import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore
import UIKit

/// 範囲指定サーチ（`detectInRegion` / `resolveRegion`）が見つけた顔（シード）を、
/// 素材の前後方向へ追い続けて検出キャッシュへ書き戻す走査の起動・キュー・世代・書き戻し。
///
/// ## なぜ要るか
///
/// 描画（`displayFaces` → `lookupFaces`）は検出キャッシュしか見ない。矩形サーチは
/// シード時刻のバケットしか埋めないため、そこから離れた時刻では顔が出ず素通しになる。
/// このファイルは `RegionSeedTracker`（`MosaicCore`。フレームも検出器も知らない純ロジック）に
/// `RegionFaceSeeder`（フレーム供給層）でフレームを与え、見つかった顔を `mergeDetection`
/// 経由でキャッシュへ書き戻す。
///
/// ## 1 本構成
///
/// `regionSeedQueue`（FIFO・上限 8）+ `regionSeedTask`（1 本）で、並行に何本も走らせない。
/// 溢れたら古いシードを捨てる（新しいユーザー操作を優先する）。
///
/// ## 世代
///
/// `regionSeedGeneration` は `timelineGeneration` を流用しない専用トークン。シードが運ぶのは
/// 素材ID＋素材時刻で、タイムラインを編集しても（トリム・並べ替え）意味が変わらないため。
/// 流用すると正当な走査結果までトリムのたびに捨てられてしまう。
///
/// ## 書き戻しの規律（最重要）
///
/// - 書き込み口は `mergeDetection` のみ。素の `cacheStore.store` は同バケットの他の顔を
///   消してしまい、プライバシー的に露出が増える方向へ逆流する（`mergeDetection` の doc 参照）。
/// - **顔が見つからなかったときは、全画面フォールバックの結果であっても空エントリを
///   一切書かない**。理由は `recordRegionSeedFinding` の doc 参照。
/// - `liveFlowCache` へは一切書かない（これはオプティカルフロー専用で、実検出ではない
///   矩形サーチ由来の結果を混ぜるとエクスポート品質を汚染する）。
@MainActor
extension MosaicEditorModel {
    /// 矩形サーチ結果を起点にした 1 本の追跡シード。
    struct RegionSeed {
        let sourceID: UUID
        let asset: AVAsset
        /// 該当クリップの `clip.sourceStart...clip.sourceEnd`。
        let sourceRange: ClosedRange<Double>
        /// このシードが属するクリップの識別子（`TimelineClip.id`）。**非オプショナル**:
        /// クリップを決められない経路（クリップ未構築・写像不能）ではそもそもシードを
        /// 作らない（`detectInRegion` / `resolveRegion` の既存の `hit.range == nil` ガードと
        /// 同じ倒し方）。第 3 段の台帳（`RegionPlaceholderLedger`）がこの id を
        /// マスクの `anchor.clipID` と突き合わせて「シードとマスクのクリップが食い違って
        /// いないか」を検証するのに使う。
        let clipID: UUID
        /// **実測時刻**（`copyCGImage(at:actualTime:)` の actualTime、または矩形サーチが
        /// 実測した時刻）。要求時刻を使わないこと。
        let seedTime: Double
        let seedLandmarks: FaceLandmarkSet
        /// このシードのもとになった `FaceTarget.id`。
        let targetID: UUID
        let personID: UUID?
        /// このシードの元になった暫定矩形マスクの id。`nil` は「対象外」
        /// （マスクが作れなかった・矩形サーチ以外の経路からテストが直接組み立てた等）で、
        /// 第 3 段の被覆判定（`regionPlaceholderLedgers`）には積まれない。
        let maskID: UUID?

        init(sourceID: UUID, asset: AVAsset, sourceRange: ClosedRange<Double>, clipID: UUID,
             seedTime: Double, seedLandmarks: FaceLandmarkSet,
             targetID: UUID, personID: UUID?, maskID: UUID? = nil) {
            self.sourceID = sourceID
            self.asset = asset
            self.sourceRange = sourceRange
            self.clipID = clipID
            self.seedTime = seedTime
            self.seedLandmarks = seedLandmarks
            self.targetID = targetID
            self.personID = personID
            self.maskID = maskID
        }
    }

    /// 1 シードぶんの走査中に持ち回る可変状態。関数の引数を増やしすぎないための入れ物
    /// （`SwiftLint` の `function_parameter_count` 対策の意味もあるが、本質は「1 走査を通した
    /// 一貫した状態」であることを型で示すため）。`class` なのは、後方 → 前方の 2 方向を
    /// 通して同じ間引き時計・同じフォールバック上限を共有する必要があるため
    /// （値型で分ければ方向間で状態が引き継がれない）。
    ///
    /// **アクセスレベル**: テストが「ROI ミスで空を書かない」等を実素材なしで直接検証できるよう
    /// `internal`。
    final class RegionSeedScanState {
        /// 書き戻しを許可する世代。`recordRegionSeedFinding` が書き込み直前に
        /// `regionSeedGeneration` と突き合わせる。
        let generation: Int
        /// 走査ローカルの署名間引き時計。**モデルの `lastSignatureSourceTime` は触らない**
        /// （プレビュー側の状態を汚す）。
        var lastSignatureTime: Double?
        /// この走査で補った `FaceTarget` の重心（次の追加のための最小距離判定に使う）。
        var fallbackCentroids: [CGPoint] = []
        /// この走査で補った `FaceTarget` の数（上限 4）。
        var fallbackCount = 0
        /// 第 3 段の被覆台帳（`regionPlaceholderLedgers`）へ引き渡す、この走査が
        /// 実際に `mergeDetection` を通した素材時刻。**追記のみ**（`recordCovered` 経由）。
        private(set) var coveredSourceTimes: [Double] = []
        /// 追跡中の人物と一致したと確認できたバケット数。
        var identityConfirmations = 0

        init(generation: Int) {
            self.generation = generation
        }

        /// 被覆時刻を1件追記する。書き込み口は `processRegionSeed`（シード時刻）と
        /// `recordRegionSeedFinding`（`chosenIndex` が選ばれたとき）の2箇所だけ。
        func recordCovered(_ sourceTime: Double) {
            coveredSourceTimes.append(sourceTime)
        }
    }

    /// 1 シードぶんの走査が終わったところの結果。第 3 段の台帳
    /// （`MosaicEditorModel+RegionPlaceholder.swift` の `RegionPlaceholderLedger`）へ渡す。
    struct RegionSeedScanResult {
        let seed: RegionSeed
        /// この走査が動いていた時点の `regionSeedGeneration`。
        let generation: Int
        let coveredSourceTimes: [Double]
        let identityConfirmations: Int
        /// 後方・前方の**両方**が自然終了（`nextStep()` が nil を返した）したか。
        /// `Task.isCancelled` や世代不一致で打ち切られた走査は false になり、
        /// 台帳側はこの結果を被覆判定に使わず失格として扱う。
        let isComplete: Bool
    }

    /// シード走査の待ち行列の上限。溢れたら古いものから捨てる。
    private static var regionSeedQueueLimit: Int { 8 }
    /// 署名計測の間引き間隔（秒、素材時刻）。候補が 2 つ以上あるステップは間引かず必ず測る。
    private static var regionSeedSignatureInterval: Double { 0.5 }
    /// 署名が使えなかったときに補う `FaceTarget` の 1 走査あたりの上限。
    private static var regionSeedFallbackTargetLimit: Int { 4 }
    /// 補う `FaceTarget` どうしが「別の顔」とみなせる最小重心距離（正規化座標）。
    private static var regionSeedFallbackMinDistance: CGFloat { 0.4 }

    // MARK: - 起動・キュー

    /// 矩形サーチが見つけた顔をシードとして待ち行列へ積み、走査を（未起動なら）開始する。
    ///
    /// 動画モード専用（写真は素材ID・検出キャッシュの概念が無いので何もしない）。
    /// 上限 8 件の FIFO。溢れたら古いものから捨てる（新しいユーザー操作を優先する）。
    ///
    /// `seed.maskID` があれば、第 3 段（`finalizeRegionPlaceholder`）の台帳
    /// （`regionPlaceholderLedgers`）を作る／`expectedSeeds` を増やす
    /// （`enqueueRegionPlaceholderLedgerEntry` の doc 参照）。
    ///
    /// FIFO 上限を超えて捨てられるシードがあれば、その maskID の台帳を失格にする
    /// （捨てられたシードの走査結果は永遠に来ないため、`expectedSeeds` が満たされず
    /// 台帳が固まったまま残ってしまう。失格マークで代わりに矩形を残す）。
    func enqueueRegionSeed(_ seed: RegionSeed) {
        guard mode == .video, seed.sourceRange.upperBound > seed.sourceRange.lowerBound else { return }
        if let maskID = seed.maskID {
            enqueueRegionPlaceholderLedgerEntry(maskID: maskID, seed: seed)
        }
        regionSeedQueue.append(seed)
        if regionSeedQueue.count > Self.regionSeedQueueLimit {
            let overflow = regionSeedQueue.count - Self.regionSeedQueueLimit
            for dropped in regionSeedQueue.prefix(overflow) {
                if let maskID = dropped.maskID { disqualifyRegionPlaceholderLedger(maskID: maskID) }
            }
            regionSeedQueue.removeFirst(overflow)
        }
        startRegionSeedingIfNeeded()
    }

    /// 走査を打ち切る（素材の入れ替え・画面を閉じるとき）。世代を進めてから
    /// キューを空にし、走行中のタスクを cancel する。世代を先に進めるのが要点:
    /// 走行中のタスクが cancel の直前に読んでいた `regionSeedGeneration` と
    /// 食い違わせ、書き戻し直前のガードで確実に捨てさせる。
    func cancelRegionSeeding() {
        regionSeedGeneration += 1
        regionSeedQueue.removeAll()
        regionSeedTask?.cancel()
        regionSeedTask = nil
        // 走行中のタスクの後始末を待たずに、ここで同期的に戻す（呼び出し直後に
        // 「走査していない」を観測できることを保証する）。
        regionSeedProgress = nil
        // 世代が進んだ以上、待っていた被覆判定の台帳はもう意味を持たない
        // （`recordRegionSeedScanResult` が世代不一致で弾くはずだが、明示的に空にして
        // 残骸を残さない）。
        regionPlaceholderLedgers.removeAll()
        regionPlaceholderLedgerOrder.removeAll()
    }

    /// 走行中のシード走査が終わるまで待つ。`awaitObjectTracking()` と同じ形
    /// （`MosaicEditorModel+ObjectTracking.swift` の doc 参照）。
    ///
    /// **`while` の無限待ちにしない。** 待っている間に新しいシードが積まれ
    /// `regionSeedTask` が張り替わることがあるので数回まわすが、回数で上限を切る。
    /// 完了してもプロパティが更新されないタイミングが一度でもあれば、`while` は
    /// 書き出しボタンが永久に返ってこない固まり方をする。
    func awaitRegionSeeding() async {
        for _ in 0..<8 {
            guard let task = regionSeedTask else { return }
            await task.value
        }
    }

    private func startRegionSeedingIfNeeded() {
        guard regionSeedTask == nil else { return }
        regionSeedRunToken += 1
        let runToken = regionSeedRunToken
        regionSeedTask = Task { [weak self] in
            await self?.drainRegionSeedQueue(runToken: runToken)
        }
    }

    /// `runToken` は自分の起動時点の `regionSeedRunToken`。末尾の `regionSeedTask = nil` は
    /// **自分がまだ現役の実行であるときだけ**行う（`regionSeedRunToken` の doc 参照）。
    /// これを無条件にすると、`cancelRegionSeeding()` 直後に新しいシードが積まれて
    /// タスクが張り替わったあと、cancel された自分（このタスク）が遅れて `while` を
    /// 抜けたときに新しいタスクの参照を上書きして消してしまう。
    private func drainRegionSeedQueue(runToken: Int) async {
        // フレーム単位の細かい進捗は不要なので「キューに積まれたシードのうち
        // 何本目を処理しているか」で近似する。走査中に新しいシードが積まれて
        // 母数が増えることがあるので、母数は毎回「処理済み＋残り」で取り直す。
        var processed = 0
        while !Task.isCancelled {
            guard !regionSeedQueue.isEmpty else { break }
            let total = processed + regionSeedQueue.count
            regionSeedProgress = total > 0 ? Double(processed) / Double(total) : nil
            let seed = regionSeedQueue.removeFirst()
            let generation = regionSeedGeneration
            let result = await processRegionSeed(seed, generation: generation)
            processed += 1
            // 第3段: この 1 本の走査結果を台帳へ記録する。全シードが揃ったところで
            // `recordRegionSeedScanResult` 自身が `finalizeRegionPlaceholder` を呼ぶ
            // （同じ矩形の他のシードがまだ走っている途中で早まって外さないため）。
            recordRegionSeedScanResult(result)
        }
        guard runToken == regionSeedRunToken else { return }
        regionSeedTask = nil
        regionSeedProgress = nil
    }

    // MARK: - 1 シードぶんの走査

    /// 1 シードを後方 → 前方の順で走査する。方向ごとに `RegionSeedTracker` を 1 つ作り、
    /// 両方向で**同じ `AVAssetImageGenerator` を共有**する（作り直すとコマ数ぶんデコーダの
    /// 立ち上げ直しになる。`MosaicEditorModel.makeFrameGenerator(for:)` の doc 参照）。
    private func processRegionSeed(_ seed: RegionSeed, generation: Int) async -> RegionSeedScanResult {
        let state = RegionSeedScanState(generation: generation)
        // シード時刻そのものは `detectInRegion` / `resolveRegion` が既にその時刻へ
        // `mergeDetection` 済み（トラッカーは `seedTime` を返さないので、ここで
        // 明示的に足しておかないと台帳から抜け落ちる）。
        state.recordCovered(seed.seedTime)

        guard sources[seed.sourceID] != nil else {
            return RegionSeedScanResult(seed: seed, generation: generation,
                                        coveredSourceTimes: state.coveredSourceTimes,
                                        identityConfirmations: state.identityConfirmations,
                                        isComplete: false)
        }
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let generator = Self.makeFrameGenerator(for: seed.asset)

        var isComplete = true
        for direction: RegionSeedTracker.Direction in [.backward, .forward] {
            guard !Task.isCancelled, generation == regionSeedGeneration else {
                isComplete = false
                continue
            }
            var tracker = RegionSeedTracker(seedTime: seed.seedTime,
                                            seedBox: seed.seedLandmarks.boundingBox,
                                            range: seed.sourceRange, direction: direction)
            let directionComplete = await runDirection(&tracker, seed: seed, generator: generator,
                                                       scanner: scanner, state: state)
            if !directionComplete { isComplete = false }
        }
        return RegionSeedScanResult(seed: seed, generation: generation,
                                    coveredSourceTimes: state.coveredSourceTimes,
                                    identityConfirmations: state.identityConfirmations,
                                    isComplete: isComplete)
    }

    /// 1 方向を走査し終える。**両方向とも自然終了（`nextStep()` が nil）したときだけ
    /// `true`**。`Task.isCancelled` や世代不一致で打ち切られたときは `false`
    /// （呼び出し元の `processRegionSeed` が `RegionSeedScanResult.isComplete` へ畳む）。
    private func runDirection(
        _ tracker: inout RegionSeedTracker,
        seed: RegionSeed,
        generator: AVAssetImageGenerator,
        scanner: FaceLandmarking,
        state: RegionSeedScanState
    ) async -> Bool {
        while true {
            guard !Task.isCancelled, state.generation == regionSeedGeneration else { return false }
            guard let step = tracker.nextStep() else { return true }
            // 協調的な譲り: 既存の `shouldYieldTrackingDecoder` を判定に使い、
            // `ObjectMaskTracker.pumpFrames` と同じ 200ms スリープで譲る。
            while shouldYieldTrackingDecoder {
                if Task.isCancelled { return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, state.generation == regionSeedGeneration else { return false }

            // 毎フレーム autoreleasepool（書き忘れると実機で「途中から検出ゼロ」になる
            // 既知事故）。
            var stepResult: RegionFaceSeeder.StepResult?
            autoreleasepool {
                stepResult = RegionFaceSeeder.detect(step: step, generator: generator, scanner: scanner)
            }
            guard let result = stepResult else {
                tracker.accept(candidates: [], similarities: nil)
                continue
            }

            let profile = seed.personID.flatMap { personRegistry.person(id: $0) }
            var signatures: [FaceSignature?]?
            if let profile, !result.candidates.isEmpty, FaceSignatureProvider.shared.isAvailable,
               shouldMeasureSignature(candidateCount: result.candidates.count,
                                      sourceTime: result.sourceTime,
                                      lastSignatureTime: state.lastSignatureTime) {
                signatures = FaceSignatureProvider.shared.signatures(for: result.candidates, in: result.frame)
                state.lastSignatureTime = result.sourceTime
            }
            let similarities: [Float]? = signatures.map { sigs in
                sigs.map { sig -> Float in
                    guard let sig, let profile else { return -1 }
                    return profile.similarity(to: sig)
                }
            }

            let outcome = tracker.accept(candidates: result.candidates, similarities: similarities)
            recordRegionSeedFinding(result, seed: seed, outcome: outcome,
                                    signatures: signatures, state: state)
        }
    }

    private func shouldMeasureSignature(candidateCount: Int, sourceTime: Double,
                                        lastSignatureTime: Double?) -> Bool {
        // 候補が2つ以上あるステップは必ず測る（同定できないと乗り移り事故になる）。
        guard candidateCount < 2 else { return true }
        guard let lastSignatureTime else { return true }
        return abs(sourceTime - lastSignatureTime) >= Self.regionSeedSignatureInterval
    }

    // MARK: - キャッシュへの書き戻し

    /// 1 ステップぶんの検出結果を検出キャッシュ（＋署名・フォールバック `FaceTarget`）へ
    /// 反映する。**キャッシュへ書き込む直前に毎回世代・素材の生死を確認する**
    /// （テストから直接呼べるよう `internal`。世代不一致・素材消失の 2 経路を
    /// 実素材なしで検証するため）。
    ///
    /// **顔が見つからなかったときは、全画面フォールバックの結果であっても空エントリを
    /// 一切書かない。** `cacheStore.store([], ...)` は「このフレームをスキャンして顔が
    /// 無かった」という意味で、`shouldDetectPreviewFrame`（`MosaicEditorModel+LiveDetection.swift`）
    /// が `hasEntry` を見てそのバケットのライブ検出を永久にスキップする。
    ///
    /// 当初は「全画面フォールバック（`isFullFrame`、連続ミス3回目に ROI を単位矩形へ
    /// 広げたステップ）だけは本当に全画面を見た上でのミスだから空エントリを書いてよい」
    /// という例外を設けていたが、親の裁定でこれをやめた。理由: 全画面を見た上でのミスで
    /// あっても、空エントリを書くとそのバケットのライブ検出が永久に止まる。
    /// **検出の退行は誤モザイクより重い**（プライバシーアプリ）という本件の原則からすると、
    /// 書かない方が安全で、書いて得られる利得（キャッシュミスの節約）は無い。
    /// 規則は単純化して「候補が空なら理由に関わらず一切書かない」に統一する。
    func recordRegionSeedFinding(
        _ result: RegionFaceSeeder.StepResult,
        seed: RegionSeed,
        outcome: RegionSeedTracker.Outcome,
        signatures: [FaceSignature?]?,
        state: RegionSeedScanState
    ) {
        guard state.generation == regionSeedGeneration, sources[seed.sourceID] != nil else { return }
        guard !result.candidates.isEmpty else { return }

        // ROI に入っていた「追っていない顔」も全部書く（絞り込みは描画側の仕事）。
        mergeDetection(result.candidates, sourceID: seed.sourceID, sourceTime: result.sourceTime)
        if let signatures {
            signatureCache.store(signatures, for: result.candidates,
                                 sourceID: seed.sourceID, time: result.sourceTime)
        }

        guard let chosenIndex = outcome.chosenIndex else { return }
        // 第3段の台帳へ: トラッカーが選んだ（＝人物を絞り込んだ）結果のときだけ被覆時刻を
        // 記録する。ROI に写り込んだだけの他人の顔（`chosenIndex` に選ばれない候補）は
        // ここへ来ないので、他人で穴が埋まる問題が原理的に成立しない。
        state.recordCovered(result.sourceTime)
        let chosenFace = result.candidates[chosenIndex]
        let chosenSignature = signatures?[chosenIndex] ?? nil
        let profile = seed.personID.flatMap { personRegistry.person(id: $0) }
        if let profile, let chosenSignature,
           profile.similarity(to: chosenSignature) >= FaceIdentityThreshold.match {
            state.identityConfirmations += 1
        }

        if let personID = seed.personID, let chosenSignature {
            personRegistry.addExemplar(chosenSignature, toPersonWith: personID)
        }

        // 署名が使えなかったときに限り、追跡中心が離れていれば FaceTarget を補う
        // （描画の絞り込みは重心 0.5 以内 ＋ 署名で判定するため、シード時刻から離れた
        // 顔は FaceTarget が無いと落ちる）。
        guard chosenSignature == nil, state.fallbackCount < Self.regionSeedFallbackTargetLimit else { return }
        let centroid = normalizedCentroid(of: chosenFace)
        let tooClose = state.fallbackCentroids.contains {
            hypot($0.x - centroid.x, $0.y - centroid.y) < Self.regionSeedFallbackMinDistance
        }
        guard !tooClose else { return }
        let thumb = generateThumbnail(for: chosenFace, from: result.frame)
        detectedFaces.append(FaceTarget(id: UUID(), landmarks: chosenFace, thumbnail: thumb,
                                        isSelected: true, sourceID: seed.sourceID,
                                        personID: seed.personID))
        state.fallbackCentroids.append(centroid)
        state.fallbackCount += 1
    }
}
