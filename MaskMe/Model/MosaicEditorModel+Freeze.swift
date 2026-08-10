import AVFoundation
import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// `resolvedFreezeSource(atDisplayTime:)` の結果（`large_tuple` を避けるための型）。
private struct ResolvedFreezeSource {
    let asset: AVAsset
    let sourceID: UUID
    let sourceTime: Double
}

/// `applyFreezeEdit` へ渡す一式（`function_parameter_count` を避けるための型）。
/// コア編集の結果そのものではなく、それを組み立てるのに要る材料をまとめただけ
/// （`freezingEdit` の呼び出しは `applyFreezeEdit` の内部で行う）。
private struct FreezeInsertion {
    let clipID: UUID
    let displayTime: Double
    let freezeClip: TimelineClip
    let newSourceID: UUID
    let photoAsset: AVAsset
    let unionFaces: [FaceLandmarkSet]
    let normalizedImage: UIImage
    let wasMosaicActive: Bool
}

/// `MosaicEditorModel` の**フリーズフレーム挿入**（アプリ層）。
///
/// コア層（`TimelineState.freezingEdit` / `ObjectMaskEditOperations.masks(freezingClip:...)`）は
/// 「タイムライン上のどこに、どう挟み込むか」だけを扱う。ここでは
///
/// 1. 対象時刻のコマを**素材から直接**抽出して静止 mp4 へエンコードし、
/// 2. **検出キャッシュ・選択顔・手描き矩形・適用区間**の 4 つを引き継ぎ、
/// 3. それら全部を **1 回の undo 単位**として確定する
///
/// という「素材登録・欠けると顔が素通しになる引き継ぎ」を担う
/// （`appendPhotoClip` / `seedPhotoDetection` の写真クリップ経路と同じ骨格）。
extension MosaicEditorModel {
    // MARK: - プレビュー（シート表示用の軽量抽出）

    /// フリーズ対象時刻のコマをプレビュー用に取り出す。**素材登録・検出・編集は一切行わない**
    /// （シートを開いた時点でユーザーが実際に何を凍らせるのか見せるためだけの読み取り専用処理）。
    ///
    /// 長 GOP 素材では `requestedTimeToleranceBefore/After = .zero` のデコードに時間がかかる
    /// ことがあるため、呼び出し側（UI）は非同期で待つこと。
    public func freezeFramePreview(atDisplayTime displayTime: Double) async -> UIImage? {
        guard let source = resolvedFreezeSource(atDisplayTime: displayTime) else { return nil }
        return try? await Task.detached(priority: .userInitiated) {
            try FreezeFrameFactory.extractFrame(from: source.asset, atSourceTime: source.sourceTime)
        }.value
    }

    /// フリーズ対象時刻を素材・素材内時刻へ解決する（プレビュー・本実行の共通入口）。
    ///
    /// `resolveSourceLocation(atComposition:)` を使う理由: 表示時刻（トランジションの
    /// 重なり込み）と合成時刻は同じ時間軸である（`splitAtCurrentPosition` が
    /// `compositionTime(forPosition:)` をそのまま `splittingEdit(atDisplayTime:)` へ渡しているのと
    /// 同じ前提）。これにより「凍らせる瞬間の素材位置」を、検出キャッシュの参照
    /// （`sourceScopedCache(for:)`）とコマ抽出（`FreezeFrameFactory`）の両方で
    /// **同じ値**にできる——別々に算出すると 1 フレームずれた位置の顔を引く事故になる。
    private func resolvedFreezeSource(atDisplayTime displayTime: Double) -> ResolvedFreezeSource? {
        let resolved = resolveSourceLocation(atComposition: displayTime)
        guard let asset = sources[resolved.sourceID] else { return nil }
        return ResolvedFreezeSource(asset: asset, sourceID: resolved.sourceID, sourceTime: resolved.time)
    }

    // MARK: - 本実行

    /// 指定クリップの指定表示時刻へフリーズフレーム（3 秒の静止画クリップ）を挿入する。
    ///
    /// 活性判定は呼び出し側が `timeline.canFreeze(clipID:atDisplayTime:)` を使うこと
    /// （UI の「フリーズ」ボタンの活性・本関数の実行が別の規則で決まると
    /// 「押せるのに何も起きない/黙って失敗する」が起こる。ここでも同じ判定を再度掛けて
    /// 二重に守るが、UI 側の判定と食い違ってはならない）。
    ///
    /// **失敗時は `errorMessage` を立てて何もしない**（他の編集 API と違い、これは
    /// エンコード・検出という失敗しうる非同期処理を含むため、無言の no-op ではなく
    /// 理由を出す。`appendPhotoClip` と同じ方針）。
    @MainActor
    public func freezeFrame(clipID: UUID, atDisplayTime displayTime: Double) async {
        guard timeline.canFreeze(clipID: clipID, atDisplayTime: displayTime) else { return }
        guard let originalClip = timeline.clips.first(where: { $0.id == clipID }) else { return }
        guard let source = resolvedFreezeSource(atDisplayTime: displayTime) else {
            errorMessage = "コマの取り出しに失敗しました"
            return
        }
        // 「凍らせた合成時刻でモザイクが有効だったか」は編集前の状態で判定する
        // （4 つ目の引き継ぎ＝適用区間の可否。`freezingEdit` は常に全域を覆う適用区間を
        // 自動生成するが、これは「モザイクを使っている編集に区間を足す」という
        // 他の追加経路（`appendPhotoClip` の `coveringWithApplyRange`）の規則とは異なる。
        // フリーズ元の時点でモザイクが掛かっていなかった区間を凍らせても、
        // その静止画にだけモザイクが生えるのは意図と違う——ここで判定し、
        // 後段で自動生成された区間を要不要に応じて残す/取り除く）。
        let wasActive = isMosaicActive(atComposition: displayTime)

        do {
            let stillImage = try FreezeFrameFactory.extractFrame(
                from: source.asset, atSourceTime: source.sourceTime)
            let encoded = try await PhotoClipEncoder()
                .encode(image: stillImage, seconds: PhotoClipEncoder.clipCapacitySeconds)

            let sourceID = UUID()
            let requested = PhotoClipEncoder.defaultClipSeconds
            let freezeClip = TimelineClip(sourceID: sourceID, sourceStart: 0,
                                          sourceEnd: min(requested, encoded.duration),
                                          // ピクセルには焼き込まない。元クリップの向き設定を
                                          // そのまま引き継ぐ（`FreezeFrameFactory` の doc 参照）。
                                          orientation: originalClip.orientation)

            let unionFaces = detectAndUnionFaces(
                stillImage: encoded.normalizedImage, originalSourceID: source.sourceID,
                sourceTime: source.sourceTime)

            applyFreezeEdit(FreezeInsertion(
                clipID: clipID, displayTime: displayTime, freezeClip: freezeClip,
                newSourceID: sourceID, photoAsset: AVAsset(url: encoded.url),
                unionFaces: unionFaces, normalizedImage: encoded.normalizedImage,
                wasMosaicActive: wasActive))
        } catch {
            errorMessage = "フリーズフレームの作成に失敗しました"
        }
    }

    // MARK: - 検出（引き継ぎ 1: 検出キャッシュ）

    /// 静止画への実検出 (a) と、元クリップのその素材時刻で書き出し経路が使う顔 (b) の和集合を返す。
    ///
    /// (a) だけでは動きブレ・横顔で検出が落ち「動画では隠れていた顔が凍らせた瞬間だけ
    /// 素通しになる」。(b) は `VideoMosaicExporter.lookupCache` と同じ
    /// `DetectionBridge(interpolates: true)` を書き出し用キャッシュへそのまま掛けたもの
    /// （プレビュー専用の `liveFlowCache` / `nearestCachedFaces` フォールバックは混ぜない
    /// ——書き出しが実際に描く顔だけを引き継ぐ）。
    ///
    /// 重複は bbox IoU（`hasCounterpart`、閾値 0.3）で潰す。この判定は静止画は
    /// **常に全画面スキャン**なので、CLAUDE.md の「空エントリは全画面スキャンかつ両方空の
    /// ときだけ」を自動的に満たす。
    private func detectAndUnionFaces(stillImage: UIImage, originalSourceID: UUID,
                                     sourceTime: Double) -> [FaceLandmarkSet] {
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let stillFaces = scanner.allLandmarks(in: Self.downscaleForDetection(stillImage))
        let exportFaces = DetectionBridge(interpolates: true)
            .faces(in: sourceScopedCache(for: originalSourceID), at: sourceTime)
        let newOnes = exportFaces.filter { !$0.hasCounterpart(in: stillFaces) }
        return stillFaces + newOnes
    }

    // MARK: - 1 回の undo 単位として確定

    /// コア編集 + 4 つの引き継ぎを 1 回の `commitEdit()` にまとめる。
    ///
    /// `MosaicEditorModel+Timeline.swift` の `applyEditResult`（private）と同じ並び
    /// （`replaceTimeline` → `followClipEdit` → 追加の状態更新 → `commitEdit`）を、
    /// 手描き矩形・検出キャッシュ・選択顔・適用区間の追加作業を挟めるようここで再構成する。
    @MainActor
    private func applyFreezeEdit(_ insertion: FreezeInsertion) {
        let previous = timeline
        let edit = previous.freezingEdit(clipID: insertion.clipID, atDisplayTime: insertion.displayTime,
                                         freezeClip: insertion.freezeClip,
                                         source: TimelineSource(id: insertion.newSourceID, kind: .photo))
        guard edit.state != previous else {
            errorMessage = "この位置にはフリーズフレームを挿入できません"
            return
        }
        // 素材登録は `replaceTimeline` の Composition 再構築が `sources` を読む前に済ませる
        // （`appendPhotoClip` と同じ順序）。
        sources[insertion.newSourceID] = insertion.photoAsset

        // **4. 適用区間**: `freezingEdit` は無条件で全域を覆う適用区間を自動生成する。
        // 凍らせた瞬間にモザイクが効いていなかったなら、その区間だけ取り除く
        // （新規 sourceID なので他の区間と衝突しない）。
        var state = edit.state
        if !insertion.wasMosaicActive {
            state.applyRanges.removeAll { $0.sourceID == insertion.newSourceID }
        }

        replaceTimeline(state)
        followClipEdit(from: previous, to: state, lineage: edit.lineage)

        // **3. 手描き矩形**: 分割が起きた場合は分割点＝挿入直後のクリップの sourceStart、
        // 起きなかった場合はそのクリップ自身の sourceStart（= 挿入位置そのもの）。
        // どちらも「挿入直後のクリップ」を指す点で式が共通になる
        // （`TimelineStateFreeze.freezingEdit` の doc 参照）。
        let insertBeforeID = edit.lineage.compactMap { entry -> UUID? in
            if case let .split(front, back) = entry, front == insertion.clipID { return back }
            return nil
        }.first ?? insertion.clipID
        let sourceTimeAtInsertion = state.clips.first(where: { $0.id == insertBeforeID })?.sourceStart ?? 0
        objectMasks = ObjectMaskEditOperations.masks(
            freezingClip: insertBeforeID, atSourceTime: sourceTimeAtInsertion,
            into: insertion.freezeClip, existing: objectMasks)

        // **1. 検出キャッシュ**: 静止画は常に全画面スキャンなので、空でも安全に書ける。
        cacheStore.store(insertion.unionFaces, sourceID: insertion.newSourceID, time: 0)

        // **2. 選択顔**: 人物 ID で元クリップの選択状態を引き継ぐ。引けなかった・
        // 一致する既存ターゲットが無い場合は選択する（曖昧なら隠す側へ倒す）。
        let personIDs = seedPersonIDs(for: insertion.unionFaces, in: insertion.normalizedImage,
                                      sourceID: insertion.newSourceID, time: 0)
        detectedFaces += insertion.unionFaces.enumerated().map { idx, lm in
            let personID = personIDs[idx]
            let inheritedSelection = personID.flatMap { pid in
                detectedFaces.first(where: { $0.personID == pid })?.isSelected
            }
            return FaceTarget(id: UUID(), landmarks: lm,
                              thumbnail: generateThumbnail(for: lm, from: insertion.normalizedImage),
                              isSelected: inheritedSelection ?? true,
                              sourceID: insertion.newSourceID, personID: personID)
        }

        commitEdit()
    }
}

#endif
