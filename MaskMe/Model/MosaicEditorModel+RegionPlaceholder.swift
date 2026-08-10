import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore

/// 範囲指定サーチが置いた暫定矩形（`ObjectMask.isRegionPlaceholder == true`）を、
/// 第 2 段のシード走査結果の台帳（`regionPlaceholderLedgers`）から見て外してよいかを
/// 判定・実行する第 3 段。
///
/// ## 何をするか
///
/// 第 2 段（`MosaicEditorModel+RegionSeeding.swift`）が前後方向へ検出キャッシュを
/// 埋め終えたら、その区間が「顔として十分に覆えた」と確認できたときだけ矩形を外す。
/// 覆えていなければ矩形を残す（プライバシーアプリなので、露出が増える方向へ倒さない）。
///
/// ## 被覆判定の入力は「シード走査が実際に `mergeDetection` した素材時刻」
///
/// **この第 3 段は `lookupFaces` / `selectedLandmarks` / `signatureCache` を一切読まない。**
/// 旧実装（`selectedLandmarks(at:)` を 0.2 秒刻みでサンプリング）には 2 つの穴があった:
///
/// 1. `lookupFaces` はプレビュー専用のフォールバック（`liveFlowCache`＝フロー由来）を
///    含むが、書き出しはこれを通らない（`DetectionBridge` の 8/15 秒両側補間のみ）。
///    プレビューで埋まって見えて書き出すと露出する区間で矩形を外していた。
/// 2. `selectedLandmarks` は選択顔を**全部**返すので、矩形の**外**にいる別人が
///    全区間映っていれば、囲った人物が追跡ロスしている区間も被覆と数えていた。
///
/// 台帳（`RegionSeedScanResult.coveredSourceTimes`）は `RegionSeedTracker` が実際に
/// **選んだ**（＝ `outcome.chosenIndex != nil`）ステップでだけ `mergeDetection` した
/// 素材時刻しか持たないため、両方の穴が原理的に塞がる。
///
/// ## 判定範囲は「シードした区間」ではなく「クリップ全区間」
///
/// 暫定矩形はキーフレーム 1 個で時間範囲を持たず、`ObjectMaskResolver.placements` は
/// `anchor.clipID` でしか絞り込まない。したがって矩形は `clip.sourceStart...clip.sourceEnd`
/// の**全区間**に貼り付いている。判定対象は必ず**台帳の `clipID` が指すクリップ**の
/// 全区間で行う（`seed.sourceRange` は使わない。素材が混ざる余地を消すため）。
@MainActor
extension MosaicEditorModel {
    /// 暫定矩形マスク 1 個ぶんの被覆判定台帳。
    ///
    /// **1 つの `[UUID: RegionPlaceholderLedger]` だけを持つ**（旧実装の
    /// `regionSeedPlaceholderSnapshot` + `regionSeedAuditPending` の 2 系統を統合した）。
    struct RegionPlaceholderLedger {
        /// マスクがアンカーしたクリップ（enqueue 時点で `mask.anchor.clipID` と一致を確認済み）。
        let clipID: UUID
        let sourceID: UUID
        /// enqueue 時点のマスクの指紋。ユーザーが矩形を編集した（動かした・キーフレームを
        /// 増やした）ものは、現在のマスクと比較して不一致になるため対象外にできる。
        let snapshot: ObjectMask
        /// このマスクに紐づく全シードの `FaceTarget.id`。finalize 時に「まだ選択されているか」
        /// を確かめる（選択が外れていれば書き出しの `filterToSelected` で素通しになるため）。
        var seedTargetIDs: [UUID] = []
        /// enqueue のたびに +1 する、このマスクへ積まれるはずのシード総数。
        var expectedSeeds = 0
        /// 完走したシード走査結果。`finished.count == expectedSeeds` になるまで finalize しない
        /// （同じ maskID の 1 本だけが残って「シード 1 本」に見える穴を塞ぐ）。
        var finished: [RegionSeedScanResult] = []
        /// 走査が中止・世代不一致・FIFO 溢れで失われたら true。以後 finalize しても
        /// 必ず矩形を残す。
        var isDisqualified = false
    }

    /// 台帳の上限件数。超えたら挿入順で古いものから破棄する（単調増加しない）。
    private static var regionPlaceholderLedgerLimit: Int { 16 }

    // MARK: - 台帳の書き込み（enqueue 側）

    /// `enqueueRegionSeed` から呼ぶ。台帳を作る／`expectedSeeds` を増やす。
    ///
    /// **enqueue 時に `mask.anchor.clipID == seed.clipID && mask.anchor.sourceID ==
    /// seed.sourceID` が成り立たなければ、そもそも台帳を作らない。** これにより
    /// `scanSegments` がクリップ B でヒットしたのにマスクがクリップ A にある
    /// （`resolveRegion` が矩形を置いた後にクリップ構成が変わった等の）経路が、
    /// 自動的に「残す」へ倒れる。
    func enqueueRegionPlaceholderLedgerEntry(maskID: UUID, seed: RegionSeed) {
        guard let mask = objectMasks.first(where: { $0.id == maskID }),
              mask.anchor.clipID == seed.clipID, mask.anchor.sourceID == seed.sourceID
        else { return }
        if regionPlaceholderLedgers[maskID] == nil {
            regionPlaceholderLedgers[maskID] = RegionPlaceholderLedger(
                clipID: seed.clipID, sourceID: seed.sourceID, snapshot: mask)
            regionPlaceholderLedgerOrder.append(maskID)
            enforceRegionPlaceholderLedgerLimit()
        }
        regionPlaceholderLedgers[maskID]?.expectedSeeds += 1
        regionPlaceholderLedgers[maskID]?.seedTargetIDs.append(seed.targetID)
    }

    /// FIFO 上限溢れ・走査中止・世代不一致で失われたシードの maskID を失格にする。
    /// 失格になった台帳は、以後 `finalizeRegionPlaceholder` が必ず矩形を残す。
    func disqualifyRegionPlaceholderLedger(maskID: UUID) {
        regionPlaceholderLedgers[maskID]?.isDisqualified = true
    }

    private func enforceRegionPlaceholderLedgerLimit() {
        while regionPlaceholderLedgerOrder.count > Self.regionPlaceholderLedgerLimit {
            let oldest = regionPlaceholderLedgerOrder.removeFirst()
            regionPlaceholderLedgers.removeValue(forKey: oldest)
        }
    }

    /// `drainRegionSeedQueue` から呼ぶ。1 本のシード走査結果を台帳へ記録し、
    /// そのマスクへ積まれた全シードが揃ったところで `finalizeRegionPlaceholder` を呼ぶ
    /// （個々のシード完了ごとに判定すると、同じ矩形の他のシードがまだ走っている途中で
    /// 早まって外してしまう）。
    ///
    /// 走査が完走しなかった（`isComplete == false`）・世代が食い違う・タスクが
    /// 既にキャンセルされているときは、この結果を採用せず失格にする
    /// （中止された走査の結果が復活する穴を塞ぐ）。
    func recordRegionSeedScanResult(_ result: RegionSeedScanResult) {
        guard let maskID = result.seed.maskID else { return }
        guard result.isComplete, result.generation == regionSeedGeneration, !Task.isCancelled else {
            disqualifyRegionPlaceholderLedger(maskID: maskID)
            return
        }
        guard regionPlaceholderLedgers[maskID] != nil else { return }
        regionPlaceholderLedgers[maskID]?.finished.append(result)
        finalizeRegionPlaceholderIfReady(maskID: maskID)
    }

    /// 全シードが揃ったときだけ判定へ進む。
    ///
    /// **ここの `expectedSeeds == finished.count` は「いつ呼ぶか」の制御であって、
    /// 安全弁ではない**（安全弁は `finalizeRegionPlaceholder` 本体の guard 群にある同じ条件。
    /// こちらを消してもマスクは外れない ＝ 門は本体側 1 本に寄っている）。
    /// 台帳を consume するのは本体なので、ここで早期 return しても台帳は消えない。
    private func finalizeRegionPlaceholderIfReady(maskID: UUID) {
        guard let ledger = regionPlaceholderLedgers[maskID],
              ledger.expectedSeeds == ledger.finished.count else { return }
        finalizeRegionPlaceholder(maskID: maskID)
    }

    // MARK: - 反映（S6）

    /// 台帳の被覆判定の結果、暫定矩形を外してよいかを判定して実行する。
    ///
    /// **1 つでもガードに引っかかったら何もしない（矩形を残す）。** 迷ったら残す、という
    /// 本件の原則をここでも崩さない。台帳は呼び出し時点で consume（削除）する
    /// （合否に関わらず）ので、この関数は idempotent（2 回目は即 no-op）。
    func finalizeRegionPlaceholder(maskID: UUID) {
        regionPlaceholderLedgerOrder.removeAll { $0 == maskID }
        guard let ledger = regionPlaceholderLedgers.removeValue(forKey: maskID) else { return }

        guard !ledger.isDisqualified,
              let mask = objectMasks.first(where: { $0.id == maskID }), mask.isRegionPlaceholder,
              ledger.snapshot == mask,
              mask.anchor.clipID == ledger.clipID, mask.anchor.sourceID == ledger.sourceID,
              let clipIndex = clips.firstIndex(where: { $0.id == ledger.clipID }),
              sources[ledger.sourceID] != nil,
              faceMosaicOn,
              !clipParticipatesInTransition(clipIndex: clipIndex),
              ledger.expectedSeeds == ledger.finished.count,
              ledger.finished.allSatisfy({ $0.generation == regionSeedGeneration }),
              ledger.seedTargetIDs.allSatisfy({ targetID in
                  detectedFaces.contains { $0.id == targetID && $0.isSelected }
              }),
              applyRangeCoversClip(clips[clipIndex])
        else { return }

        let clip = clips[clipIndex]
        let span = clip.sourceStart...clip.sourceEnd
        guard span.upperBound > span.lowerBound, !ledger.finished.isEmpty else { return }

        let verdicts = ledger.finished.map { result in
            RegionPlaceholderAudit.evaluate(
                span: span, rate: clip.rate, coveredTimes: result.coveredSourceTimes,
                identityConfirmations: result.identityConfirmations,
                requiresIdentity: result.seed.personID != nil && FaceSignatureProvider.shared.isAvailable,
                anchorInsideRect: isAnchorInsideRect(seed: result.seed, mask: mask))
        }
        guard verdicts.allSatisfy(\.isCovered) else { return }

        objectMasks.removeAll { $0.id == maskID }
        renderPreview()
        previewController?.invalidate()
        commitEdit()
    }

    /// クリップの使用区間が、現在有効な適用区間（`effectiveApplyRanges`）で切れ目なく
    /// 覆われているか。**`TimelineBandLayout.applySpans`**（`MosaicApplyGate.clippedInterval`
    /// を内部で使う、画面の帯と同一の交差判定。不変条件 I1/I3）を通した合成秒の帯で判定する
    /// （`MosaicApplyGate.clippedInterval` 自体は `MosaicCore` 内部専用で `internal` のため、
    /// アプリ層から直接は呼べない。式を書き写さず、公開されている帯の計算を再利用する）。
    /// 部分被覆なら false（矩形を残す）。
    private func applyRangeCoversClip(_ clip: TimelineClip) -> Bool {
        guard let clipSpan = mapping.clipSpans.first(where: { $0.clip.id == clip.id }) else { return false }
        let allSpans: [TimelineApplySpan] = TimelineBandLayout.applySpans(
            ranges: effectiveApplyRanges, mapping: mapping, photoSourceIDs: timeline.photoSourceIDs)
        // `applySpans` の結果はすべて `.mosaic`（`anchorClipID` は非 nil）だが、
        // 被覆の判定に BGM が紛れ込むことは絶対に避けたいので種でも絞る。
        // **モザイクの被覆を「何かの帯があるか」で測らない**（`testing.md` の教訓）。
        let clipSpans: [TimelineApplySpan] = allSpans.filter {
            $0.kind == .mosaic && $0.anchorClipID == clip.id
        }
        let spans: [TimelineApplySpan] = clipSpans.sorted { $0.start < $1.start }
        guard !spans.isEmpty else { return false }
        var coveredEnd = clipSpan.start
        for span in spans {
            guard span.start <= coveredEnd else { return false }
            coveredEnd = max(coveredEnd, span.end)
        }
        return coveredEnd >= clipSpan.end
    }

    /// シード時刻の顔（`seed.seedLandmarks`。素材フレーム基準）の重心が、同じ素材時刻の
    /// マスク矩形（`ObjectMaskResolver.rect(of:tracks:atSourceTime:)`。素材フレーム基準）を
    /// 1.2 倍に膨らませた範囲の内側にあるか。**両方とも素材フレーム基準のまま比較する**
    /// （合成フレーム基準へ写した値と混ぜない）。
    private func isAnchorInsideRect(seed: RegionSeed, mask: ObjectMask) -> Bool {
        let rect = ObjectMaskResolver.rect(of: mask, tracks: objectTracks, atSourceTime: seed.seedTime)
        let inflated = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1)
        let centroid = normalizedCentroid(of: seed.seedLandmarks)
        return inflated.contains(centroid)
    }

    /// クリップがトランジションの重なりに関与しているか（自分の後ろ・自分の前のどちらか）。
    private func clipParticipatesInTransition(clipIndex: Int) -> Bool {
        let clipID = clips[clipIndex].id
        if timeline.transitions[clipID] != nil { return true }
        if clipIndex > 0, timeline.transitions[clips[clipIndex - 1].id] != nil { return true }
        return false
    }
}
