import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// S4: `MosaicEditorModel` の公開タイムライン編集 API と世代トークンのテスト。
///
/// 編集 API は `TimelineState` の編集ラッパを呼ぶ薄い層なので、ここでは
/// 「モデルの状態（timeline / videoDuration / 世代）が正しく遷移するか」だけを
/// 検証する（分割・移動そのものの数値仕様は MosaicCore のテストが担う）。
@MainActor
final class TimelineEditingModelTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    private func fakeFace(cx: Double = 0.5, cy: Double = 0.4, size: Double = 0.2) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    // MARK: - 公開編集 API の状態遷移

    /// 現在の再生位置での分割が TimelineState に正しく反映されること
    /// （sourceID・rate の引き継ぎと整合性を含む）。
    func test_splitAtCurrentPosition_splitsClipAtPlaybackPosition() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        // videoDuration は timeline の didSet で合成尺に追随している
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9)
        model.playbackPosition = 0.3   // 合成 3.0s

        model.splitAtCurrentPosition()

        XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(model.clips[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(model.clips[1].sourceStart, 3.0, accuracy: 1e-9)
        XCTAssertEqual(model.clips[1].sourceEnd, 10.0, accuracy: 1e-9)
        XCTAssertEqual(model.clips[0].sourceID, source)
        XCTAssertEqual(model.clips[1].sourceID, source,
                       "分割後も素材IDを共有する（素材基準の検出キャッシュを引き継ぐ）")
        XCTAssertTrue(model.timeline.validate())
        // 分割は合成尺を変えない
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9)
    }

    /// クリップ境界（先頭）での分割は no-op で、世代も進めないこと
    /// （無駄な rebuild・in-flight 破棄を起こさない）。
    func test_splitAtClipBoundary_isNoOpAndKeepsGeneration() {
        let model = makeModel()
        model.setClipsForTesting([TimelineClip(sourceID: model.currentSourceID,
                                               sourceStart: 0, sourceEnd: 10)])
        model.playbackPosition = 0
        let generationBefore = model.timelineGeneration

        model.splitAtCurrentPosition()

        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(model.timelineGeneration, generationBefore,
                       "変化の無い編集で世代トークンが進んでいる")
    }

    /// removeClip がクリップを取り除き、最後の 1 本は消せないこと。
    func test_removeClip_removesButKeepsLastClip() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 6)
        model.setClipsForTesting([first, second])

        model.removeClip(id: first.id)
        XCTAssertEqual(model.clips.map(\.id), [second.id])
        XCTAssertEqual(model.videoDuration, 2.0, accuracy: 1e-9, "削除後の合成尺に追随していない")

        model.removeClip(id: second.id)
        XCTAssertEqual(model.clips.count, 1, "最後の 1 本が消えてタイムラインが空になった")
    }

    /// moveClip で並べ替えが反映されること。
    func test_moveClip_reordersClips() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 6)
        model.setClipsForTesting([first, second])

        model.moveClip(id: second.id, toIndex: 0)

        XCTAssertEqual(model.clips.map(\.id), [second.id, first.id])
    }

    /// setClipRate が合成尺（videoDuration）へ波及すること
    /// （seekTo 等の `position * videoDuration` が正しい合成時刻になる前提）。
    func test_setClipRate_updatesVideoDurationToScaledTotal() {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        model.setClipRate(id: clip.id, rate: 2.0)

        XCTAssertEqual(model.clips[0].rate, 2.0, accuracy: 1e-9)
        XCTAssertEqual(model.videoDuration, 5.0, accuracy: 1e-9,
                       "rate 変更後の合成尺（mapping.totalDuration）に追随していない")
    }

    /// trimClip が素材使用範囲と合成尺を更新すること。
    func test_trimClip_updatesRangeAndDuration() {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        model.trimClip(id: clip.id, sourceStart: 2, sourceEnd: 6)

        XCTAssertEqual(model.clips[0].sourceStart, 2, accuracy: 1e-9)
        XCTAssertEqual(model.clips[0].sourceEnd, 6, accuracy: 1e-9)
        XCTAssertEqual(model.videoDuration, 4.0, accuracy: 1e-9)
    }

    // MARK: - 世代トークン（ライブ検出の in-flight 破棄）

    /// タイムライン編集を跨いだライブ検出結果（旧世代の合成時刻）が破棄されること。
    /// 旧タイムラインのフレームを新しい写像でキーすると、誤った素材時刻に正規の
    /// 検出として記録される（S3 レビューの観測事項）。
    func test_staleGenerationLiveDetection_isDiscarded() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let staleGeneration = model.timelineGeneration

        // 検出中にタイムラインが変わった（並べ替え等で写像が変化した）状況
        model.setClipsForTesting([
            TimelineClip(sourceID: source, sourceStart: 6, sourceEnd: 10),
            TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        ])
        XCTAssertGreaterThan(model.timelineGeneration, staleGeneration,
                             "タイムライン変更で世代トークンが進んでいない")

        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace()], bridgedByFlow: false),
            at: 1.0, source: UIImage(), generation: staleGeneration)

        XCTAssertTrue(model.cacheStore.isEmpty,
                      "旧世代の検出結果が新しい写像のキーで記録された（キャッシュ汚染）")
        XCTAssertFalse(model.liveDetectionInFlight,
                       "破棄時に in-flight ガードが解除されず以降の検出が止まる")

        // 現行世代のトークンなら通常どおり記録される
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace()], bridgedByFlow: false),
            at: 1.0, source: UIImage(), generation: model.timelineGeneration)
        XCTAssertFalse(model.cacheStore.isEmpty, "現行世代の検出結果まで破棄されている")
    }

    // MARK: - rebuildComposition の世代トークン（実素材）

    /// テスト用に指定秒数の単色動画を生成する（外部素材に依存しない）。
    private func makeTestVideo(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * 240)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func waitUntilLoaded(_ model: MosaicEditorModel,
                                 timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoading {
            if Date() > deadline {
                XCTFail("動画の読み込みが \(timeout)s 以内に完了しない")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 世代トークンが古い rebuild は結果を破棄し、composition を差し替えないこと
    /// （連打編集で古い合成結果が新しい状態を上書きする回帰の防止）。
    func test_rebuildComposition_discardsStaleGeneration() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let original = try XCTUnwrap(model.composition, "読み込み完了後は composition があるはず")
        let staleGeneration = model.timelineGeneration

        // rebuild の await 中にタイムラインが再度変わった状況: 世代を進めてから
        // 旧世代トークンで rebuild を呼ぶ。
        let sourceID = try XCTUnwrap(model.clips.first).sourceID
        model.setClipsForTesting([TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 0.5)])
        await model.rebuildComposition(generation: staleGeneration, keepingCompositionSeconds: nil)
        XCTAssertTrue(model.composition === original,
                      "旧世代の rebuild が composition を差し替えている")

        // 現行世代の rebuild は差し替える
        await model.rebuildComposition()
        XCTAssertFalse(model.composition === original, "現行世代の rebuild が破棄されている")
        XCTAssertEqual(model.videoDuration, 0.5, accuracy: 0.05)
    }

    // MARK: - trimClip の素材尺クランプ（実素材）

    /// 素材尺を超える sourceEnd（100s や +∞）が素材尺にクランプされること。
    /// クランプ無しだと「1s 素材から 100s のクリップ」が無言で成立し、実体のない
    /// 区間を含む壊れた composition ができる（S4 レビューの実測）。
    func test_trimClip_clampsSourceEndToAssetDuration() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let clip = try XCTUnwrap(model.clips.first)
        let sourceDuration = clip.sourceEnd  // load 時の素材全長クリップ

        model.trimClip(id: clip.id, sourceStart: 0.2, sourceEnd: 100)

        XCTAssertEqual(model.clips[0].sourceStart, 0.2, accuracy: 1e-9)
        XCTAssertEqual(model.clips[0].sourceEnd, sourceDuration, accuracy: 0.1,
                       "素材尺を超える sourceEnd がクランプされていない")
        XCTAssertTrue(model.videoDuration.isFinite)
        XCTAssertEqual(model.videoDuration, sourceDuration - 0.2, accuracy: 0.1)

        // +∞ も同じ経路でクランプされ、写像を汚染しない
        model.trimClip(id: model.clips[0].id, sourceStart: 0, sourceEnd: .infinity)
        XCTAssertEqual(model.clips[0].sourceEnd, sourceDuration, accuracy: 0.1)
        XCTAssertTrue(model.mapping.totalDuration.isFinite,
                      "∞ トリムで mapping.totalDuration が非有限になった")
    }

    // MARK: - 編集直後の export（rebuild レース）

    /// 編集直後の「mapping は新・composition は旧」の窓で、awaitPendingTimelineRebuild が
    /// rebuild 完了まで待ち、mapping と composition が同一世代・同一尺で揃うこと
    /// （exportVideo はこの await を経てから書き出す）。
    func test_awaitPendingRebuild_alignsCompositionWithMapping() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let clip = try XCTUnwrap(model.clips.first)

        model.setClipRate(id: clip.id, rate: 2.0)
        // 直後は不整合の窓: 世代トークンで検出できる状態になっている
        XCTAssertNotEqual(model.compositionGeneration, model.timelineGeneration,
                          "編集直後に composition が旧世代であることを検出できない")

        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "rebuild 完了後も世代が揃わない")
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), model.mapping.totalDuration,
                       accuracy: 0.05,
                       "await 後の composition が新しい mapping と尺で一致しない")
        XCTAssertEqual(model.mapping.totalDuration, 0.5, accuracy: 0.05)
    }

    /// load の build 中に編集が割り込んでも、stale な composition に新世代が刻まれず、
    /// 最終的に mapping と composition が現行世代・同一尺で揃うこと。
    /// 修正前は build 後に「現在の」世代を刻んでいたため、旧クリップ列（1.0s）の
    /// composition が新世代を持ち、exportVideo の世代照合が素通しになっていた。
    func test_editDuringLoadBuild_doesNotStampStaleComposition() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)

        // load 内 Task が timeline をセットした直後（= build の await 中）を狙って
        // 編集を割り込ませる。clips の出現は timeline セットと同時で、その後
        // build の await まで同期区間なので、ここで観測できた時点で build は未完了。
        let deadline = Date().addingTimeInterval(30)
        while model.clips.isEmpty {
            if Date() > deadline {
                XCTFail("load が 30s 以内に timeline をセットしない")
                return
            }
            await Task.yield()
        }
        let clip = model.clips[0]
        model.trimClip(id: clip.id, sourceStart: 0, sourceEnd: 0.4)

        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "load 割り込み後に世代が揃わない（stale 刻印 or 再構築漏れ）")
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), model.mapping.totalDuration,
                       accuracy: 0.05,
                       "stale な composition（旧クリップ列）が現行世代として残っている")
        XCTAssertEqual(model.mapping.totalDuration, 0.4, accuracy: 0.05)
    }

    // MARK: - Undo/Redo × タイムライン（S5）

    /// タイムライン編集（split / setRate）が undo/redo でクリップ ID・順序・rate まで
    /// 完全復元されること（EditSnapshot に timeline を追加した S5 の中核仕様）。
    func test_timelineEdit_undoRedo_restoresClipsExactly() {
        let model = makeModel()
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        model.commitEdit()   // load の resetHistory 相当（履歴基準を確立）
        XCTAssertFalse(model.canUndo)

        model.playbackPosition = 0.3
        model.splitAtCurrentPosition()
        XCTAssertTrue(model.canUndo, "タイムライン編集が履歴に積まれていない")
        let splitState = model.timeline
        XCTAssertEqual(splitState.clips.count, 2)

        model.setClipRate(id: splitState.clips[1].id, rate: 2.0)
        let ratedState = model.timeline

        model.undo()
        XCTAssertEqual(model.timeline, splitState, "undo が rate 変更を戻していない")
        model.undo()
        XCTAssertEqual(model.timeline.clips, [clip],
                       "undo でクリップ ID を含む完全な状態復元ができていない")
        XCTAssertFalse(model.canUndo)

        model.redo()
        XCTAssertEqual(model.timeline, splitState)
        model.redo()
        XCTAssertEqual(model.timeline, ratedState,
                       "redo がクリップ ID・順序・rate を完全復元していない")
        XCTAssertEqual(model.timeline.clips[1].rate, 2.0, accuracy: 1e-9)
        XCTAssertFalse(model.canRedo)
    }

    /// trimRange（書き出し範囲）の変更が履歴に積まれ、undo/redo で復元されること。
    func test_trimRangeChange_isUndoable() {
        let model = makeModel()
        model.commitEdit()   // 履歴基準（trimRange 0...1）

        model.trimRange = 0.2...0.8
        model.commitEdit()   // トリムハンドルの DragGesture.onEnded 相当

        model.undo()
        XCTAssertEqual(model.trimRange, 0...1)
        model.redo()
        XCTAssertEqual(model.trimRange, 0.2...0.8)
    }

    /// undo 連打 × 非同期 rebuild のレース: 各 undo が世代を進めて先行 rebuild を
    /// stale 化しても、最終的に composition が最終状態のタイムラインと同一世代・
    /// 同一尺で揃うこと（古い合成結果が現行状態を上書きしない）。
    func test_undoRapidFire_discardsStaleRebuilds() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let originalClips = model.clips
        let clipID = try XCTUnwrap(model.clips.first).id

        // 編集 2 連発 →（rebuild 完了を待たずに）undo 連打
        model.trimClip(id: clipID, sourceStart: 0, sourceEnd: 0.5)
        model.setClipRate(id: clipID, rate: 2.0)
        model.undo()
        model.undo()

        XCTAssertEqual(model.clips, originalClips, "undo 連打でクリップ列が元に戻らない")
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "undo 連打後に composition と mapping の世代が揃わない")
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), model.mapping.totalDuration,
                       accuracy: 0.05, "stale な rebuild 結果が composition に残っている")
        XCTAssertEqual(model.mapping.totalDuration, 1.0, accuracy: 0.05,
                       "undo 完了後の合成尺が元に戻っていない")
    }

    // MARK: - 下書き復元（queueTimelineRestore → load）

    /// 予約済みタイムラインが load で適用され、クリップ ID・rate・素材IDが
    /// 保存時のまま復元されること（下書き v2 の復元経路）。
    func test_queueTimelineRestore_loadAppliesSavedTimeline() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        let saved = TimelineState(clips: [
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 0.4),
            TimelineClip(sourceID: sourceID, sourceStart: 0.5, sourceEnd: 0.9, rate: 2.0)
        ])
        let model = makeModel()

        model.queueTimelineRestore(timeline: saved, sourceURLs: [sourceID: url],
                                   primarySourceID: sourceID)
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.timeline, saved,
                       "復元後のタイムラインが保存時と一致しない（クリップID・rate・順序）")
        XCTAssertEqual(model.currentSourceID, sourceID,
                       "primary 素材IDが引き継がれず、初期シード・顔サムネの帰属がずれる")
        XCTAssertFalse(model.canUndo, "復元直後が履歴基準になっていない")
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration)
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), 0.6, accuracy: 0.05,
                       "復元タイムライン（0.4s + 0.4s/2x）の合成尺で composition が構築されていない")
    }

    /// S5 レビュー Major の再現手順の恒久化: 2 素材下書きを再開し、片方のクリップを
    /// 削除して再保存しても、undo で復活し得る素材コピーが GC で消えないこと。
    /// さらに undo → 再保存で、下書きの sources が実在ファイルだけを参照すること
    /// （アーキテクチャ決定 7「素材 GC は下書き保存時のみ。セッション中は undo 用に保持」）。
    func test_draftResave_midSession_protectsSourcesNeededByUndo() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftGCProtection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let urlX = try await makeTestVideo(seconds: 1.0)
        let urlY = try await makeTestVideo(seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(at: urlX)
            try? FileManager.default.removeItem(at: urlY)
        }
        let sourceX = UUID()
        let sourceY = UUID()
        func persist(_ model: MosaicEditorModel, existing: UUID?) -> EditingDraft? {
            store.saveVideoDraft(
                existing: existing,
                sources: model.draftSources,
                sessionSourceIDs: model.sessionReferencedSourceIDs,
                timeline: model.timeline,
                faceMosaicOn: true, backgroundMosaicOn: false,
                faceBlockSize: 28, backgroundBlockSize: 28,
                manualRects: [], thumbnail: nil)
        }

        // 1. 素材 X, Y の 2 素材下書きを作成
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil,
            sources: [(id: sourceX, url: urlX), (id: sourceY, url: urlY)],
            timeline: TimelineState(clips: [
                TimelineClip(sourceID: sourceX, sourceStart: 0, sourceEnd: 0.8),
                TimelineClip(sourceID: sourceY, sourceStart: 0, sourceEnd: 0.8)
            ]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil))
        let sourceURLs = store.sourceURLs(for: draft)
        let copiedY = try XCTUnwrap(sourceURLs[sourceY])

        // 2. queueTimelineRestore + load で再開（2 クリップ復元）
        let model = makeModel()
        model.queueTimelineRestore(timeline: draft.timeline, sourceURLs: sourceURLs,
                                   primarySourceID: sourceX)
        model.load(videoURL: try XCTUnwrap(sourceURLs[sourceX]))
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 2, "2 クリップの下書きが復元されていない")

        // 3. Y のクリップを削除 → 再保存: source-Y は undo で復活し得るので残ること
        let clipY = try XCTUnwrap(model.clips.first { $0.sourceID == sourceY })
        model.removeClip(id: clipY.id)
        XCTAssertNotNil(persist(model, existing: draft.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedY.path),
                      "undo で必要な素材コピーが下書き再保存の GC で削除された")

        // 4. undo → 再保存: sources が実在ファイルのみ参照すること
        model.undo()
        await model.awaitPendingTimelineRebuild()
        let resaved = try XCTUnwrap(persist(model, existing: draft.id))
        XCTAssertEqual(Set(resaved.sources.map(\.id)), [sourceX, sourceY],
                       "undo で復活した 2 素材が再保存に反映されていない")
        for (id, fileURL) in store.sourceURLs(for: resaved) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                          "再保存後の下書きが存在しないファイルを参照している: \(id) → \(fileURL.lastPathComponent)")
        }
    }

    /// 正規経路外でタイムラインだけが変わり rebuild が走っていない場合、
    /// exportVideo が不整合（composition 旧世代）を検出して安全側に倒れること
    /// （旧 composition を新 mapping で写像した壊れた動画を書き出さない）。
    func test_exportVideo_refusesStaleCompositionGeneration() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let sourceID = try XCTUnwrap(model.clips.first).sourceID

        // テストバックドアで世代だけ進める（applyTimelineEdit を通らないので
        // rebuild タスクは積まれない = 不整合が残る）
        model.setClipsForTesting([TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 0.5)])

        await model.exportVideo()

        XCTAssertNotNil(model.errorMessage, "不整合な composition のまま書き出しが進んだ")
        XCTAssertNil(model.exportProgress)
    }
}

/// S5: `EditingDraft` v2（sources + timeline）と `DraftStore` の複数素材コピー/GC のテスト。
///
/// 新規テストファイルは `xcodegen generate`（禁止: CocoaPods 統合が消える）無しでは
/// MaskMeTests ターゲットに入らないため、このファイルに別クラスとして同居させている。
@MainActor
final class DraftStoreV2Tests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStoreV2Tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore() -> DraftStore {
        DraftStore(directory: tempDir.appendingPathComponent("Drafts", isDirectory: true))
    }

    /// ダミーの素材ファイル（保存対象の URL）を作る。
    private func makeSourceFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    private func draftsDirContents(of store: DraftStore) -> Set<String> {
        let dir = tempDir.appendingPathComponent("Drafts")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    // MARK: - 旧スキーマ（v1）互換デコード

    /// v1 JSON（sources / timeline キー無し・旧 faceEnabled / blockSize）が
    /// 「素材全体 1 クリップ」相当（sources 1 件 + 空 timeline）に合成されること。
    func test_v1JSON_decodesIntoSingleSourceAndEmptyTimeline() throws {
        let json = """
        {"id":"7F9C8E5A-1111-2222-3333-444455556666",
         "kind":"video",
         "sourceFileName":"source-OLD.mov",
         "faceEnabled":false,
         "blockSize":40}
        """
        let draft = try JSONDecoder().decode(EditingDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.sources.count, 1, "v1 の唯一の素材が sources に合成されていない")
        XCTAssertEqual(draft.sources.first?.fileName, "source-OLD.mov")
        XCTAssertEqual(draft.primarySource?.fileName, "source-OLD.mov")
        XCTAssertTrue(draft.timeline.clips.isEmpty,
                      "v1 に timeline は無い（空 = 素材全体 1 クリップとして復元される）")
        // 旧フィールドの引き継ぎ（既存互換）も維持されていること
        XCTAssertFalse(draft.faceMosaicOn)
        XCTAssertEqual(draft.faceBlockSize, 40)
        XCTAssertFalse(draft.backgroundMosaicOn)
    }

    // MARK: - v2 round-trip

    /// 保存 → 別インスタンスで再読込したとき、タイムライン（クリップ ID・rate・順序）と
    /// 複数素材のメタ・コピー済みファイルが完全に復元されること。
    func test_v2Draft_roundTripsTimelineAndSources() throws {
        let store = makeStore()
        let url1 = try makeSourceFile("clip1.mov")
        let url2 = try makeSourceFile("clip2.mov")
        let source1 = UUID()
        let source2 = UUID()
        let timeline = TimelineState(clips: [
            TimelineClip(sourceID: source1, sourceStart: 0, sourceEnd: 3),
            TimelineClip(sourceID: source2, sourceStart: 1, sourceEnd: 2, rate: 2.5),
            TimelineClip(sourceID: source1, sourceStart: 5, sourceEnd: 8)
        ])

        let draft = store.saveVideoDraft(
            existing: nil,
            sources: [(id: source1, url: url1), (id: source2, url: url2)],
            timeline: timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        XCTAssertNotNil(draft)

        let reloaded = makeStore()   // 同じディレクトリを読む別インスタンス
        let restored = try XCTUnwrap(reloaded.videoDrafts.first)
        XCTAssertEqual(restored.timeline, timeline,
                       "タイムラインがクリップ ID・rate・順序まで round-trip しない")
        XCTAssertEqual(restored.sources.map(\.id), [source1, source2])
        XCTAssertEqual(restored.primarySource?.id, source1, "先頭素材が primary になっていない")
        for (id, fileURL) in reloaded.sourceURLs(for: restored) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                          "素材コピー \(id) が存在しない")
        }
    }

    // MARK: - GC 安全性

    /// 参照が外れた素材コピーは保存時に GC され、複数下書きが共有する素材と
    /// 保存中の下書きが参照する素材は誤削除されないこと。
    func test_gc_removesUnreferencedSources_keepsSharedOnes() throws {
        let store = makeStore()
        let sharedURL = try makeSourceFile("shared.mov")
        let soloURL = try makeSourceFile("solo.mov")
        let shared = UUID()
        let solo = UUID()
        let sharedClip = TimelineClip(sourceID: shared, sourceStart: 0, sourceEnd: 2)
        let soloClip = TimelineClip(sourceID: solo, sourceStart: 0, sourceEnd: 2)

        // draftA: shared + solo の 2 素材 / draftB: shared のみ（共有ケース）
        let draftA = store.saveVideoDraft(
            existing: nil,
            sources: [(id: shared, url: sharedURL), (id: solo, url: soloURL)],
            timeline: TimelineState(clips: [sharedClip, soloClip]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        let draftB = store.saveVideoDraft(
            existing: nil,
            sources: [(id: shared, url: sharedURL)],
            timeline: TimelineState(clips: [sharedClip]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        let sharedName = "source-\(shared.uuidString).mov"
        let soloName = "source-\(solo.uuidString).mov"
        XCTAssertTrue(draftsDirContents(of: store).isSuperset(of: [sharedName, soloName]))

        // draftA を「solo クリップを削除した状態」で上書き保存 → solo のコピーだけ GC
        let updatedA = store.saveVideoDraft(
            existing: draftA?.id,
            sources: [(id: shared, url: sharedURL)],
            timeline: TimelineState(clips: [sharedClip]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        XCTAssertEqual(updatedA?.id, draftA?.id)
        var contents = draftsDirContents(of: store)
        XCTAssertFalse(contents.contains(soloName), "未参照になった素材コピーが GC されない")
        XCTAssertTrue(contents.contains(sharedName), "参照中の素材コピーが誤削除された")

        // draftA 削除 → shared は draftB がまだ参照しているので残る
        if let updatedA { store.removeVideoDraft(updatedA) }
        contents = draftsDirContents(of: store)
        XCTAssertTrue(contents.contains(sharedName),
                      "共有素材が、他の下書きの参照を無視して削除された")

        // draftB も削除 → 参照ゼロになった shared が消える
        if let draftB { store.removeVideoDraft(draftB) }
        contents = draftsDirContents(of: store)
        XCTAssertFalse(contents.contains(sharedName), "参照ゼロの素材コピーが残留する")
    }

    /// 再保存の GC が、セッション保護リスト（undo で復活し得る素材ID）に載った
    /// 素材コピーを削除しないこと。保護リスト未指定（既定）の経路では従来どおり
    /// 未参照コピーが GC されること。
    func test_gc_keepsSessionProtectedSources() throws {
        let store = makeStore()
        let urlX = try makeSourceFile("x.mov")
        let urlY = try makeSourceFile("y.mov")
        let sourceX = UUID()
        let sourceY = UUID()
        let clipX = TimelineClip(sourceID: sourceX, sourceStart: 0, sourceEnd: 2)
        let clipY = TimelineClip(sourceID: sourceY, sourceStart: 0, sourceEnd: 2)
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil,
            sources: [(id: sourceX, url: urlX), (id: sourceY, url: urlY)],
            timeline: TimelineState(clips: [clipX, clipY]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil))
        let copiedX = try XCTUnwrap(store.sourceURLs(for: draft)[sourceX])
        let nameY = "source-\(sourceY.uuidString).mov"

        // Y のクリップ削除相当の再保存でも、保護リストに載った Y のコピーは残る
        _ = store.saveVideoDraft(
            existing: draft.id,
            sources: [(id: sourceX, url: copiedX)],
            sessionSourceIDs: [sourceX, sourceY],
            timeline: TimelineState(clips: [clipX]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        XCTAssertTrue(draftsDirContents(of: store).contains(nameY),
                      "セッションが undo 用に参照中の素材コピーが GC された")

        // 保護リスト無し（既定）の再保存では、未参照になった Y のコピーは GC される
        _ = store.saveVideoDraft(
            existing: draft.id,
            sources: [(id: sourceX, url: copiedX)],
            timeline: TimelineState(clips: [clipX]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        XCTAssertFalse(draftsDirContents(of: store).contains(nameY),
                       "保護リスト未指定でも未参照コピーが GC されない（既定経路の退行）")
    }

    /// 防波堤: 下書きフォルダ内 URL でも実体が無ければ参照登録せず、保存自体を
    /// 失敗させること（存在しない source-* を参照する壊れた下書きを作らない）。
    func test_save_withMissingDraftFolderSource_failsInsteadOfDanglingReference() throws {
        let store = makeStore()
        let sourceID = UUID()
        let missingURL = tempDir.appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("source-\(sourceID.uuidString).mov")
        let draft = store.saveVideoDraft(
            existing: nil,
            sources: [(id: sourceID, url: missingURL)],
            timeline: TimelineState(clips: [
                TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
            ]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil)
        XCTAssertNil(draft, "存在しないフォルダ内素材を参照する壊れた下書きが保存された")
        XCTAssertTrue(store.videoDrafts.isEmpty)
    }

    /// 下書きフォルダ内のファイル（下書き再開で読み込んだ素材）を再保存しても
    /// 二重コピーせず、そのまま参照し続けること（v1 命名の下書き再開の互換経路）。
    func test_resave_ofDraftFolderSource_reusesFileInPlace() throws {
        let store = makeStore()
        let externalURL = try makeSourceFile("original.mov")
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil,
            sources: [(id: sourceID, url: externalURL)],
            timeline: TimelineState(clips: [clip]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil))

        // 再開相当: 下書きフォルダ内のコピーを素材 URL として再保存
        let copiedURL = try XCTUnwrap(store.sourceURLs(for: draft)[sourceID])
        let newSourceID = UUID()   // 再ロードで素材IDは新規発行される
        let resaved = try XCTUnwrap(store.saveVideoDraft(
            existing: draft.id,
            sources: [(id: newSourceID, url: copiedURL)],
            timeline: TimelineState(clips: [
                TimelineClip(sourceID: newSourceID, sourceStart: 0, sourceEnd: 1)
            ]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            manualRects: [], thumbnail: nil))

        XCTAssertEqual(resaved.sources.first?.fileName, copiedURL.lastPathComponent,
                       "フォルダ内素材が別名で二重コピーされた")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path),
                      "参照し続けるはずの素材コピーが消えた")
    }
}
