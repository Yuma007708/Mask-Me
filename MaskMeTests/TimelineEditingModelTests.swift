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
