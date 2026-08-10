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
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // **「顔モザイクをかける」までを再現する。** 動画モードの既定は OFF
        // （開いただけでは掛からない）で、ライブ検出も描画も `faceMosaicOn` を見ている。
        // 既定そのものを検証したいテストは `MosaicReapplyFlowTests` にある。
        model.faceMosaicOn = true
        return model
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

    /// 実機報告の再現手当て: クリップを分割した直後、**別の（分割していない）クリップ**を
    /// 選び直せること。View 層（`TimelineClipBandView` のタップ・トリムハンドルの
    /// ヒットテスト）を経由しないモデル層だけの経路（`timelineSelection.selectClip` を
    /// 直接呼ぶ）で検証する。ここが落ちれば選択の相互排他／`prune` 側の欠陥、
    /// 通れば View 層（ジェスチャ・ヒットテスト）を疑う切り分けに使う。
    func test_splitClip_thenSelectingAnotherClip_updatesSelection() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        // first の中ほど（合成 1.0s）で分割する。first.id は前半へ引き継がれる
        // （`TimelineState.splitting(at:)` の doc 参照）。
        model.playbackPosition = 1.0 / 8.0
        model.timelineSelection.selectClip(first.id)

        model.splitClip(id: first.id)

        XCTAssertEqual(model.clips.count, 3, "分割でクリップが3本になっていない")
        XCTAssertEqual(model.timelineSelection.clipID, first.id,
                       "分割直後は前半（id 継承）が選ばれたままのはず")

        // 分割で新たに増えた・関係しない `second` を選び直す。
        model.timelineSelection.selectClip(second.id)

        XCTAssertEqual(model.timelineSelection.clipID, second.id,
                       "分割後に別のクリップへ選択を移せていない（モデル層の欠陥）")
        XCTAssertNil(model.timelineSelection.layer,
                     "クリップ選択でレイヤー選択が残っている（相互排他の欠陥）")
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

    /// 並べ替え後、再生位置が**動かしたクリップを追いかける**こと。
    ///
    /// 合成時刻を据え置くと、並べ替えでその時刻に別のクリップが来るため、掴んでいた
    /// クリップが画面から消えて別の映像が映る（実機で確認された挙動）。
    func test_moveClip_playheadFollowsMovedClip() async {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 6)
        model.setClipsForTesting([first, second])
        // 合成尺 4s。second は [2,4) にいるので、その 0.5 秒目 = 合成 2.5s を見ている。
        model.playbackPosition = 2.5 / 4.0

        model.moveClip(id: second.id, toIndex: 0)
        await model.awaitPendingTimelineRebuild()

        // second は先頭 [0,2) へ移ったので、同じ 0.5 秒目 = 合成 0.5s。
        let composition = model.playbackPosition * model.videoDuration
        XCTAssertEqual(composition, 0.5, accuracy: 1e-6,
                       "再生位置が動かしたクリップを追いかけていない")
        let location = model.timeline.mapping.sourceLocation(at: composition)
        XCTAssertEqual(location?.clipID, second.id, "並べ替え後に別のクリップを指している")
        XCTAssertEqual(location?.time ?? -1, 4.5, accuracy: 1e-6,
                       "素材時刻が並べ替え前（4.5s）とずれている")
    }

    /// 再生位置が動かしたクリップの**外**にいたときは、合成時刻を据え置くこと。
    func test_moveClip_playheadStaysWhenOutsideMovedClip() async {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 6)
        model.setClipsForTesting([first, second])
        model.playbackPosition = 0.5 / 4.0   // first の中（合成 0.5s）

        model.moveClip(id: second.id, toIndex: 0)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.playbackPosition * model.videoDuration, 0.5, accuracy: 1e-6,
                       "対象クリップ外の再生位置が動いている")
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
    ///
    /// **注意: この機能には S9 現在ユーザー操作からの到達経路が無い**
    /// （全体 In/Out トリム UI はクリップ単位のトリムへ置き換わった。
    /// `MosaicEditorModel.trimRange` の doc 参照）。将来の再導入に備えて
    /// スナップショットへの載せ方だけを固定しているテストであり、
    /// 「UI から触れる機能を守っている」と読まないこと。
    func test_trimRangeChange_isUndoable() {
        let model = makeModel()
        model.commitEdit()   // 履歴基準（trimRange 0...1）

        model.trimRange = 0.2...0.8
        model.commitEdit()   // 直接代入（UI 経路は無い）

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

    /// 8px 市松（黒/白）のテスト動画。**単色素材ではモザイクの有無が画素に出ない**ため、
    /// ブロックモザイクが平均化で必ず潰す高周波パターンを使う。
    ///
    /// - Parameter checkerFrom: この素材時刻より前のフレームは白一色にする。
    ///   「プレビューが素材の先頭フレームを描いたのか、合成タイムラインの現在位置を
    ///   描いたのか」を平均輝度だけで区別するために使う（白 255 / 市松 ≈127）。
    private func makeCheckerboardVideo(seconds: Double, checkerFrom: Double = 0) async throws -> URL {
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
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let isChecker = Double(i) / Double(fps) >= checkerFrom
                for y in 0..<240 {
                    for x in 0..<320 {
                        let value: UInt8 = !isChecker ? 255
                            : (((x / 8) + (y / 8)) % 2 == 0 ? 0 : 255)
                        let offset = y * bytesPerRow + x * 4
                        base[offset] = value
                        base[offset + 1] = value
                        base[offset + 2] = value
                        base[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 画像中央の正方形パッチ（辺の 1/4）の輝度の平均と標準偏差。
    /// 素の市松は std が高い（≈127）、ブロックモザイクが乗ると平均化されて 0 に落ちる。
    /// 平均は「白一色の区間（255）を描いたのか市松の区間（≈127）を描いたのか」の判別に使う。
    private func centerPatchStats(of image: UIImage) throws -> (mean: Double, stdDev: Double) {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var values: [Double] = []
        for y in (3 * h / 8)..<(5 * h / 8) {
            for x in (3 * w / 8)..<(5 * w / 8) {
                values.append(Double(pixels[(y * w + x) * 4]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// 下書きを復元して**再生もシークもせず放置した初期プレビュー**が、
    /// 復元したタイムライン（適用区間・クリップの使用範囲）を反映していること。
    ///
    /// 修正前は、復元タイムラインが載る前に走り終わった `renderPreview()`
    /// （合成前の**素材の先頭フレーム**に対する暫定表示。適用区間もクリップのトリムも
    /// 反映されない）が残り続けていた。displayLink は `play()` でしか回らないので
    /// 描き直す機会が無く、ユーザーが再生/シークするまで誤った初期画が消えなかった
    /// （実測: previewImage 中央画素 [127,127,127]＝モザイク、シーク後に
    /// [255,255,255]＝素の映像）。一般的な動画編集アプリと同様、開いた時点で
    /// 現在の編集状態どおりの絵が出ていなければならない。
    func test_draftRestore_initialPreviewReflectsRestoredTimeline() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let centerRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

        /// 実アプリ（`EditorView.loadMedia`）と同じ順序で下書きを再開する:
        /// queueTimelineRestore → load(videoURL:) →（必要なら）applyRestoredParameters。
        /// 再開後は**再生もシークもせず 2 秒放置**して初期プレビューを観測する。
        func restore(url: URL, clip: (UUID) -> TimelineClip,
                     applyRanges: (TimelineClip) -> [MosaicApplyRange],
                     restoreParameters: Bool) async throws -> MosaicEditorModel {
            let model = makeModel()
            let sourceID = UUID()
            let restored = clip(sourceID)
            var saved = TimelineState(clips: [restored])
            saved.applyRanges = applyRanges(restored)
            model.queueTimelineRestore(timeline: saved, sourceURLs: [sourceID: url],
                                       primarySourceID: sourceID)
            model.load(videoURL: url)
            if restoreParameters {
                model.applyRestoredParameters(faceMosaicOn: true, backgroundMosaicOn: false,
                                              faceBlockSize: 48, backgroundBlockSize: 28,
                                              objectMasks: [], legacyManualRects: [centerRect])
            }
            try await waitUntilLoaded(model)
            await model.awaitPendingTimelineRebuild()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return model
        }

        // --- A) 適用区間が初期プレビューに効いていること -------------------------
        let checker = try await makeCheckerboardVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: checker) }
        func wholeClip(_ source: UUID) -> TimelineClip {
            TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 2)
        }

        // 対照: クリップ全体を覆う区間 → 中央の手動矩形にモザイクが乗る（＝計測系が効いている）。
        // S11 で「区間 0 本 = 全区間 OFF」になったので、対照は全体区間で作る。
        let ungated = try await restore(url: checker, clip: wholeClip,
                                        applyRanges: { MosaicApplyGate.fullCoverRanges(for: [$0], photoSourceIDs: []) },
                                        restoreParameters: true)
        let ungatedStats = try centerPatchStats(of: try XCTUnwrap(
            ungated.previewImage, "初期プレビューが描かれていない"))

        // 本題: 再生位置 0 は復元した適用区間 [1,2) の外 → 素の映像でなければならない。
        let gated = try await restore(
            url: checker, clip: wholeClip,
            applyRanges: { [MosaicApplyRange(clipID: $0.id, sourceID: $0.sourceID,
                                             sourceStart: 1, sourceEnd: 2)] },
            restoreParameters: true)
        XCTAssertEqual(gated.playbackPosition, 0, accuracy: 0.05, "再生位置が 0 から動いている")
        XCTAssertFalse(gated.isMosaicActive(atComposition: 0), "前提が崩れている（区間内になっている）")
        let gatedStats = try centerPatchStats(of: try XCTUnwrap(
            gated.previewImage, "初期プレビューが描かれていない"))

        XCTAssertLessThan(ungatedStats.stdDev, 60.0,
                          "対照実験で中央にモザイクが観測できない（計測系が壊れている）"
                          + " std=\(ungatedStats.stdDev)")
        XCTAssertGreaterThan(gatedStats.stdDev, 90.0,
                             "下書き復元直後の初期プレビューが適用区間を無視してモザイクを描いている"
                             + " std=\(gatedStats.stdDev)（対照 \(ungatedStats.stdDev)）")

        // --- B) 初期プレビューが**合成タイムラインの現在位置**から描かれていること ---
        //
        // A だけでは足りない: `applyRestoredParameters` が @Published を書き換えるため、
        // `bindControls` の 16ms デバウンス経由で `previewController?.invalidate()` が
        // 走り、タイミング次第で結果的に正しい絵になってしまう（実測でそうなった）。
        // ここは効果パラメータを一切触らない＝デバウンスが発火しない経路で、
        // 「暫定表示（素材の先頭フレーム）」と「合成の現在位置」を平均輝度で区別する。
        // 素材の先頭 1 秒は白一色（平均 255）、復元クリップが使う [1,2) は市松（平均 ≈127）。
        let split = try await makeCheckerboardVideo(seconds: 2.0, checkerFrom: 1.0)
        defer { try? FileManager.default.removeItem(at: split) }
        let trimmed = try await restore(
            url: split,
            clip: { TimelineClip(sourceID: $0, sourceStart: 1, sourceEnd: 2) },
            applyRanges: { MosaicApplyGate.fullCoverRanges(for: [$0], photoSourceIDs: []) }, restoreParameters: false)
        let trimmedStats = try centerPatchStats(of: try XCTUnwrap(
            trimmed.previewImage, "初期プレビューが描かれていない"))
        XCTAssertEqual(trimmedStats.mean, 127.5, accuracy: 20.0,
                       "初期プレビューが素材の先頭フレーム（白一色）のままで、"
                       + "復元タイムラインの現在位置が描かれていない mean=\(trimmedStats.mean)")
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
                objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil))
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

    // MARK: - S9: トランジション編集 API（UI から到達可能になった経路）

    /// 2 クリップ状態を作る（sources は存在確認だけに使われる stub）。
    private func makeTwoClipModel() -> (MosaicEditorModel, TimelineClip, TimelineClip) {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        model.setTimelineForTesting(TimelineState(clips: [clipA, clipB]))
        let stub = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        model.sources = [sourceA: stub, sourceB: stub]
        model.commitEdit()   // 履歴基準
        return (model, clipA, clipB)
    }

    /// トランジションの設定が合成尺・世代・履歴に反映されること。
    func test_setTransition_appliesClampsAndIsUndoable() {
        let (model, clipA, _) = makeTwoClipModel()
        let generationBefore = model.timelineGeneration
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9)

        // 上限 min(4, 6)/2 = 2.0 を超える指定はクランプされる。
        model.setTransition(afterClipID: clipA.id, kind: .crossfade, duration: 5.0)

        XCTAssertEqual(model.timeline.transitions[clipA.id]?.kind, .crossfade)
        XCTAssertEqual(model.timeline.transitions[clipA.id]?.duration ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(model.videoDuration, 8.0, accuracy: 1e-9, "重なりぶん合成尺が縮んでいない")
        XCTAssertGreaterThan(model.timelineGeneration, generationBefore)
        XCTAssertTrue(model.timeline.validate())

        XCTAssertTrue(model.canUndo, "トランジション設定が履歴に積まれていない")
        model.undo()
        XCTAssertTrue(model.timeline.transitions.isEmpty)
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(model.timeline.transitions[clipA.id]?.duration ?? -1, 2.0, accuracy: 1e-9)
    }

    /// 種類の差し替えと削除。設定できない境界（末尾クリップ）は no-op で世代も進めない。
    func test_setTransition_replaceRemoveAndNoOp() {
        let (model, clipA, clipB) = makeTwoClipModel()
        model.setTransition(afterClipID: clipA.id, kind: .crossfade, duration: 1.0)
        model.setTransition(afterClipID: clipA.id, kind: .wipeRight, duration: 1.0)
        XCTAssertEqual(model.timeline.transitions[clipA.id]?.kind, .wipeRight)

        let generation = model.timelineGeneration
        model.setTransition(afterClipID: clipB.id, kind: .crossfade, duration: 1.0)
        XCTAssertEqual(model.timelineGeneration, generation, "末尾クリップへの設定で世代が進んだ")
        model.removeTransition(afterClipID: clipB.id)
        XCTAssertEqual(model.timelineGeneration, generation, "無いトランジションの削除で世代が進んだ")

        model.removeTransition(afterClipID: clipA.id)
        XCTAssertTrue(model.timeline.transitions.isEmpty)
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9)
    }

    /// 下書き（`TimelineState` の Codable）にトランジションが載ること。
    func test_transition_survivesDraftRoundTrip() throws {
        let (model, clipA, _) = makeTwoClipModel()
        model.setTransition(afterClipID: clipA.id, kind: .slideLeft, duration: 1.5)

        let data = try JSONEncoder().encode(model.timeline)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, model.timeline)
        XCTAssertEqual(decoded.transitions[clipA.id]?.kind, .slideLeft)
    }

    // MARK: - S9: モザイク適用区間の編集 API

    /// 合成時刻で追加した区間が素材アンカーで保存され、undo/redo に載ること。
    func test_addMosaicApplyRange_storesSourceAnchorsAndIsUndoable() throws {
        let (model, clipA, clipB) = makeTwoClipModel()

        // 合成 [3, 5) は clipA の [3,4) と clipB の [0,1) に分解される。
        model.addMosaicApplyRange(fromCompositionTime: 3, to: 5)

        XCTAssertEqual(model.timeline.applyRanges.count, 2)
        let forA = try XCTUnwrap(model.timeline.applyRanges.first { $0.sourceID == clipA.sourceID })
        XCTAssertEqual(forA.sourceStart, 3, accuracy: 1e-9)
        XCTAssertEqual(forA.sourceEnd, 4, accuracy: 1e-9)
        let forB = try XCTUnwrap(model.timeline.applyRanges.first { $0.sourceID == clipB.sourceID })
        XCTAssertEqual(forB.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(forB.sourceEnd, 1, accuracy: 1e-9)
        XCTAssertTrue(model.timeline.validate())
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9, "区間追加が合成尺を変えてはいけない")

        model.undo()
        XCTAssertTrue(model.timeline.applyRanges.isEmpty)
        model.redo()
        XCTAssertEqual(model.timeline.applyRanges.count, 2)
    }

    /// 端ドラッグの確定（区間置き換え）と削除。
    func test_setAndRemoveMosaicApplyRange() throws {
        let (model, clipA, _) = makeTwoClipModel()
        model.addMosaicApplyRange(fromCompositionTime: 1, to: 3)
        let id = try XCTUnwrap(model.timeline.applyRanges.first).id

        model.setMosaicApplyRange(id: id, clipID: clipA.id,
                                  interval: CompositionInterval(start: 1.5, end: 2.0))
        XCTAssertEqual(model.timeline.applyRanges.count, 1)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceID, clipA.sourceID)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, 2.0, accuracy: 1e-9)

        let newID = model.timeline.applyRanges[0].id
        model.removeMosaicApplyRange(id: newID)
        XCTAssertTrue(model.timeline.applyRanges.isEmpty)
        model.undo()
        XCTAssertEqual(model.timeline.applyRanges.count, 1)
    }

    /// 区間編集の後でも composition と mapping の世代が揃うこと
    /// （揃わないと `exportVideo` が「更新が完了していません」で止まる）。
    func test_applyRangeEdit_keepsCompositionGenerationAligned() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)

        model.addMosaicApplyRange(fromCompositionTime: 0.1, to: 0.5)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.timeline.applyRanges.count, 1)
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "適用区間の編集後に composition と mapping の世代が揃わない")
    }

    // MARK: - S13: モザイク適用区間の「移動」（本体ドラッグの確定）

    /// 移動後も composition と mapping の世代が揃うこと（`setMosaicApplyRange` と同じ契約）。
    /// undo 1 回で素材アンカー（`sourceStart` / `sourceEnd`）が完全に元へ戻ること。
    func test_moveMosaicApplyRange_keepsGenerationAlignedAndIsUndoableExactly() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)

        model.addMosaicApplyRange(fromCompositionTime: 0.2, to: 0.6)
        await model.awaitPendingTimelineRebuild()
        let id = try XCTUnwrap(model.timeline.applyRanges.first).id
        let clipID = try XCTUnwrap(model.clips.first).id
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, 0.2, accuracy: 1e-9)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, 0.6, accuracy: 1e-9)

        model.moveMosaicApplyRange(id: id, clipID: clipID, byCompositionDelta: 0.3)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.timeline.applyRanges.count, 1)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, 0.9, accuracy: 1e-9)
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "区間移動後に composition と mapping の世代が揃わない")

        model.undo()
        XCTAssertEqual(model.timeline.applyRanges.count, 1)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, 0.2, accuracy: 1e-9,
                       "undo 1 回で素材アンカーが完全に元へ戻っていない")
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, 0.6, accuracy: 1e-9,
                       "undo 1 回で素材アンカーが完全に元へ戻っていない")
    }

    /// 移動しても、マージが起きない限り「帯の本数」（`TimelineBandLayout.applySpans`）と
    /// 「有効な適用区間の本数」（`MosaicApplyGate.effectiveRanges` ＝ `effectiveApplyRanges`）が
    /// 一致し続けること（不変条件 I1 が移動でも保たれる）。
    func test_moveMosaicApplyRange_bandCountMatchesEffectiveRangeCount() throws {
        let (model, clipA, _) = makeTwoClipModel()
        model.addMosaicApplyRange(fromCompositionTime: 0, to: 1)
        model.addMosaicApplyRange(fromCompositionTime: 2, to: 3)
        XCTAssertEqual(model.timeline.applyRanges.count, 2, "前提が崩れている")

        let movingID = try XCTUnwrap(
            model.timeline.applyRanges.first { $0.sourceStart == 2 }).id

        model.moveMosaicApplyRange(id: movingID, clipID: clipA.id, byCompositionDelta: 0.3)

        XCTAssertEqual(model.timeline.applyRanges.count, 2, "無関係な区間とマージしてしまった")
        let bandCount = TimelineBandLayout.applySpans(
            ranges: model.timeline.applyRanges, mapping: model.mapping,
            photoSourceIDs: model.timeline.photoSourceIDs).count
        XCTAssertEqual(bandCount, model.effectiveApplyRanges.count)
        XCTAssertEqual(bandCount, 2)
        let moved = try XCTUnwrap(model.timeline.applyRanges.first { $0.sourceStart != 0 })
        XCTAssertEqual(moved.sourceStart, 2.3, accuracy: 1e-9)
        XCTAssertEqual(moved.sourceEnd, 3.3, accuracy: 1e-9)
    }

    /// 移動した先で別の区間と隣接・重複してマージされた場合でも、移動した位置に
    /// （マージ後の）区間が解決できること。`VideoTimelineView.commitApplyMove` は移動確定後、
    /// 掴んでいたセグメントの最終位置の中点で `TimelineBandLayout.applySpans` を引き直して
    /// 選択を復元する（`reselectApplyRange` と同じ作法）ため、ここではその材料
    /// （帯の本数・掴んでいた位置に帯が存在すること）を検証する。
    func test_moveMosaicApplyRange_mergeLeavesReselectableSpanAtMovedPosition() throws {
        let (model, clipA, _) = makeTwoClipModel()
        model.addMosaicApplyRange(fromCompositionTime: 0, to: 1)
        model.addMosaicApplyRange(fromCompositionTime: 1.5, to: 2.5)
        XCTAssertEqual(model.timeline.applyRanges.count, 2, "前提が崩れている")

        let movingID = try XCTUnwrap(
            model.timeline.applyRanges.first { $0.sourceStart == 0 }).id

        // [0,1) を +0.5 動かすと [0.5,1.5) になり、隣接する [1.5,2.5) とマージされる。
        model.moveMosaicApplyRange(id: movingID, clipID: clipA.id, byCompositionDelta: 0.5)

        XCTAssertEqual(model.timeline.applyRanges.count, 1, "隣接した区間とマージされていない")
        let bandCount = TimelineBandLayout.applySpans(
            ranges: model.timeline.applyRanges, mapping: model.mapping,
            photoSourceIDs: model.timeline.photoSourceIDs).count
        XCTAssertEqual(bandCount, model.effectiveApplyRanges.count)
        XCTAssertEqual(bandCount, 1)

        // 掴んでいたセグメントの最終位置（合成 [0.5, 1.5)）の中点で選択を引き直せること。
        let near = (0.5 + 1.5) / 2
        let spans = TimelineBandLayout.applySpans(
            ranges: model.timeline.applyRanges, mapping: model.mapping,
            photoSourceIDs: model.timeline.photoSourceIDs)
        let reselected = spans.first { near >= $0.start && near < $0.end }
        XCTAssertNotNil(reselected, "マージ後、移動先の位置に選択し直せる帯が無い")
    }

    // MARK: - S10: モザイク適用区間の描画ゲート

    /// 素材時刻 `step` 刻みで顔を詰めた単一クリップのモデル（ゲート判定だけを見たいので
    /// 検出キャッシュの補間・ホールドの穴が判定に混ざらないよう密に埋める）。
    private func makeDenseFaceModel(sourceEnd: Double = 10, step: Double = 0.2,
                                    rate: Double = 1.0) -> MosaicEditorModel {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0,
                                               sourceEnd: sourceEnd, rate: rate)])
        var t = 0.0
        while t < sourceEnd {
            model.cacheStore.store([fakeFace()], sourceID: source, time: t)
            t += step
        }
        return model
    }

    /// テスト用に適用区間だけを差し替える（`timeline` の didSet 経由で
    /// `effectiveApplyRanges` も追随する）。
    private func setApplyRanges(_ model: MosaicEditorModel, _ ranges: [MosaicApplyRange]) {
        var state = model.timeline
        state.applyRanges = ranges
        model.setTimelineForTesting(state)
    }

    /// クリップ全体を覆う区間（新規プロジェクトの既定）では全フレームで顔が返り、
    /// 部分区間にすると**境界フレーム**で ON/OFF が切り替わること。
    /// 半開区間 [start, end) の `end` ちょうどは区間外。
    func test_applyRangeGate_facesSwitchAtBoundaryFrames() {
        let model = makeDenseFaceModel()
        setApplyRanges(model, MosaicApplyGate.fullCoverRanges(for: model.clips, photoSourceIDs: []))

        XCTAssertFalse(model.displayFaces(at: 1.9).isEmpty, "全体区間で顔が返っていない")
        XCTAssertFalse(model.displayFaces(at: 8.0).isEmpty)

        // S11: 区間 0 本 = 全区間 OFF。
        setApplyRanges(model, [])
        XCTAssertTrue(model.displayFaces(at: 1.9).isEmpty, "区間 0 本で顔が返っている（全区間 OFF のはず）")

        model.addMosaicApplyRange(fromCompositionTime: 2, to: 4)

        XCTAssertTrue(model.displayFaces(at: 1.9).isEmpty, "区間外にモザイクが乗っている")
        XCTAssertFalse(model.displayFaces(at: 2.0).isEmpty, "区間開始ちょうどが区間外になっている")
        XCTAssertFalse(model.displayFaces(at: 4.0.nextDown).isEmpty)
        XCTAssertTrue(model.displayFaces(at: 4.0).isEmpty,
                      "半開区間 [start, end) の end ちょうどが区間内になっている")
        XCTAssertTrue(model.displayFaces(at: 8.0).isEmpty)
    }

    /// **ゲートは lookup の後段にある**こと（区間外でも検出キャッシュは埋まり、
    /// `lookupFaces` はゲート前の生の結果を返す）。ゲートを lookup 側に入れると、
    /// 区間を後から広げたときに再検出が必要になる。
    func test_applyRangeGate_isAfterLookupAndKeepsDetectionCache() {
        let model = makeDenseFaceModel()
        model.addMosaicApplyRange(fromCompositionTime: 2, to: 4)
        let entriesBefore = model.cacheStore.count

        // 区間外の合成時刻でライブ検出を記録しても捨てられない（未検出バケットが増える）。
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.3, cy: 0.3)], bridgedByFlow: false),
            at: 7.5, source: UIImage(), generation: model.timelineGeneration)
        XCTAssertGreaterThan(model.cacheStore.count, entriesBefore,
                             "区間外でライブ検出の書き込みが捨てられている（ゲートが lookup 側に入っている）")

        // lookup はゲート前なので顔を返し、描画入口の displayFaces だけが空になる。
        XCTAssertFalse(model.lookupFaces(at: 7.0).isEmpty,
                       "区間外で検出キャッシュの参照まで止まっている")
        XCTAssertTrue(model.displayFaces(at: 7.0).isEmpty)

        // 区間を広げれば再検出なしでそのまま乗る。
        model.addMosaicApplyRange(fromCompositionTime: 6, to: 8)
        XCTAssertFalse(model.displayFaces(at: 7.0).isEmpty,
                       "区間を広げたのに既存の検出キャッシュが使われていない")
    }

    /// **速度変更されたクリップでは素材時刻で判定される**こと。
    /// rate=2 の素材 [0,10)（合成 5 秒）に合成 [1,2) を指定すると素材 [2,4) がアンカーになり、
    /// ON になるのは合成 [1,2) だけ。合成時刻で判定する誤実装なら合成 [2,4) が ON になる。
    func test_applyRangeGate_usesSourceTimeForSpeedChangedClip() {
        let model = makeDenseFaceModel(rate: 2.0)
        XCTAssertEqual(model.videoDuration, 5.0, accuracy: 1e-9, "rate の前提が崩れている")

        model.addMosaicApplyRange(fromCompositionTime: 1, to: 2)
        XCTAssertEqual(model.timeline.applyRanges.count, 1)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, 4.0, accuracy: 1e-9)

        XCTAssertFalse(model.displayFaces(at: 1.5).isEmpty, "素材時刻 3.0 が区間外と判定された")
        XCTAssertTrue(model.displayFaces(at: 3.0).isEmpty,
                      "合成時刻で判定している（rate=2 で区間の位置がずれる）")
        XCTAssertTrue(model.displayFaces(at: 0.5).isEmpty)
    }

    /// 素材時刻アンカーなので、**分割・並べ替えの後も区間が素材に追従する**こと。
    func test_applyRangeGate_followsSourceAcrossSplitAndReorder() {
        let model = makeDenseFaceModel(sourceEnd: 4)
        model.playbackPosition = 0.5          // 合成 2.0s
        model.splitAtCurrentPosition()
        XCTAssertEqual(model.clips.count, 2)
        // 後半クリップ（素材 [2,4)）だけを覆う区間。
        model.addMosaicApplyRange(fromCompositionTime: 2, to: 4)

        XCTAssertTrue(model.displayFaces(at: 1.0).isEmpty)
        XCTAssertFalse(model.displayFaces(at: 3.0).isEmpty)

        // 並べ替えると素材 [2,4) は合成 [0,2) へ移る。区間は素材に貼り付いたまま。
        model.moveClip(id: model.clips[1].id, toIndex: 0)
        XCTAssertEqual(model.timeline.applyRanges.count, 1, "並べ替えで区間が増減している")
        XCTAssertFalse(model.displayFaces(at: 1.0).isEmpty,
                       "並べ替え後に区間が素材へ追従していない")
        XCTAssertTrue(model.displayFaces(at: 3.0).isEmpty)
    }

    /// **トランジションの重なり区間では素材別にゲートが効く**こと
    /// （片方 ON・片方 OFF なら ON 側の顔だけが返る。両者をまとめて ON/OFF しない）。
    func test_applyRangeGate_isPerSourceInsideTransitionOverlap() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        let transitions = [clipA.id: TransitionSpec(kind: .crossfade, duration: 2)]
        model.setTimelineForTesting(TimelineState(clips: [clipA, clipB], transitions: transitions))
        // 合成 3.0 は重なりの中: A は素材 3.0、B は素材 1.0。
        let faceA = fakeFace(cx: 0.2, cy: 0.5)
        let faceB = fakeFace(cx: 0.8, cy: 0.5)
        model.cacheStore.store([faceA], sourceID: sourceA, time: 3.0)
        model.cacheStore.store([faceB], sourceID: sourceB, time: 1.0)
        XCTAssertEqual(model.mapping.sourceLocations(at: 3.0).count, 2, "重なり区間の前提が崩れている")
        setApplyRanges(model, MosaicApplyGate.fullCoverRanges(for: model.clips, photoSourceIDs: []))
        XCTAssertEqual(model.displayFaces(at: 3.0).count, 2, "全体区間では両素材の顔が union される")

        // B のクリップだけを適用区間にする。
        setApplyRanges(model, [MosaicApplyRange(clipID: clipB.id, sourceID: sourceB,
                                                sourceStart: 0, sourceEnd: 6)])

        let faces = model.displayFaces(at: 3.0)
        XCTAssertEqual(faces.count, 1, "重なり区間で素材別にゲートできていない")
        let centroidX = faces[0].points.reduce(0.0) { $0 + Double($1.x) } / Double(faces[0].points.count)
        XCTAssertEqual(centroidX, 0.8, accuracy: 0.05, "区間外の素材（A）の顔が返っている")
        // 重なり外の A 単独区間は完全に OFF。
        XCTAssertTrue(model.displayFaces(at: 1.0).isEmpty)
    }

    /// 素材アンカーを持たない効果（手動矩形・背景モザイク）のゲート
    /// `isMosaicActive(atComposition:)` が、プレビューとエクスポートで共有する
    /// 判定規則どおりに動くこと: 区間なし＝常に true、重なり区間は
    /// 「映っている素材のどれかが区間内なら true」。
    func test_isMosaicActiveAtComposition_gatesManualRegionsAndBackground() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        let transitions = [clipA.id: TransitionSpec(kind: .crossfade, duration: 2)]
        model.setTimelineForTesting(TimelineState(clips: [clipA, clipB], transitions: transitions))

        // 全クリップを覆う区間 → 全時刻 ON。
        setApplyRanges(model, MosaicApplyGate.fullCoverRanges(for: model.clips, photoSourceIDs: []))
        for t in stride(from: 0.0, to: 8.0, by: 0.5) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "全体区間で OFF になっている t=\(t)")
        }
        // S11: 区間 0 本 → 全時刻 OFF（旧仕様から反転）。
        setApplyRanges(model, [])
        for t in stride(from: 0.0, to: 8.0, by: 0.5) {
            XCTAssertFalse(model.isMosaicActive(atComposition: t), "区間 0 本で ON になっている t=\(t)")
        }

        setApplyRanges(model, [MosaicApplyRange(clipID: clipB.id, sourceID: sourceB,
                                                sourceStart: 0, sourceEnd: 6)])

        XCTAssertFalse(model.isMosaicActive(atComposition: 1.0), "A 単独区間で ON になっている")
        XCTAssertTrue(model.isMosaicActive(atComposition: 3.0),
                      "重なり区間で片方が区間内なのに OFF になっている")
        XCTAssertTrue(model.isMosaicActive(atComposition: 5.0))
        // 合成尺ちょうど（半開区間の外）は終端へクランプして判定する。
        XCTAssertTrue(model.isMosaicActive(atComposition: model.mapping.totalDuration))
    }

    /// **帯 0 本 ⇔ 全区間 OFF**（不変条件 I1）を、モデル層の実経路で固定する。
    ///
    /// 4 秒素材の区間 source[1,2) を左端トリム 1 回で孤児にすると、帯が 0 本になり
    /// ゲートも全時刻 OFF になる。区間データそのものは温存されるのでトリムを戻せば復活する。
    func test_applyRangeGate_orphanRangeTurnsGateOff() {
        let model = makeDenseFaceModel(sourceEnd: 4)
        model.addMosaicApplyRange(fromCompositionTime: 1, to: 2)
        XCTAssertEqual(model.effectiveApplyRanges.count, 1)
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges,
                                                     mapping: model.mapping,
                                                     photoSourceIDs: []).count, 1)
        XCTAssertTrue(model.displayFaces(at: 1.5).isEmpty == false)
        XCTAssertTrue(model.displayFaces(at: 3.0).isEmpty)

        // 左端トリムで区間はどのクリップの使用範囲とも交差しなくなる。
        model.trimClip(id: model.clips[0].id, sourceStart: 2.5, sourceEnd: 4)
        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "区間データが消えている（トリムを戻したら復活する設計を壊している）")
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges,
                                                    mapping: model.mapping,
                                                    photoSourceIDs: []).isEmpty,
                      "前提が崩れている（孤児になっていない）")
        XCTAssertTrue(model.effectiveApplyRanges.isEmpty, "孤児区間がゲートに残っている")

        // 帯 0 本 ⇔ ゲート全区間 OFF。
        for t in stride(from: 0.0, to: model.mapping.totalDuration, by: 0.05) {
            XCTAssertFalse(model.isMosaicActive(atComposition: t), "t=\(t) で ON になっている")
        }
        XCTAssertTrue(model.displayFaces(at: 1.0).isEmpty)

        // トリムを戻せば帯もゲートも復活する（区間データを温存している証拠）。
        model.trimClip(id: model.clips[0].id, sourceStart: 0, sourceEnd: 4)
        XCTAssertEqual(model.effectiveApplyRanges.count, 1)
        XCTAssertFalse(model.displayFaces(at: 1.5).isEmpty)
    }

    /// **ゲートを `shouldDetectPreviewFrame` に入れてはならない**という契約を固定する。
    ///
    /// 区間外でライブ検出が止まると「後から区間を広げたときに再検出が要る」ことになり、
    /// 「ゲートは lookup の後段・描画直前だけ」という S10 の設計目的が静かに失われる。
    /// この検証が無いと、`MosaicEditorModel+LiveDetection.swift` の
    /// `shouldDetectPreviewFrame` 冒頭に `guard isMosaicActive(...) else { return false }` を
    /// 足しても MaskMeTests が 1 件も落ちない（レビュー実測）。
    func test_shouldDetectPreviewFrame_ignoresApplyRangeGate() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        model.addMosaicApplyRange(fromCompositionTime: 2, to: 4)

        // 合成 7.0 は適用区間の外（＝描画ゲートは閉じている）。
        XCTAssertFalse(model.isMosaicActive(atComposition: 7.0), "前提が崩れている")
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 7.0),
                      "区間外でライブ検出が止まっている（ゲートを検出判定に入れてはならない）")

        // 検出済みバケットなら false になる（＝この関数が素通しの true ではないことの確認）。
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace()], bridgedByFlow: false),
            at: 7.0, source: UIImage(), generation: model.timelineGeneration)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 7.0),
                       "検出済みバケットでも検出し続けている（判定が壊れている）")

        // 検出キャッシュは区間外でも埋まっているので、区間を広げれば再検出なしで乗る。
        model.addMosaicApplyRange(fromCompositionTime: 6, to: 8)
        XCTAssertFalse(model.displayFaces(at: 7.0).isEmpty,
                       "区間外で貯めた検出キャッシュが使われていない")
    }

    // MARK: - S9: UI が使う補助 API

    /// `sourceDuration(forClipID:)` が素材の実尺を返し、トリムのクランプ根拠と一致すること。
    func test_sourceDuration_matchesAssetDuration() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let clipID = try XCTUnwrap(model.clips.first).id

        let duration = try XCTUnwrap(model.sourceDuration(forClipID: clipID))
        XCTAssertEqual(duration, 1.0, accuracy: 0.1)
        XCTAssertNotNil(model.sourceURL(forSourceID: model.currentSourceID))
        XCTAssertNil(model.sourceDuration(forClipID: UUID()), "不在クリップは nil")
        XCTAssertNil(model.sourceURL(forSourceID: UUID()))
    }

    // MARK: - S9 レビュー: 分割対象の明示（トランジション重なり内）

    /// `splitClip(id:)` はトランジションの重なり区間でも**選択したクリップ**を割ること。
    /// 帰属規則（重なり内は incoming 側）に任せる `splitAtCurrentPosition` は別のクリップを割る。
    func test_splitClip_splitsSelectedClipInsideTransitionOverlap() {
        let (model, clipA, clipB) = makeTwoClipModel()   // A 4s + B 6s
        model.setTransition(afterClipID: clipA.id, kind: .crossfade, duration: 2.0)
        XCTAssertEqual(model.videoDuration, 8.0, accuracy: 1e-9)
        // 重なりは表示時刻 [2, 4)。3.0 は重なりの中。
        XCTAssertNotNil(model.mapping.overlap(at: 3.0))
        model.playbackPosition = 3.0 / model.videoDuration

        XCTAssertTrue(model.timeline.canSplit(clipID: clipA.id, atDisplayTime: 3.0))
        model.splitClip(id: clipA.id)

        XCTAssertEqual(model.clips.filter { $0.sourceID == clipA.sourceID }.count, 2,
                       "選択したクリップが割れていない")
        XCTAssertEqual(model.clips.filter { $0.sourceID == clipB.sourceID }.count, 1,
                       "選択していないクリップが割れた")
        XCTAssertTrue(model.timeline.validate())
    }

    // MARK: - S9 レビュー: プレビューのデコード資源占有（M-B3）

    /// `beginPreviewDecode` / `endPreviewDecode` が対で動き、値が変わったときだけ
    /// 通知すること（`@Published` にできない = 通知が多いと画面全体が再描画される）。
    func test_previewDecodeBusy_pairsBeginAndEndAndNotifiesOnChangeOnly() {
        let model = makeModel()
        var events: [Bool] = []
        model.onPreviewDecodeBusyChanged = { events.append($0) }

        XCTAssertFalse(model.isPreviewDecodeBusy)
        model.beginPreviewDecode()
        XCTAssertTrue(model.isPreviewDecodeBusy)
        model.beginPreviewDecode()          // 入れ子（rebuild の中の seek など）
        model.endPreviewDecode()
        XCTAssertTrue(model.isPreviewDecodeBusy, "入れ子の内側で busy が落ちている")
        model.endPreviewDecode()
        XCTAssertFalse(model.isPreviewDecodeBusy)
        XCTAssertEqual(model.previewDecodeDepthForTesting, 0)
        XCTAssertEqual(events, [true, false], "値が変わらない通知が飛んでいる")

        // 余分な end で深さが負に沈まないこと（沈むと以降の begin が効かなくなる）。
        model.endPreviewDecode()
        XCTAssertEqual(model.previewDecodeDepthForTesting, 0)
        model.beginPreviewDecode()
        XCTAssertTrue(model.isPreviewDecodeBusy)
        model.endPreviewDecode()
        XCTAssertFalse(model.isPreviewDecodeBusy)
    }

    /// **番人: 再構築が重なったとき、先に終わった方が待ち表示を消さないこと。**
    ///
    /// `replaceTimeline` は古い再構築を cancel せず新しいタスクを積むだけなので、
    /// 連続編集すると古い方が後から終わる。1 本ごとの `defer` で消す実装だと、
    /// 「新しい方がまだ再構築中なのに表示が消える」＝最も待たされる場面でだけ
    /// 表示が出ない、という目的の真逆が起きる。
    func test_rebuildIndicator_重なった再構築で先に終わった方が消さない() async throws {
        let model = makeModel()
        XCTAssertFalse(model.isRebuildingComposition)

        model.beginRebuild()
        model.beginRebuild()                       // 連続編集で 2 本目が重なる
        // 猶予（0.4 秒）を超えるまで待つ。ここで初めて表示が立つ。
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(model.isRebuildingComposition, "猶予を超えたのに待ち表示が立たない")

        model.endRebuild()                         // 先に終わった 1 本目
        XCTAssertTrue(model.isRebuildingComposition,
                      "まだ再構築中なのに待ち表示が消えた")
        model.endRebuild()                         // 最後の 1 本
        XCTAssertFalse(model.isRebuildingComposition)
        XCTAssertEqual(model.rebuildDepthForTesting, 0)

        // 余分な end で深さが負に沈まないこと（沈むと以降の begin が効かなくなる）。
        model.endRebuild()
        XCTAssertEqual(model.rebuildDepthForTesting, 0)
    }

    /// 猶予より早く終わる再構築では待ち表示を**一度も**出さないこと
    /// （分割・トリムのような日常操作でインジケータが光らない）。
    func test_rebuildIndicator_すぐ終わる再構築では出ない() async throws {
        let model = makeModel()
        model.beginRebuild()
        try await Task.sleep(nanoseconds: 100_000_000)   // 猶予 0.4 秒より十分短い
        model.endRebuild()
        XCTAssertFalse(model.isRebuildingComposition)
        // 猶予を過ぎても、キャンセル済みのタスクが後から立てないこと。
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.isRebuildingComposition,
                       "終わった後に待ち表示が立った（タスクがキャンセルされていない）")
    }

    /// 実素材での編集（composition 差し替え + seek）とスクラブ用シークの後、
    /// 占有の深さが 0 に戻ること（`defer` の対が崩れていないことの実測）。
    func test_previewDecodeBusy_returnsToZeroAfterEditAndSeek() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let clipID = try XCTUnwrap(model.clips.first).id

        model.trimClip(id: clipID, sourceStart: 0, sourceEnd: 0.5)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.previewDecodeDepthForTesting, 0, "編集経路で立ち下げが漏れている")

        model.seekToLatest(position: 0.3)
        let deadline = Date().addingTimeInterval(5)
        while model.isPreviewDecodeBusy, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.previewDecodeDepthForTesting, 0, "シーク経路で立ち下げが漏れている")
        XCTAssertFalse(model.isPreviewDecodeBusy)
    }

    /// 編集（composition 差し替え + zero-tolerance seek）の**最中**にサムネイル生成が
    /// 抑止されること。`isPlaying` は false のままなので、旧ガードでは 1 つも覆えなかった経路。
    func test_previewDecodeBusy_blocksThumbnailGenerationDuringEdit() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let clipID = try XCTUnwrap(model.clips.first).id

        let store = TimelineThumbnailStore()
        // VideoTimelineView.bindPreviewBusy と同じ結線。
        model.onPreviewDecodeBusyChanged = { busy in store.setPreviewBusy(busy) }
        store.request(thumbnailJobs(sourceID: model.currentSourceID, url: url, count: 4))
        try await waitUntilThumbnailsSettle(store)

        model.trimClip(id: clipID, sourceStart: 0, sourceEnd: 0.5)
        var observedBusy = false
        var blockedWhileBusy = false
        var playingWhileBusy = true
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.isPreviewDecodeBusy {
                observedBusy = true
                blockedWhileBusy = store.isGenerationBlockedForTesting
                playingWhileBusy = model.isPlaying
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await model.awaitPendingTimelineRebuild()

        XCTAssertTrue(observedBusy, "編集中にプレビューのデコード占有が立っていない")
        XCTAssertFalse(playingWhileBusy, "isPlaying ガードでは覆えない経路であることの確認")
        XCTAssertTrue(blockedWhileBusy, "編集中にサムネイル生成が抑止されていない")
        XCTAssertFalse(model.isPreviewDecodeBusy, "編集後に占有が下がっていない")
    }

    // MARK: - S9 レビュー: サムネイル生成の不変条件（M-B1 / M-B2 / M-B3）

    private func thumbnailJobs(sourceID: UUID, url: URL,
                               count: Int = 6) -> [TimelineThumbnailStore.Request] {
        (0..<count).map {
            TimelineThumbnailStore.Request(sourceID: sourceID, url: url,
                                           sourceTime: Double($0) * 0.25)
        }
    }

    private func waitUntilThumbnailsSettle(_ store: TimelineThumbnailStore,
                                           timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isGeneratingForTesting || store.pendingCountForTesting > 0 {
            if Date() > deadline {
                XCTFail("サムネイル生成が \(timeout)s 以内に落ち着かない")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 最後の finish（MainActor へ戻る後始末）が走り切るのを待つ。
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// **生成器が 2 個同時に走らないこと。**
    ///
    /// 旧実装は `setPlaying(true)` が `activeBatch = nil` していたため、
    /// 「再生 → 即一時停止」の連打で生成器が 1 個ずつ増えた（デコード中のバッチは
    /// キャンセルされても完走するため、その窓の間だけ並走する）。
    func test_thumbnailStore_neverRunsTwoGeneratorsConcurrently() async throws {
        let urlA = try await makeTestVideo(seconds: 2.0)
        let urlB = try await makeTestVideo(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        timelineThumbnailConcurrencyProbe.reset()
        let store = TimelineThumbnailStore()
        // 別素材のジョブも積む（1 バッチは同一素材ぶんだけ取るので B は保留に残り、
        // 打ち切り直後の pump が「別 url の新バッチ」を起こせる状態を作る）。
        store.request(thumbnailJobs(sourceID: UUID(), url: urlA, count: 12))
        store.request(thumbnailJobs(sourceID: UUID(), url: urlB, count: 12))
        // 「再生 → 即一時停止」をデコード進行中に何度も割り込ませる
        // （旧実装はこの窓のたびに生成器が 1 個増えた）。
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 1_000_000)
            store.setPlaying(true)
            store.setPlaying(false)
        }
        try await waitUntilThumbnailsSettle(store)

        XCTAssertEqual(timelineThumbnailConcurrencyProbe.overlapCount, 0,
                       "サムネイル生成器が並走した（HW デコーダの取り合い）")
        XCTAssertLessThanOrEqual(timelineThumbnailConcurrencyProbe.maximumConcurrent, 1)
    }

    /// **破棄した素材の結果を捨てること**（世代トークン）。
    ///
    /// 旧実装は `reset()` が `activeBatch = nil` していたため、直後の新素材バッチが
    /// 走り、その後届いた旧バッチの `finish` が旧 url のジョブを保留へ戻して
    /// 「捨てた動画のデコードし直し」を起こし、描画に使えないキャッシュが残った。
    func test_thumbnailStore_resetDiscardsPreviousGenerationResults() async throws {
        let oldURL = try await makeTestVideo(seconds: 2.0)
        let newURL = try await makeTestVideo(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }
        let store = TimelineThumbnailStore()
        let oldSource = UUID()
        let newSource = UUID()
        store.request(thumbnailJobs(sourceID: oldSource, url: oldURL))
        try await Task.sleep(nanoseconds: 50_000_000)   // 旧バッチがデコード中

        let generationBefore = store.generationForTesting
        store.reset()
        XCTAssertEqual(store.generationForTesting, generationBefore + 1)
        store.request(thumbnailJobs(sourceID: newSource, url: newURL))
        try await waitUntilThumbnailsSettle(store)

        XCTAssertFalse(store.images.isEmpty, "新素材のサムネイルが生成されていない")
        XCTAssertTrue(store.images.keys.allSatisfy { $0.sourceID == newSource },
                      "破棄した素材のサムネイルがキャッシュに残っている")
        XCTAssertNil(store.image(sourceID: oldSource, sourceTime: 0))
    }

    /// **プレビューがデコード資源を握っている間・スクラブ中は生成しないこと**、
    /// かつその間の要求が捨てられずに後で取り直せること。
    func test_thumbnailStore_holdsGenerationWhilePreviewBusyOrScrubbing() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TimelineThumbnailStore()
        let source = UUID()

        store.setPreviewBusy(true)
        store.request(thumbnailJobs(sourceID: source, url: url))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(store.images.isEmpty, "プレビューのデコード中に生成が始まった")
        XCTAssertFalse(store.isGeneratingForTesting)
        XCTAssertGreaterThan(store.pendingCountForTesting, 0, "要求が捨てられている")

        store.setPreviewBusy(false)
        try await waitUntilThumbnailsSettle(store)
        XCTAssertFalse(store.images.isEmpty, "抑止解除後に生成が再開しない")

        // スクラブは別フラグ（seek ごとに busy が立ち下がっても止め続ける）。
        store.setScrubbing(true)
        XCTAssertTrue(store.isGenerationBlockedForTesting)
        store.setPreviewBusy(true)
        store.setPreviewBusy(false)
        XCTAssertTrue(store.isGenerationBlockedForTesting,
                      "スクラブ中に seek の立ち下がりで生成が再開している")
        store.setScrubbing(false)
        XCTAssertFalse(store.isGenerationBlockedForTesting)

        // 画面離脱・バックグラウンドでも止まる。
        store.setSuspended(true)
        XCTAssertTrue(store.isGenerationBlockedForTesting)
        store.setSuspended(false)
        XCTAssertFalse(store.isGenerationBlockedForTesting)
    }

    /// 同一キーフレームへ解決される要求はデコードを 1 回で済ませ、
    /// **実コマの時刻**でキャッシュされること（要求時刻キーだと同じコマが何枚も積まれる）。
    ///
    /// 別名（要求バケット → 実コマバケット）が張られるので、要求した全枠は描画できる。
    func test_thumbnailStore_deduplicatesRequestsResolvingToSameKeyframe() async throws {
        let url = try await makeTestVideo(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }
        timelineThumbnailConcurrencyProbe.reset()
        let store = TimelineThumbnailStore()
        let source = UUID()
        let times = (0..<8).map { Double($0) * 0.5 }   // 8 バケット（0〜3.5 秒）
        store.request(times.map {
            TimelineThumbnailStore.Request(sourceID: source, url: url, sourceTime: $0)
        })
        try await waitUntilThumbnailsSettle(store)

        for time in times {
            XCTAssertNotNil(store.image(sourceID: source, sourceTime: time),
                            "要求した枠が描画できない（t=\(time)）")
        }
        let decodes = timelineThumbnailConcurrencyProbe.decodeCount
        print("[MMTHUMB] requested=8 decodes=\(decodes) cacheEntries=\(store.images.count)")
        XCTAssertLessThanOrEqual(decodes, 8)
        XCTAssertEqual(store.images.count, decodes,
                       "デコード回数とキャッシュ枚数が一致しない（同じコマが重複して積まれている）")
    }

    // MARK: - S10a: 動画素材の追加（appendVideoClip）

    /// 追加した動画が composition に入ること: クリップ・素材メタ（kind = .video）・
    /// 合成尺・実 composition の尺が 2 本ぶんになり、素材IDは別であること。
    func test_appendVideoClip_addsSecondClipIntoComposition() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)
        let firstSource = try XCTUnwrap(model.clips.first).sourceID
        let baseDuration = model.videoDuration

        await model.appendVideoClip(url: added)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.clips.count, 2, "追加した動画がクリップにならない")
        let newClip = model.clips[1]
        XCTAssertNotEqual(newClip.sourceID, firstSource, "追加素材が元素材と同じ素材IDになっている")
        XCTAssertEqual(model.timeline.sources[newClip.sourceID]?.kind, .video,
                       "追加素材の kind が .video で記録されていない")
        XCTAssertEqual(newClip.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(newClip.sourceEnd, 2.0, accuracy: 0.1, "追加素材の尺が反映されていない")
        XCTAssertEqual(model.videoDuration, baseDuration + 2.0, accuracy: 0.1)
        let composition = try XCTUnwrap(model.composition, "追加後に composition が無い")
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), model.mapping.totalDuration,
                       accuracy: 0.05, "composition の尺が写像と一致しない（結合されていない）")
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration)
        XCTAssertTrue(model.timeline.validate())
        // sources へ AVURLAsset として登録され、サムネイル・下書きが URL を取り出せること
        XCTAssertEqual(model.sourceURL(forSourceID: newClip.sourceID), added)
    }

    // MARK: - S11: 適用区間の自動生成と「区間 0 本 = 全区間 OFF」

    /// **掛ける操作を通した編集では、クリップ全体を覆う区間が 1 本だけできて全時刻 ON になること。**
    ///
    /// 区間 0 本 = 全区間 OFF なので、掛ける操作の入口（`ensureApplyRangesExist`）が
    /// 区間を作らないと「ON にしたのにどこにも乗らない」状態になる。
    /// **新規読み込みの直後は区間 0 本**（レイヤーを出さない）で、それは
    /// `test_newProject_startsWithNoApplyRangeLayer` が固定している。
    func test_appliedProject_hasSingleFullCoverApplyRange() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        // 掛ける操作の入口（実アプリでは効果を ON にしたとき）を通す。
        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 1, "掛ける操作の入口で全体区間が作られていない")
        let clip = try XCTUnwrap(model.clips.first)
        XCTAssertEqual(model.timeline.applyRanges[0].clipID, clip.id)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceStart, clip.sourceStart, accuracy: 1e-12)
        XCTAssertEqual(model.timeline.applyRanges[0].sourceEnd, clip.sourceEnd, accuracy: 1e-12)
        XCTAssertTrue(model.timeline.validate())
        for t in stride(from: 0.0, to: model.mapping.totalDuration, by: 0.02) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "掛けているのに OFF の時刻がある t=\(t)")
        }

        // 区間を全削除 → 全時刻 OFF。
        model.removeMosaicApplyRange(id: model.timeline.applyRanges[0].id)
        XCTAssertTrue(model.timeline.applyRanges.isEmpty)
        for t in stride(from: 0.0, to: model.mapping.totalDuration, by: 0.02) {
            XCTAssertFalse(model.isMosaicActive(atComposition: t), "全削除したのに ON の時刻がある t=\(t)")
        }

        // **全削除 → undo → 復活 → redo → 再び 0 本**（自動生成が undo を汚していないこと）。
        model.undo()
        XCTAssertEqual(model.timeline.applyRanges.count, 1, "undo で区間が戻らない")
        XCTAssertTrue(model.isMosaicActive(atComposition: 0.5))
        model.redo()
        XCTAssertTrue(model.timeline.applyRanges.isEmpty, "redo で区間が復活している（自動生成が undo を汚した）")
        XCTAssertFalse(model.isMosaicActive(atComposition: 0.5))
    }

    // MARK: - S: クリップを選択しているときは、そのクリップだけに掛ける

    /// 実機報告の再現: クリップを 2 本にして 1 本を選んでから掛ける操作をしたら、
    /// 選んだクリップにだけ区間ができ、もう 1 本のクリップの時刻ではゲートが閉じていること。
    func test_ensureApplyRangesExist_withClipSelected_onlyCoversSelectedClip() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.timelineSelection.selectClip(second.id)

        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "選択中のクリップだけに絞ったはずが本数が違う")
        let range = model.timeline.applyRanges[0]
        XCTAssertEqual(range.clipID, second.id, "選んでいないクリップに区間ができている")
        XCTAssertEqual(range.sourceStart, second.sourceStart, accuracy: 1e-12)
        XCTAssertEqual(range.sourceEnd, second.sourceEnd, accuracy: 1e-12)

        // 選んだクリップ（合成時刻 4...8）は ON、選んでいないクリップ（合成時刻 0...4）は OFF。
        for t in stride(from: 4.0, to: 8.0, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "選んだクリップなのに OFF の時刻がある t=\(t)")
        }
        for t in stride(from: 0.0, to: 4.0, by: 0.1) {
            XCTAssertFalse(model.isMosaicActive(atComposition: t), "選んでいないクリップに掛かっている t=\(t)")
        }
    }

    /// 何も選択せずに掛ける操作をしたら、従来どおり全クリップぶんの区間ができること
    /// （選択機能を足す前の挙動の回帰）。
    func test_ensureApplyRangesExist_withoutSelection_coversAllClips() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        XCTAssertNil(model.timelineSelection.clipID, "前提: 何も選択していない")

        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 2, "全クリップぶんの区間ができていない")
        for t in stride(from: 0.0, to: 8.0, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "選択なしなのに OFF の時刻がある t=\(t)")
        }
    }

    /// 選択が消えたクリップを指している（存在しないクリップ id）場合は安全側の全クリップ
    /// にフォールバックすること。`TimelineSelection.prune` が通常は刈るはずだが、
    /// 入口側でも安全側に倒れることを固定する。
    func test_ensureApplyRangesExist_withDanglingSelection_fallsBackToAllClips() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.timelineSelection.selectClip(UUID())  // 存在しない id

        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 2,
                       "解決できない選択で全クリップへフォールバックしていない")
    }

    /// **別のクリップを選んで掛けたら、そのクリップにも区間ができる。**
    ///
    /// 判定の単位は「選んだクリップ」であって「全体」ではない。ここを
    /// 「`applyRanges` が空のときだけ足す」にすると、A に掛けた後で B を選んで掛けても
    /// 全体としては空でないため入口で弾かれ、**ユーザーには「掛けたのに反応しない」**
    /// に見える（`ensureApplyRangesExist` の doc 参照）。
    func test_ensureApplyRangesExist_withAnotherClipSelected_addsRangeForThatClip() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.timelineSelection.selectClip(second.id)
        model.ensureApplyRangesExist()
        XCTAssertEqual(model.timeline.applyRanges.count, 1)

        model.timelineSelection.selectClip(first.id)
        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 2,
                       "別のクリップを選んで掛けたのに区間が増えていない（掛けても無反応）")
        XCTAssertEqual(Set(model.timeline.applyRanges.map(\.clipID)), [first.id, second.id])
        for t in stride(from: 0.0, to: 8.0, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "両方掛けたのに OFF の時刻がある t=\(t)")
        }
    }

    /// **同じクリップで二度掛けても増えない**（重複した区間を作らない）。
    func test_ensureApplyRangesExist_calledTwiceForSameClip_doesNotDuplicate() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.timelineSelection.selectClip(second.id)
        model.ensureApplyRangesExist()
        let firstResult = model.timeline.applyRanges

        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges, firstResult,
                       "同じクリップで二度掛けたら区間が増えた（重複）")
    }

    /// 既存の不変条件（回帰）: **選択が無い**ときは、区間が 1 本でも残っていれば触らない。
    /// 特定のクリップの区間を消したのは意図的な操作なので復活させない。
    func test_ensureApplyRangesExist_withoutSelection_andExistingRange_doesNotAddMore() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.timelineSelection.selectClip(second.id)
        model.ensureApplyRangesExist()
        XCTAssertEqual(model.timeline.applyRanges.count, 1)

        model.timelineSelection.selectClip(nil)
        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "選択が無いのに区間が増えている（消したものが復活する）")
        XCTAssertEqual(model.timeline.applyRanges[0].clipID, second.id,
                       "既存区間の対象が入れ替わっている（触ってはいけない）")
    }

    /// **孤児区間だけが残った状態で掛け直したら、ちゃんと掛かること。**
    ///
    /// 区間は素材時刻アンカーなので、クリップをトリムすると区間がクリップの使用範囲と
    /// 交差しなくなる（孤児区間）。孤児はデータとしては残るが帯にもゲートにも出ないので、
    /// ユーザーから見れば「区間は 1 本も無い」。ここで入口の判定を生データ
    /// （`timeline.applyRanges`）で行うと**掛け直しても入口で弾かれ、何も起きない**。
    /// 判定は `effectiveApplyRanges` で行うこと（`ensureApplyRangesExist` の doc 参照）。
    func test_ensureApplyRangesExist_withOnlyOrphanRange_recreatesRange() {
        let model = makeModel()
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([clip])
        // クリップが使っている素材範囲 [4,8) と交差しない区間＝孤児。
        setApplyRanges(model, [MosaicApplyRange(clipID: clip.id, sourceID: source,
                                               sourceStart: 0, sourceEnd: 2)])
        XCTAssertEqual(model.timeline.applyRanges.count, 1, "前提: 区間データは 1 本残っている")
        XCTAssertTrue(model.effectiveApplyRanges.isEmpty, "前提が崩れている（孤児になっていない）")

        model.ensureApplyRangesExist()

        XCTAssertFalse(model.effectiveApplyRanges.isEmpty,
                       "孤児区間だけ残った状態で掛け直しても無反応（帯もゲートも空のまま）")
        for t in stride(from: 0.0, to: 4.0, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t),
                          "掛け直したのに OFF の時刻がある t=\(t)")
        }
    }

    /// 同じ状況でクリップを選択している場合。**新しい区間を足すときに、そのクリップの
    /// 孤児区間は捨てる。** 残すと、後でトリムを戻したとき孤児が生き返って今足した
    /// 全域区間と重なる（同じ clipID に重複区間が並ぶ）。
    func test_ensureApplyRangesExist_withSelectedClipHavingOnlyOrphanRange_dropsOrphan() {
        let model = makeModel()
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([clip])
        setApplyRanges(model, [MosaicApplyRange(clipID: clip.id, sourceID: source,
                                               sourceStart: 0, sourceEnd: 2)])
        model.timelineSelection.selectClip(clip.id)

        model.ensureApplyRangesExist()

        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "孤児区間を残したまま足している（トリムを戻すと重複する）")
        let range = model.timeline.applyRanges[0]
        XCTAssertEqual(range.sourceStart, 4, accuracy: 1e-12, "新しい区間がクリップ全体を覆っていない")
        XCTAssertEqual(range.sourceEnd, 8, accuracy: 1e-12)
        for t in stride(from: 0.0, to: 4.0, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t),
                          "掛け直したのに OFF の時刻がある t=\(t)")
        }
    }

    /// 既存の不変条件（回帰）: 全区間を削除して 0 本にすると、タイムライン全域でゲートが
    /// 閉じていること（選択の有無に関わらず）。
    func test_removingAllApplyRanges_closesGateAcrossWholeTimeline() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        model.ensureApplyRangesExist()
        XCTAssertEqual(model.timeline.applyRanges.count, 2)

        for range in model.timeline.applyRanges {
            model.removeMosaicApplyRange(id: range.id)
        }

        XCTAssertTrue(model.timeline.applyRanges.isEmpty)
        for t in stride(from: 0.0, to: 8.0, by: 0.1) {
            XCTAssertFalse(model.isMosaicActive(atComposition: t), "全削除したのに ON の時刻がある t=\(t)")
        }
    }

    // MARK: - S: 再生位置に区間を足す導線（`addMosaicApplyRange`）

    /// 再生位置に区間を足す操作（`VideoTimelineView.addApplyRangeAtPlayhead` が呼ぶ
    /// `addMosaicApplyRange` そのもの）は、全域を覆う区間を作らないこと。
    /// `defaultApplyRangeLength = 2.0` の短い区間が再生位置から伸びるだけで、
    /// タイムライン全域（8 秒）を覆ってはならない。
    func test_addMosaicApplyRange_atPlayhead_doesNotCoverWholeTimeline() {
        let model = makeModel()
        let source = model.currentSourceID
        let first = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        let second = TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)
        model.setClipsForTesting([first, second])
        XCTAssertTrue(model.timeline.applyRanges.isEmpty, "前提: 区間 0 本から始める")

        let defaultApplyRangeLength = 2.0
        let playheadTime = 3.0
        let end = min(playheadTime + defaultApplyRangeLength, model.mapping.totalDuration)
        model.addMosaicApplyRange(fromCompositionTime: playheadTime, to: end)

        // **2 本**になるのが正しい。区間は素材時刻アンカーで**クリップ単位**に持つので、
        // クリップ境界（合成 4.0 秒）をまたぐ区間は 2 本に割れる（1 本を期待すると、
        // 境界をまたいだときだけ落ちるテストになる）。
        XCTAssertEqual(model.timeline.applyRanges.count, 2,
                       "クリップ境界をまたぐ区間がクリップ単位に割れていない")
        // 全域（8 秒）を覆っていないこと。
        XCTAssertFalse(model.isMosaicActive(atComposition: 0.0), "先頭まで覆ってしまっている")
        XCTAssertFalse(model.isMosaicActive(atComposition: 7.5), "末尾まで覆ってしまっている")
        // 足した区間そのものは ON。
        for t in stride(from: playheadTime, to: end, by: 0.1) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "足した区間なのに OFF の時刻がある t=\(t)")
        }
    }

    // MARK: - 新規編集はレイヤー 0 本で始まる

    /// 動画を開いただけでは**モザイクのレイヤー（適用区間）を出さない**こと。
    ///
    /// 以前は開いた瞬間に全域の区間が 1 本乗っていた。効果を何も足していないのに
    /// レイヤーがあるのは編集アプリの流儀に反する
    /// （ユーザー報告「新規編集でモザイクをレイヤーに出さないで」）。
    func test_newProject_startsWithNoApplyRangeLayer() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        // **既定のモデルを使う**（`makeModel()` は「掛けると決めた後」を再現するヘルパで、
        // 読み込み完了時に区間を確保してしまう）。ここで見たいのは掛ける前の姿。
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        XCTAssertFalse(model.faceMosaicOn, "動画モードの既定が ON になっている")

        XCTAssertTrue(model.timeline.applyRanges.isEmpty,
                      "動画を開いただけでモザイクのレイヤーが乗っている")
        XCTAssertFalse(model.isMosaicActive(atComposition: 0.5))
        XCTAssertTrue(model.timeline.validate())
    }

    /// **掛ける操作をした瞬間にレイヤーが現れること。**
    ///
    /// レイヤーを出さない代償として、区間 0 本 = 全区間 OFF のままだと
    /// 「顔モザイクを ON にしたのに何も掛からない」になる。掛ける操作の入口
    /// （`toggleDockEffect` → `ensureApplyRangesExist`）が繋がっているかを固定する。
    /// **ここが切れると素顔が書き出しに残るので、レイヤーを出さない変更の対**である。
    func test_turningFaceMosaicOn_createsTheLayer() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        // 既定（顔モザイク OFF）から始める。`makeModel()` は既に ON なので、
        // これで `toggleDockEffect` を呼ぶと**切る**方向になり、入口を通らない。
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        XCTAssertTrue(model.timeline.applyRanges.isEmpty)

        model.toggleDockEffect(.face)
        XCTAssertTrue(model.faceMosaicOn, "ON になっていない（テストが切る方向に回っている）")

        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "顔モザイクを ON にしてもレイヤーが現れない（＝どこにも掛からない）")
        for t in stride(from: 0.0, to: model.mapping.totalDuration, by: 0.05) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "ON にしたのに OFF の時刻がある t=\(t)")
        }
    }

    /// **まだ何も掛けていない編集**に素材を足しても、レイヤーは現れないこと。
    /// ここで足すと「新規では出さない」を素材追加で破ることになる
    /// （しかも足した素材にだけ掛かる、という読めない状態になる）。
    func test_appendVideoClip_doesNotCreateLayerWhenNothingIsApplied() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        // 掛ける前の姿を見るので既定のモデル（`makeModel()` は掛けた後を再現する）。
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.load(videoURL: base)
        try await waitUntilLoaded(model)

        await model.appendVideoClip(url: added)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.clips.count, 2, "素材が追加されていない")
        XCTAssertTrue(model.timeline.applyRanges.isEmpty,
                      "何も掛けていない編集に素材を足しただけでレイヤーが生えている")
        XCTAssertTrue(model.timeline.validate())
    }

    /// **既にモザイクを使っている編集**へ素材を足したら、新クリップにも区間が付くこと
    /// （既存クリップの区間は変わらない）。ここが抜けると追加素材だけ素通しになる。
    func test_appendVideoClip_addsFullCoverApplyRangeForNewClip() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        // `makeModel()` +`waitUntilLoaded` が「モザイクを掛けている編集」を再現する
        // （＝レイヤーが 1 本ある状態。ヘルパの doc 参照）。
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)
        model.ensureApplyRangesExist()
        let baseRanges = model.timeline.applyRanges
        XCTAssertEqual(baseRanges.count, 1)

        await model.appendVideoClip(url: added)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.timeline.applyRanges.count, 2, "追加クリップに区間が付いていない")
        XCTAssertEqual(model.timeline.applyRanges[0], baseRanges[0], "既存クリップの区間が書き換わった")
        XCTAssertEqual(model.timeline.applyRanges[1].clipID, model.clips[1].id)
        XCTAssertTrue(model.timeline.validate())
        for t in stride(from: 0.0, to: model.mapping.totalDuration, by: 0.05) {
            XCTAssertTrue(model.isMosaicActive(atComposition: t), "追加後に OFF の時刻がある t=\(t)")
        }
    }

    /// 下書き復元 3 パターン: (a) v2 の区間 0 本は 0 本のまま（意図的な全削除が復活しない）、
    /// (b) v2 の区間ありはそのまま、(c) v1（`schemaVersion` 無し）は全体区間へ移行。
    func test_draftRestore_doesNotRegenerateApplyRanges() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        func restore(_ timeline: TimelineState, sourceID: UUID) async throws -> MosaicEditorModel {
            let model = makeModel()
            model.queueTimelineRestore(timeline: timeline, sourceURLs: [sourceID: url],
                                       primarySourceID: sourceID)
            model.load(videoURL: url)
            try await waitUntilLoaded(model)
            return model
        }

        // (a) ユーザーが全削除した下書き（v2・区間 0 本）→ 0 本のまま。
        let sourceA = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 1)
        let emptyState = try JSONDecoder().decode(
            TimelineState.self,
            from: try JSONEncoder().encode(TimelineState(clips: [clipA], applyRanges: [])))
        let restoredEmpty = try await restore(emptyState, sourceID: sourceA)
        XCTAssertTrue(restoredEmpty.timeline.applyRanges.isEmpty,
                      "意図的に全削除した下書きで区間が復活している")
        XCTAssertFalse(restoredEmpty.isMosaicActive(atComposition: 0.5))

        // (b) 部分区間を持つ下書き（v2）→ そのまま。
        let sourceB = UUID()
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 1)
        let partial = MosaicApplyRange(clipID: clipB.id, sourceID: sourceB,
                                       sourceStart: 0.2, sourceEnd: 0.5)
        let restoredPartial = try await restore(TimelineState(clips: [clipB], applyRanges: [partial]),
                                                sourceID: sourceB)
        XCTAssertEqual(restoredPartial.timeline.applyRanges, [partial])
        XCTAssertTrue(restoredPartial.isMosaicActive(atComposition: 0.3))
        XCTAssertFalse(restoredPartial.isMosaicActive(atComposition: 0.8))

        // (c) v1 下書き（schemaVersion 無し・区間 0 本）→ 旧「空 = 全区間 ON」を保存する
        //     ため全体区間へ移行。復元経路では再生成しないので、この 1 本だけが残る。
        let sourceC = UUID()
        let clipC = TimelineClip(sourceID: sourceC, sourceStart: 0, sourceEnd: 1)
        //     **版番号を直書きしないこと。** `"schemaVersion":2` と書いていた間、版を 3 へ
        //     上げた瞬間にこの除去が空振りして v1 の JSON が作れなくなり、(c) だけが
        //     「移行が壊れた」ように見える形で落ちた（実際はテストの前提が古いだけ）。
        var v1 = String(decoding: try JSONEncoder().encode(TimelineState(clips: [clipC])),
                        as: UTF8.self)
        let versionField = "\"schemaVersion\":\(TimelineState.currentSchemaVersion)"
        v1 = v1.replacingOccurrences(of: ",\(versionField)", with: "")
        v1 = v1.replacingOccurrences(of: "\(versionField),", with: "")
        XCTAssertFalse(v1.contains("schemaVersion"), "版番号が残っている（v1 になっていない）")
        let migrated = try JSONDecoder().decode(TimelineState.self, from: Data(v1.utf8))
        let restoredV1 = try await restore(migrated, sourceID: sourceC)
        XCTAssertEqual(restoredV1.timeline.applyRanges.count, 1)
        XCTAssertEqual(restoredV1.timeline.applyRanges[0].clipID, clipC.id)
        XCTAssertTrue(restoredV1.isMosaicActive(atComposition: 0.5))
    }

    /// 追加は編集履歴（undo/redo）に載ること。
    func test_appendVideoClip_isUndoable() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)

        await model.appendVideoClip(url: added)
        XCTAssertEqual(model.clips.count, 2)

        model.undo()
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 1, "追加が undo で戻らない")

        model.redo()
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 2, "追加が redo で復元されない")
    }

    /// クリップ未構築（動画ロード前）では黙って no-op にせず、エラーを出すこと
    /// （写真追加と同じ流儀）。
    func test_appendVideoClip_beforeTimelineExists_reportsError() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()

        await model.appendVideoClip(url: url)

        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertNotNil(model.errorMessage, "タイムライン未構築での追加が無言で失敗している")
    }

    /// 尺が取れない URL（存在しないファイル）では素材を登録せずエラーにすること
    /// （実体のないクリップを composition へ流さない）。
    func test_appendVideoClip_withUnreadableURL_reportsErrorAndKeepsTimeline() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: base) }
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)
        let generation = model.timelineGeneration

        await model.appendVideoClip(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).mp4"))

        XCTAssertEqual(model.clips.count, 1, "読めない素材でクリップが増えた")
        XCTAssertEqual(model.timelineGeneration, generation, "無効な追加で世代が進んだ")
        XCTAssertNotNil(model.errorMessage)
    }

    /// 追加は「読み込み」ではないので既存の検出結果（`detectedFaces`）を置き換えず、
    /// 追加素材の検出は**素材基準キー**で `detectionCache` に入って lookup に効くこと。
    ///
    /// 合成テスト動画には実際の顔が写らない（MediaPipe は何も検出しない）ため、
    /// シードが通す経路そのもの——`cacheStore` への素材基準キー格納 → 写像 →
    /// 素材スコープの選択照合 → `displayFaces`——を、シードと同じ格納 API で
    /// 注入して固定する。
    func test_appendVideoClip_keepsExistingFacesAndWiresSourceKeyedDetection() async throws {
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)
        // 追加素材にも区間が付く前提（＝既にモザイクを掛けている編集）にする。
        model.ensureApplyRangesExist()
        let firstSource = try XCTUnwrap(model.clips.first).sourceID
        // 元素材の顔（左上）を選択済みにしておく
        let existingFace = fakeFace(cx: 0.25, cy: 0.25)
        model.detectedFaces = [FaceTarget(id: UUID(), landmarks: existingFace,
                                          thumbnail: UIImage(), isSelected: true,
                                          sourceID: firstSource)]
        model.cacheStore.store([existingFace], sourceID: firstSource, time: 0.5)

        await model.appendVideoClip(url: added)
        await model.awaitPendingTimelineRebuild()

        XCTAssertTrue(model.detectedFaces.contains { $0.sourceID == firstSource },
                      "追加で既存素材の顔（＝選択状態）が失われた")

        // 追加素材のシードと同じ経路で検出結果を入れる（顔は右下に置き、
        // 別素材の顔と取り違えていないことを重心で区別できるようにする）
        let newSource = model.clips[1].sourceID
        let newFace = fakeFace(cx: 0.75, cy: 0.75)
        model.cacheStore.store([newFace], sourceID: newSource, time: 0.5)
        model.detectedFaces.append(FaceTarget(id: UUID(), landmarks: newFace,
                                              thumbnail: UIImage(), isSelected: true,
                                              sourceID: newSource))
        XCTAssertFalse(model.liveFlowCache.keys.contains { $0.sourceID == newSource },
                       "実検出のシードがフローキャッシュ（liveFlowCache）へ混ざっている")

        // 追加クリップ側の合成時刻で、追加素材の顔が引けること
        let inAddedClip = model.videoDuration - 0.5
        let faces = model.displayFaces(at: inAddedClip, matching: model.detectedFaces)
        XCTAssertEqual(faces.count, 1, "追加クリップ区間で検出が引けない（写像が繋がっていない）")
        let centroid = try XCTUnwrap(faces.first).points.reduce(into: (x: 0.0, y: 0.0)) {
            $0.x += Double($1.x); $0.y += Double($1.y)
        }
        XCTAssertGreaterThan(centroid.x / 4, 0.5,
                             "追加クリップ区間で元素材の顔が引かれている（素材スコープが効いていない）")

        // 元クリップ側では元素材の顔が引けること（取り違えていない）
        let inBaseClip = model.displayFaces(at: 0.5, matching: model.detectedFaces)
        XCTAssertEqual(inBaseClip.count, 1)
    }

    /// 追加した素材が下書き v2 に保存され、再開（`queueTimelineRestore` + `load`）で
    /// 2 クリップとして復元されること。
    func test_appendVideoClip_survivesDraftSaveAndRestore() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppendVideoDraft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let base = try await makeTestVideo(seconds: 1.0)
        let added = try await makeTestVideo(seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: added)
        }
        let model = makeModel()
        model.load(videoURL: base)
        try await waitUntilLoaded(model)
        await model.appendVideoClip(url: added)
        await model.awaitPendingTimelineRebuild()
        let sourceIDs = model.clips.map(\.sourceID)

        // 下書き保存: draftSources が 2 素材ぶんの URL を出せること
        XCTAssertEqual(model.draftSources.map(\.id), sourceIDs,
                       "追加素材が下書き保存対象（draftSources）に出てこない")
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil,
            sources: model.draftSources,
            sessionSourceIDs: model.sessionReferencedSourceIDs,
            timeline: model.timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], thumbnail: nil))
        XCTAssertEqual(draft.sources.count, 2)

        // 再開: 2 クリップ・同じ素材IDで戻ること
        let urls = store.sourceURLs(for: draft)
        let restored = makeModel()
        restored.queueTimelineRestore(timeline: draft.timeline, sourceURLs: urls,
                                      primarySourceID: sourceIDs[0])
        restored.load(videoURL: try XCTUnwrap(urls[sourceIDs[0]]))
        try await waitUntilLoaded(restored)
        await restored.awaitPendingTimelineRebuild()

        XCTAssertEqual(restored.clips.map(\.sourceID), sourceIDs,
                       "追加した素材が下書きから復元されない")
        XCTAssertEqual(restored.videoDuration, model.videoDuration, accuracy: 0.1)
        XCTAssertNotNil(restored.composition)
    }

    // MARK: - 下書き復元と顔モザイクの選択状態

    /// 下書きを再開したあとの状態（`EditorView.loadMedia` と同じ順序で再開する）。
    ///
    /// 合成テスト動画には実際の顔が写らない（MediaPipe は何も検出しない）ため、
    /// 「初期スキャンが顔を見つけた状態」は `load` の自動選択規則と同じ結果——
    /// 顔が 1 つなら選択・複数なら全部非選択——を注入して再現する。
    /// 検証対象は復元の照合ロジックであり、検出そのものではない。
    private func restoreDraft(_ draft: EditingDraft, from store: DraftStore,
                              primarySourceID: UUID,
                              scannedFaces: [FaceLandmarkSet]) async throws -> MosaicEditorModel {
        let urls = store.sourceURLs(for: draft)
        let restored = makeModel()
        if !draft.timeline.clips.isEmpty {
            restored.queueTimelineRestore(timeline: draft.timeline, sourceURLs: urls,
                                          primarySourceID: primarySourceID)
        }
        restored.load(videoURL: try XCTUnwrap(urls[primarySourceID]))
        restored.detectedFaces = scannedFaces.enumerated().map { idx, lm in
            FaceTarget(id: UUID(), landmarks: lm, thumbnail: UIImage(),
                       isSelected: scannedFaces.count == 1 && idx == 0,
                       sourceID: restored.currentSourceID)
        }
        restored.applyRestoredParameters(
            faceMosaicOn: draft.faceMosaicOn, backgroundMosaicOn: draft.backgroundMosaicOn,
            faceBlockSize: draft.faceBlockSize, backgroundBlockSize: draft.backgroundBlockSize,
            objectMasks: draft.objectMasks, legacyManualRects: draft.legacyManualRects,
            faceSelections: draft.faceSelections)
        try await waitUntilLoaded(restored)
        return restored
    }

    /// 顔を選択した状態のモデルを作り、そのまま下書きへ保存する
    /// （`EditorView.persistDraft` と同じ引数の渡し方）。
    private func saveDraftWithSelection(
        store: DraftStore, url: URL, faces: [(FaceLandmarkSet, Bool)]
    ) async throws -> (draft: EditingDraft, sourceID: UUID) {
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let source = model.currentSourceID
        model.detectedFaces = faces.map {
            FaceTarget(id: UUID(), landmarks: $0.0, thumbnail: UIImage(),
                       isSelected: $0.1, sourceID: source)
        }
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil, sources: model.draftSources,
            sessionSourceIDs: model.sessionReferencedSourceIDs,
            timeline: model.timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], faceSelections: model.selectedFaceAnchors, thumbnail: nil))
        return (draft, source)
    }

    /// **顔が 2 人以上写っている下書きを再開しても、選択されていた顔のモザイクが
    /// 外れないこと**（修正前は初期スキャンの自動選択規則に落ち、実測 0 個選択だった。
    /// プライバシーアプリで「復元したら顔が出ている」状態になる）。
    ///
    /// `FaceTarget.id` は検出のたびに振り直されるので ID では照合できない。
    /// 素材ID＋正規化重心（`DraftFaceSelection`）で再照合されることを固定する。
    func test_draftRestore_keepsSelectedFaces() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelDraft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let faceA = fakeFace(cx: 0.2, cy: 0.3)
        let faceB = fakeFace(cx: 0.8, cy: 0.3)

        // 2 顔とも選択して保存 → 再開
        let saved = try await saveDraftWithSelection(
            store: store, url: url, faces: [(faceA, true), (faceB, true)])
        XCTAssertEqual(saved.draft.faceSelections?.count, 2,
                       "選択された顔が下書きに保存されていない")
        let restored = try await restoreDraft(saved.draft, from: store,
                                              primarySourceID: saved.sourceID,
                                              scannedFaces: [faceA, faceB])

        XCTAssertEqual(restored.detectedFaces.filter(\.isSelected).count, 2,
                       "復元後に顔の選択が失われている（顔が露出する）")
        XCTAssertFalse(restored.canUndo,
                       "復元した選択が履歴の起点になっていない（undo で選択が外れうる）")

        // 片方だけ選択して保存した場合は、その片方だけが復元されること
        // （安全側フォールバックが常時発火して全選択になっていないことの対照）。
        let partial = try await saveDraftWithSelection(
            store: store, url: url, faces: [(faceA, true), (faceB, false)])
        let restoredPartial = try await restoreDraft(partial.draft, from: store,
                                                     primarySourceID: partial.sourceID,
                                                     scannedFaces: [faceA, faceB])
        let selected = restoredPartial.detectedFaces.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1, "選択されていなかった顔まで復元されている")
        XCTAssertEqual(restoredPartial.normalizedCentroid(of: try XCTUnwrap(selected.first).landmarks).x,
                       0.2, accuracy: 0.01, "復元された顔が保存時と別人になっている")
    }

    /// 保存時の顔が復元時に見つからない（重心が閾値を超えて動いた・検出が変わった）
    /// ときは、**その素材の顔を全選択**して安全側（過剰適用）へ倒すこと。
    /// 「選択されていた顔の行方が説明できない」状態で 0 個選択に落とすと顔が露出する。
    func test_draftRestore_unmatchedAnchorSelectsAllFacesOfSource() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        // 保存時: 左上の顔だけを選択
        let saved = try await saveDraftWithSelection(
            store: store, url: url,
            faces: [(fakeFace(cx: 0.1, cy: 0.1), true), (fakeFace(cx: 0.5, cy: 0.5), false)])

        // 復元時: 顔が 2 つとも右下側へ移り、保存時の目印（0.1,0.1）とは
        // 閾値 0.5 を超えて離れている → 照合失敗
        let restored = try await restoreDraft(
            saved.draft, from: store, primarySourceID: saved.sourceID,
            scannedFaces: [fakeFace(cx: 0.9, cy: 0.9), fakeFace(cx: 0.75, cy: 0.95)])

        XCTAssertEqual(restored.detectedFaces.filter(\.isSelected).count, 2,
                       "照合に失敗したのに選択が空のまま（顔が露出する）")
    }

    /// 単位ベクトルの署名（軸が違えば類似度 0＝別人、同じ軸なら 1＝同一人物）。
    private func unitSignature(axis: Int) throws -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis] = 1
        return try XCTUnwrap(FaceSignature(rawValues: values))
    }

    /// **S5**: 保存したときと違う場所に居ても、人物が同定できていれば選択が付いてくること。
    ///
    /// 重心だけで照合していた頃、この状況（選んだ人が動き、選んでいない人が
    /// 選んだ人の元の位置に居る）は**選んでいない人だけを選択し、選んだ人を素で残す**
    /// という最悪の取り違えになっていた。順序も実際の再開と同じにする——
    /// `load` → `applyRestoredParameters`（この時点で顔はまだ空＝目印は保留）→
    /// 初期スキャンが人物 ID 付きの顔を載せる——ので、保留経路も一緒に固定する。
    func test_draftRestore_followsThePersonAcrossTheFrame() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelPerson-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let aliceSignature = try unitSignature(axis: 0)
        let bobSignature = try unitSignature(axis: 1)

        // 保存: alice（左上）だけを選択。bob は選択しない。
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let source = model.currentSourceID
        let alice = try XCTUnwrap(model.personRegistry.register(aliceSignature))
        let bob = try XCTUnwrap(model.personRegistry.register(bobSignature))
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.2, cy: 0.3), thumbnail: UIImage(),
                       isSelected: true, sourceID: source, personID: alice),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.8, cy: 0.3), thumbnail: UIImage(),
                       isSelected: false, sourceID: source, personID: bob)
        ]
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil, sources: model.draftSources,
            sessionSourceIDs: model.sessionReferencedSourceIDs,
            timeline: model.timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28, objectMasks: [],
            faceSelections: model.selectedFaceAnchors,
            personProfiles: model.selectedPersonProfilesForDraft, thumbnail: nil))
        XCTAssertEqual(draft.personProfiles?.map(\.id), [alice],
                       "選択された人物だけが保存されていない（選んでいない人の顔特徴が残る）")
        XCTAssertEqual(draft.faceSelections?.first?.personID, alice,
                       "目印に人物 ID が乗っていない")

        // 再開: alice は右下へ移動し、bob が alice の元いた場所に居る。
        // ディスクから読み直す（人物が JSON を往復して戻ることまで含めて確かめる）。
        let reloaded = try XCTUnwrap(
            DraftStore(directory: draftsDir).videoDrafts.first { $0.id == draft.id })
        let restored = makeModel()
        restored.queueTimelineRestore(timeline: reloaded.timeline,
                                      sourceURLs: store.sourceURLs(for: reloaded),
                                      primarySourceID: source)
        restored.load(videoURL: try XCTUnwrap(store.sourceURLs(for: reloaded)[source]))
        restored.applyRestoredParameters(
            faceMosaicOn: reloaded.faceMosaicOn, backgroundMosaicOn: reloaded.backgroundMosaicOn,
            faceBlockSize: reloaded.faceBlockSize,
            backgroundBlockSize: reloaded.backgroundBlockSize,
            objectMasks: reloaded.objectMasks, legacyManualRects: reloaded.legacyManualRects, faceSelections: reloaded.faceSelections,
            personProfiles: reloaded.personProfiles)
        try await waitUntilLoaded(restored)

        // 初期スキャンが顔を載せる瞬間を再現する。人物 ID は `seedPersonIDs` と同じく
        // 復元した台帳から引く（bob は保存されていないので nil のまま＝同定できない顔）。
        restored.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.85, cy: 0.8), thumbnail: UIImage(),
                       isSelected: false, sourceID: restored.currentSourceID,
                       personID: restored.personRegistry.person(matching: aliceSignature)?.id),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.2, cy: 0.3), thumbnail: UIImage(),
                       isSelected: false, sourceID: restored.currentSourceID,
                       personID: restored.personRegistry.person(matching: bobSignature)?.id)
        ]

        let selected = restored.detectedFaces.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1, "選択が 1 人に収束していない")
        XCTAssertEqual(restored.normalizedCentroid(of: try XCTUnwrap(selected.first).landmarks).x,
                       0.85, accuracy: 0.01,
                       "移動した本人ではなく、本人の元いた場所に居る別人を選んでいる")
    }

    /// 顔選択フィールドを持たない**旧下書き**は壊れずにデコードでき、復元時は
    /// 顔の選択状態に一切触れない（初期スキャンの自動選択規則がそのまま残る）こと。
    func test_draftRestore_legacyDraftWithoutFaceSelectionsKeepsAutoRule() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let source = model.currentSourceID

        // faceSelections を渡さずに保存＝旧下書き相当（nil = 情報なし）
        let draft = try XCTUnwrap(store.saveVideoDraft(
            existing: nil, sources: model.draftSources,
            sessionSourceIDs: model.sessionReferencedSourceIDs,
            timeline: model.timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], thumbnail: nil))
        XCTAssertNil(draft.faceSelections, "情報なしが空配列に潰れている")

        // 顔 2 つ → 自動選択規則どおり 0 個選択のまま（修正前と同じ挙動）
        let restoredMulti = try await restoreDraft(
            draft, from: store, primarySourceID: source,
            scannedFaces: [fakeFace(cx: 0.2, cy: 0.3), fakeFace(cx: 0.8, cy: 0.3)])
        XCTAssertEqual(restoredMulti.detectedFaces.filter(\.isSelected).count, 0)

        // 顔 1 つ → 自動選択規則どおり選択される（旧下書きの単独顔が外れないこと）
        let restoredSingle = try await restoreDraft(
            draft, from: store, primarySourceID: source,
            scannedFaces: [fakeFace(cx: 0.5, cy: 0.4)])
        XCTAssertEqual(restoredSingle.detectedFaces.filter(\.isSelected).count, 1,
                       "旧下書きの復元で単独の顔の自動選択まで外れている")
    }

    /// 初期スキャンが空（冒頭に顔が写らない動画）で復元した場合、目印は保留され、
    /// ライブ検出が顔を見つけて `detectedFaces` が埋まった時点で適用されること。
    /// 保留が無いと、この経路は「顔が複数なら 0 個選択」の自動規則に落ちて顔が露出する。
    func test_draftRestore_appliesSelectionWhenFacesAppearLater() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelPending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let faceA = fakeFace(cx: 0.2, cy: 0.3)
        let faceB = fakeFace(cx: 0.8, cy: 0.3)
        let saved = try await saveDraftWithSelection(
            store: store, url: url, faces: [(faceA, true), (faceB, true)])

        // 初期スキャンが空のまま復元する
        let restored = try await restoreDraft(saved.draft, from: store,
                                              primarySourceID: saved.sourceID,
                                              scannedFaces: [])
        XCTAssertTrue(restored.detectedFaces.isEmpty)

        // 後からライブ検出が顔を見つけた相当（自動選択規則では 2 顔とも非選択）
        restored.detectedFaces = [faceA, faceB].map {
            FaceTarget(id: UUID(), landmarks: $0, thumbnail: UIImage(),
                       isSelected: false, sourceID: restored.currentSourceID)
        }

        XCTAssertEqual(restored.detectedFaces.filter(\.isSelected).count, 2,
                       "後から現れた顔に下書きの選択が適用されていない")
        XCTAssertFalse(restored.canUndo, "復元した選択が undo 可能な編集として積まれている")
    }

    /// 目印の適用が保留中（冒頭に顔が写らない動画の復元）に**素材を追加**しても、
    /// 追加素材の顔の自動選択が打ち消されないこと。
    ///
    /// 保留中の目印は復元時点の素材に向けられたものなので、復元後に追加された素材には
    /// 当てはまらない（「保存時に非選択だった」という解釈は、保存時に存在しなかった
    /// 素材には成立しない）。打ち消されると追加クリップの区間だけモザイクが乗らない
    /// ＝顔が露出する。
    func test_pendingRestore_doesNotDeselectFacesOfSourceAddedAfterRestore() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelPendingAppend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = try await saveDraftWithSelection(
            store: store, url: url, faces: [(fakeFace(cx: 0.2, cy: 0.3), true)])

        // 初期スキャンが空 → 目印は保留される
        let restored = try await restoreDraft(saved.draft, from: store,
                                              primarySourceID: saved.sourceID,
                                              scannedFaces: [])
        XCTAssertTrue(restored.detectedFaces.isEmpty)

        // 保留中に素材を追加（実顔が無いので seed は空。素材登録だけが起きる）
        let added = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: added) }
        await restored.appendVideoClip(url: added)
        let addedSourceID = try XCTUnwrap(restored.timeline.clips.last?.sourceID)
        XCTAssertNotEqual(addedSourceID, saved.sourceID, "クリップが追加されていない")

        // seedVideoDetection と同じ形（検出した顔すべてを即選択して追記）
        restored.detectedFaces += [fakeFace(cx: 0.7, cy: 0.6)].map {
            FaceTarget(id: UUID(), landmarks: $0, thumbnail: UIImage(),
                       isSelected: true, sourceID: addedSourceID)
        }

        let addedSelected = restored.detectedFaces
            .filter { $0.sourceID == addedSourceID && $0.isSelected }
        XCTAssertEqual(addedSelected.count, 1,
                       "追加素材の顔の選択が下書き復元の保留目印に打ち消されている（顔が露出する）")
    }

    /// 復元時点で下書きに含まれていた素材については、目印が 1 つも無い＝
    /// 「保存時に 0 個選択」という明示的な意思なので、非選択へ戻すこと
    /// （上のテストの対照。追加素材を触らない修正が、この意味論まで壊していないこと）。
    func test_draftRestore_emptyAnchorsStillDeselectFacesOfSavedSource() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceSelEmpty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        // 全部の顔を非選択にして保存（faceSelections == []）
        let saved = try await saveDraftWithSelection(
            store: store, url: url, faces: [(fakeFace(cx: 0.5, cy: 0.4), false)])
        XCTAssertEqual(saved.draft.faceSelections, [], "0 個選択が保存されていない")

        // 復元時に顔が 1 つ見つかる → 自動選択規則では選択される
        let restored = try await restoreDraft(saved.draft, from: store,
                                              primarySourceID: saved.sourceID,
                                              scannedFaces: [fakeFace(cx: 0.5, cy: 0.4)])
        XCTAssertEqual(restored.detectedFaces.filter(\.isSelected).count, 0,
                       "保存時に非選択だった顔が復元で選択されている")
    }

    /// 複数クリップの顔一覧が、再生中のライブ検出で壊れないこと。
    ///
    /// かつては「再検出」ボタンが顔一覧をその素材ぶん作り直しており、素材スコープを
    /// 誤ると**他素材の顔と選択が丸ごと消える**（その区間のモザイクが外れる）。
    /// ボタンは撤去したので、いま同じ事故を起こしうるのはライブ検出だけになった。
    /// ライブ検出は顔一覧が空のときしか作らない契約なので、それを固定する。
    ///
    /// 合成テスト動画には実顔が写らないため、顔一覧は直接注入する（他テストと同じ手法）。
    func test_liveDetection_doesNotDisturbOtherSourceFaces() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let sourceA = model.currentSourceID
        let sourceB = UUID()

        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.2, cy: 0.2), thumbnail: UIImage(),
                       isSelected: true, sourceID: sourceA),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.8, cy: 0.8), thumbnail: UIImage(),
                       isSelected: true, sourceID: sourceB)
        ]
        let idsBefore = model.detectedFaces.map(\.id)

        // A を再生した相当のライブ検出（A の顔が少し動いた）。
        for i in 0..<10 {
            model.storeLiveDetection([fakeFace(cx: 0.25 + Double(i) * 0.01, cy: 0.22)],
                                     at: model.liveBucket(Double(i) / 15.0), source: UIImage())
        }

        XCTAssertEqual(model.detectedFaces.map(\.id), idsBefore,
                       "ライブ検出で顔一覧が作り直されている（他素材の顔と選択が飛ぶ）")
        XCTAssertTrue(model.detectedFaces.allSatisfy(\.isSelected),
                      "ライブ検出で選択が外れている")
        XCTAssertEqual(model.detectedFaces.filter { $0.sourceID == sourceB }.count, 1,
                       "再生していない素材の顔が消えている")
    }

    /// 途中から現れた人物の自動追加が、**他素材の顔と選択に触れない**こと。
    /// 追加は末尾追記で、既存の並び・ID・選択はそのまま残る。
    func test_personAdmission_appendsWithoutTouchingOtherSourceFaces() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        let sourceA = model.currentSourceID
        let sourceB = UUID()

        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.2, cy: 0.2), thumbnail: UIImage(),
                       isSelected: true, sourceID: sourceA),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.8, cy: 0.8), thumbnail: UIImage(),
                       isSelected: false, sourceID: sourceB)
        ]
        let idsBefore = model.detectedFaces.map(\.id)
        let selectionBefore = model.detectedFaces.map(\.isSelected)

        // 1 軸だけ立てた署名 = 既知の誰とも直交する未知の人物。
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[7] = 1
        guard let signature = FaceSignature(rawValues: values) else {
            return XCTFail("署名を作れない")
        }
        for t in [0.0, 0.5, 1.0] {
            model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                       sourceID: sourceA, sourceTime: t, frame: UIImage())
        }

        XCTAssertEqual(model.detectedFaces.count, 3, "自動追加が反映されていない")
        XCTAssertEqual(Array(model.detectedFaces.prefix(2).map(\.id)), idsBefore,
                       "既存の顔の並び／ID が自動追加で入れ替わっている")
        XCTAssertEqual(Array(model.detectedFaces.prefix(2).map(\.isSelected)), selectionBefore,
                       "既存の顔の選択が自動追加で書き換わっている")
        XCTAssertEqual(model.detectedFaces.last?.isSelected, true,
                       "自動追加した顔が未選択で入っている")
    }

    // MARK: - S11: 編集 → Undo/Redo → 下書き保存 → 復元の全結合ラウンドトリップ

    /// **A（モデル側）: 全機能を積み上げた状態が Undo/Redo で完全に往復し、
    /// 下書き保存 → 復元で余さず戻ること。**
    ///
    /// 動画 2 本 + 写真 1 枚に対して 分割・並べ替え・速度変更（0.5x/2x）・
    /// トランジション 2 種・モザイク適用区間 を順に適用し、
    /// 1. すべて undo すると初期状態（1 クリップ）まで戻る
    /// 2. すべて redo すると**完全に同じ TimelineState**（クリップ ID・順序・rate・
    ///    トランジション・適用区間）へ戻る
    /// 3. その状態 + 顔選択 + 粗さを下書きに保存し、再開すると全部復元される
    /// を実測で固定する。
    func test_S11_e2e_fullEditStack_undoRedoAndDraftRoundTrip() async throws {
        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S11E2EDraft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftsDir) }
        let store = DraftStore(directory: draftsDir)
        let urlA = try await makeTestVideo(seconds: 4.0)
        let urlB = try await makeTestVideo(seconds: 4.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let model = makeModel()
        model.load(videoURL: urlA)
        try await waitUntilLoaded(model)
        let sourceA = model.currentSourceID
        let initialTimeline = model.timeline
        XCTAssertEqual(model.clips.count, 1, "読み込み直後は 1 クリップのはず")
        XCTAssertFalse(model.canUndo, "読み込み直後が履歴基準になっていない")

        // 1) 動画をもう 1 本追加
        await model.appendVideoClip(url: urlB)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 2, "動画素材の追加でクリップが増えていない")

        // 2) 写真クリップを追加（既定 3s）
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let photoImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240),
                                                 format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        await model.appendPhotoClip(image: photoImage)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 3, "写真クリップが追加されていない")
        XCTAssertEqual(model.timeline.photoSourceIDs.count, 1,
                       "写真素材が photo として登録されていない")

        // 3) 先頭クリップを分割（合成尺 4+4+3=11s の 0.2 = 2.2s → clip0 の内側）
        model.playbackPosition = 0.2
        XCTAssertEqual(model.compositionTime(forPosition: 0.2), 2.2, accuracy: 0.05,
                       "正規化位置 → 合成時刻の換算が想定と違う")
        model.splitAtCurrentPosition()
        XCTAssertEqual(model.clips.count, 4, "分割でクリップが増えていない")

        // 4) 並べ替え: 分割した 2 本目を末尾へ
        let movedID = model.clips[1].id
        model.moveClip(id: movedID, toIndex: 3)
        XCTAssertEqual(model.clips.last?.id, movedID, "並べ替えが反映されていない")

        // 5) 速度変更 0.5x / 2x
        model.setClipRate(id: model.clips[0].id, rate: 0.5)
        model.setClipRate(id: model.clips[1].id, rate: 2.0)
        XCTAssertEqual(model.clips[0].rate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.clips[1].rate, 2.0, accuracy: 1e-9)

        // 6) トランジション 2 種
        model.setTransition(afterClipID: model.clips[0].id, kind: .crossfade, duration: 0.5)
        model.setTransition(afterClipID: model.clips[1].id, kind: .wipeLeft, duration: 0.5)
        XCTAssertEqual(model.timeline.transitions.count, 2, "トランジションが 2 本入っていない")

        // 7) モザイク適用区間
        model.addMosaicApplyRange(fromCompositionTime: 0.5, to: 2.0)
        XCTAssertFalse(model.timeline.applyRanges.isEmpty, "適用区間が入っていない")
        await model.awaitPendingTimelineRebuild()

        let fullState = model.timeline
        XCTAssertTrue(fullState.validate(), "積み上げた状態が validate を通らない")
        let fullDuration = model.videoDuration
        print("[S11-MODEL] clips=\(fullState.clips.count) "
              + "transitions=\(fullState.transitions.count) "
              + "applyRanges=\(fullState.applyRanges.count) "
              + String(format: "尺=%.3f", fullDuration))

        // --- Undo: 全部戻す ---
        var undoSteps = 0
        while model.canUndo {
            model.undo()
            undoSteps += 1
            XCTAssertLessThan(undoSteps, 50, "undo が終わらない（履歴が循環している）")
        }
        print("[S11-MODEL] undo 段数=\(undoSteps) 戻り先クリップ数=\(model.clips.count)")
        XCTAssertEqual(model.timeline, initialTimeline,
                       "全 undo で読み込み直後の状態に戻っていない")

        // --- Redo: 全部やり直す ---
        var redoSteps = 0
        while model.canRedo {
            model.redo()
            redoSteps += 1
            XCTAssertLessThan(redoSteps, 50, "redo が終わらない")
        }
        XCTAssertEqual(redoSteps, undoSteps, "redo の段数が undo と一致しない")
        XCTAssertEqual(model.timeline, fullState,
                       "全 redo で編集後の状態が完全復元されない"
                       + "（クリップID・順序・rate・トランジション・適用区間）")
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.videoDuration, fullDuration, accuracy: 0.05,
                       "redo 後の合成尺が編集直後と違う")

        // --- 顔選択と粗さを設定して下書き保存 ---
        model.faceBlockSize = 44
        model.backgroundBlockSize = 36
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.25, cy: 0.4),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceA),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.75, cy: 0.4),
                       thumbnail: UIImage(), isSelected: false, sourceID: sourceA)
        ]
        let anchors = model.selectedFaceAnchors
        XCTAssertEqual(anchors.count, 1, "選択中の顔だけがアンカーになっていない")

        let saved = try XCTUnwrap(store.saveVideoDraft(
            existing: nil,
            sources: model.draftSources,
            sessionSourceIDs: model.sessionReferencedSourceIDs,
            timeline: model.timeline,
            faceMosaicOn: true, backgroundMosaicOn: true,
            faceBlockSize: 44, backgroundBlockSize: 36,
            objectMasks: [],
            faceSelections: anchors, thumbnail: nil))
        // **旧スキーマ**の下書き（矩形 1 個・時間軸なし）を模す。新規保存では
        // `legacyManualRects` に値が入る経路は無いので、ここで直接組み立てる。
        let draft = EditingDraft(
            id: saved.id, kind: .video, sourceFileName: saved.sourceFileName,
            sources: saved.sources, timeline: saved.timeline,
            faceMosaicOn: saved.faceMosaicOn, backgroundMosaicOn: saved.backgroundMosaicOn,
            faceBlockSize: saved.faceBlockSize, backgroundBlockSize: saved.backgroundBlockSize,
            objectMasks: [],
            legacyManualRects: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)],
            faceSelections: saved.faceSelections, personProfiles: saved.personProfiles,
            thumbnailFileName: saved.thumbnailFileName)
        XCTAssertEqual(draft.sources.count, 3, "3 素材ぶんが下書きに登録されていない")

        // --- 復元 ---
        let restored = try await restoreDraft(
            draft, from: store, primarySourceID: sourceA,
            scannedFaces: [fakeFace(cx: 0.25, cy: 0.4), fakeFace(cx: 0.75, cy: 0.4)])
        await restored.awaitPendingTimelineRebuild()

        XCTAssertEqual(restored.timeline, fullState,
                       "下書き復元でタイムラインが完全一致しない")
        XCTAssertEqual(restored.timeline.applyRanges.count, fullState.applyRanges.count,
                       "適用区間が復元されていない")
        XCTAssertEqual(restored.timeline.transitions, fullState.transitions,
                       "トランジションが復元されていない")
        XCTAssertEqual(restored.faceBlockSize, 44, accuracy: 1e-6, "顔の粗さが復元されていない")
        XCTAssertEqual(restored.backgroundBlockSize, 36, accuracy: 1e-6,
                       "背景の粗さが復元されていない")
        XCTAssertTrue(restored.backgroundMosaicOn, "背景モザイクの ON/OFF が復元されていない")
        // 旧 `manualRects` は**全クリップへ 1 本ずつ**移行される。先頭だけに付けると、
        // 3 クリップ構成の下書きを再開したときクリップ 2・3 のモザイクが消える。
        XCTAssertEqual(restored.objectMasks.count, restored.timeline.clips.count,
                       "旧手動矩形が全クリップへ配られていない")
        XCTAssertEqual(Set(restored.objectMasks.compactMap(\.anchor.clipID)),
                       Set(restored.timeline.clips.map(\.id)))
        XCTAssertEqual(restored.videoDuration, fullDuration, accuracy: 0.1,
                       "復元後の合成尺が保存時と違う")

        let selected = restored.detectedFaces.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1,
                       "顔選択が復元されていない（選択数=\(selected.count)）")
        let centroid = restored.normalizedCentroid(of: try XCTUnwrap(selected.first).landmarks)
        XCTAssertEqual(Double(centroid.x), 0.25, accuracy: 0.05,
                       "復元された選択が別の顔に付いている")
        print("[S11-MODEL] 復元 OK clips=\(restored.clips.count) "
              + "applyRanges=\(restored.timeline.applyRanges.count) "
              + "faceBlock=\(restored.faceBlockSize) 選択=\(selected.count)")
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
        XCTAssertNil(draft.faceSelections,
                     "顔選択キーの無い旧下書きが『0 個選択』に化けている（復元で顔の選択が外れる）")
    }

    // MARK: - 顔選択（faceSelections）

    /// 顔選択キーを持たない下書き JSON がデコードで壊れず、nil（＝情報なし）に
    /// なること。`sources` / `timeline` を持つ v2 下書きも対象。
    func test_draftWithoutFaceSelectionsKey_decodesAsNil() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555566667777",
         "kind":"video",
         "sourceFileName":"source-V2.mov",
         "faceMosaicOn":true,
         "backgroundMosaicOn":false,
         "faceBlockSize":28,
         "backgroundBlockSize":28,
         "manualRects":[],
         "sources":[{"id":"AAAAAAAA-2222-3333-4444-555566667777","fileName":"source-V2.mov"}]}
        """
        let draft = try JSONDecoder().decode(EditingDraft.self, from: Data(json.utf8))
        XCTAssertNil(draft.faceSelections)
        XCTAssertEqual(draft.sources.first?.fileName, "source-V2.mov")
    }

    /// 顔選択（素材ID＋正規化重心）が保存 → 再読込で往復すること。
    /// 「0 個選択（空配列）」と「情報なし（nil）」が区別されたまま残ること。
    func test_faceSelections_roundTripsAndKeepsEmptyDistinctFromNil() throws {
        let store = makeStore()
        let url = try makeSourceFile("faces.mov")
        let source = UUID()
        let anchors = [DraftFaceSelection(sourceID: source, centroid: CGPoint(x: 0.25, y: 0.4)),
                       DraftFaceSelection(sourceID: nil, centroid: CGPoint(x: 0.75, y: 0.6))]
        let saved = try XCTUnwrap(store.saveVideoDraft(
            existing: nil, sources: [(source, url)],
            timeline: TimelineState(clips: [TimelineClip(sourceID: source,
                                                         sourceStart: 0, sourceEnd: 1)]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], faceSelections: anchors, thumbnail: nil))

        let reloaded = try XCTUnwrap(makeStore().videoDrafts.first { $0.id == saved.id })
        XCTAssertEqual(reloaded.faceSelections, anchors,
                       "顔選択（素材ID・重心）が保存 → 再読込で往復していない")

        // 0 個選択は空配列として残る（nil ＝情報なしに化けない）。
        let empty = try XCTUnwrap(store.saveVideoDraft(
            existing: saved.id, sources: [(source, url)],
            timeline: reloaded.timeline,
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], faceSelections: [], thumbnail: nil))
        let reloadedEmpty = try XCTUnwrap(makeStore().videoDrafts.first { $0.id == empty.id })
        XCTAssertEqual(reloadedEmpty.faceSelections, [],
                       "『0 個選択』が『情報なし』に化けている")
    }

    /// 人物（`personProfiles`）を持たない下書き JSON がデコードで壊れず、nil になること。
    /// この機能より前に保存された下書きは目印の `personID` も nil なので、
    /// 復元は従来どおり重心照合だけで進む。
    func test_draftWithoutPersonProfilesKey_decodesAsNil() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555566667777",
         "kind":"video",
         "sourceFileName":"source-V2.mov",
         "faceMosaicOn":true,
         "backgroundMosaicOn":false,
         "faceBlockSize":28,
         "backgroundBlockSize":28,
         "manualRects":[],
         "faceSelections":[{"centroid":[0.2,0.3]}]}
        """
        let draft = try JSONDecoder().decode(EditingDraft.self, from: Data(json.utf8))
        XCTAssertNil(draft.personProfiles)
        XCTAssertEqual(draft.faceSelections?.count, 1)
        XCTAssertNil(draft.faceSelections?.first?.personID, "旧目印に人物 ID が生えている")
    }

    /// 人物と、それを指す目印の `personID` が保存 → 再読込で往復すること。
    func test_personProfiles_roundTrip() throws {
        let store = makeStore()
        let url = try makeSourceFile("person.mov")
        let source = UUID()
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[0] = 1
        let profile = PersonProfile(exemplars: [try XCTUnwrap(FaceSignature(rawValues: values))])
        let anchors = [DraftFaceSelection(sourceID: source, centroid: CGPoint(x: 0.25, y: 0.4),
                                          personID: profile.id)]
        let saved = try XCTUnwrap(store.saveVideoDraft(
            existing: nil, sources: [(source, url)],
            timeline: TimelineState(clips: [TimelineClip(sourceID: source,
                                                         sourceStart: 0, sourceEnd: 1)]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], faceSelections: anchors, personProfiles: [profile], thumbnail: nil))

        let reloaded = try XCTUnwrap(makeStore().videoDrafts.first { $0.id == saved.id })
        XCTAssertEqual(reloaded.faceSelections, anchors, "目印の人物 ID が往復していない")
        XCTAssertEqual(reloaded.personProfiles, [profile], "人物（手本）が往復していない")
        XCTAssertEqual(makeStore().personProfiles(forDraftID: saved.id), [profile],
                       "下書きID から人物を引けない")
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
            objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil)
        let draftB = store.saveVideoDraft(
            existing: nil,
            sources: [(id: shared, url: sharedURL)],
            timeline: TimelineState(clips: [sharedClip]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil))
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
            objectMasks: [], thumbnail: nil)
        XCTAssertTrue(draftsDirContents(of: store).contains(nameY),
                      "セッションが undo 用に参照中の素材コピーが GC された")

        // 保護リスト無し（既定）の再保存では、未参照になった Y のコピーは GC される
        _ = store.saveVideoDraft(
            existing: draft.id,
            sources: [(id: sourceX, url: copiedX)],
            timeline: TimelineState(clips: [clipX]),
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil)
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
            objectMasks: [], thumbnail: nil))

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
            objectMasks: [], thumbnail: nil))

        XCTAssertEqual(resaved.sources.first?.fileName, copiedURL.lastPathComponent,
                       "フォルダ内素材が別名で二重コピーされた")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path),
                      "参照し続けるはずの素材コピーが消えた")
    }
}

/// S6: `PhotoClipEncoder`（写真 → 静止 mp4 の事前エンコード）の出力検証。
///
/// 新規テストファイルは `xcodegen generate`（禁止）無しでは MaskMeTests ターゲットに
/// 入らないため、このファイルに別クラスとして同居させている。
final class PhotoClipEncoderTests: XCTestCase {
    /// 単色のテスト画像（scale 1 = 指定サイズがそのままピクセル寸法）。
    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 4 象限が異なる色（TL 赤・TR 緑・BL 青・BR 白）のテスト画像。
    /// EXIF 向きの正規化で「どの色がどの隅に来るか」を追跡するために使う。
    private func quadrantImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            let halfW = width / 2
            let halfH = height / 2
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
            UIColor.green.setFill()
            ctx.fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
        }
    }

    /// 正規化座標（左上原点）で指定した位置のピクセル色（RGB 0...255）を読む。
    private func pixelColor(in cgImage: CGImage, atNormalized point: CGPoint) -> [Int] {
        let x = min(cgImage.width - 1, Int(CGFloat(cgImage.width) * point.x))
        let yFromTop = min(cgImage.height - 1, Int(CGFloat(cgImage.height) * point.y))
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .none
        // CGContext は左下原点: 上から yFromTop 行目 = 下から (height-1-yFromTop) 行目。
        let yFromBottom = cgImage.height - 1 - yFromTop
        ctx.draw(cgImage, in: CGRect(x: -CGFloat(x), y: -CGFloat(yFromBottom),
                                     width: CGFloat(cgImage.width),
                                     height: CGFloat(cgImage.height)))
        return [Int(data[0]), Int(data[1]), Int(data[2])]
    }

    /// 出力 mp4 の先頭フレームを CGImage で取り出す。
    private func firstFrame(of url: URL) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// 許容 90: H.264 の YUV 変換で純色（特に緑）は 1 チャンネルあたり最大 ~70 ずれる
    /// 実測がある。象限の 4 色（赤/緑/青/白）はどのペアも必ずどこかのチャンネルで
    /// 255 差があるため、90 でも隅の取り違え（向きの誤り）は検出できる。
    private func assertColor(_ actual: [Int], near expected: [Int], tolerance: Int = 90,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 3, message, file: file, line: line)
        guard actual.count == 3 else { return }
        for (a, e) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(a - e), tolerance,
                                     "\(message)（actual=\(actual) expected=\(expected)）",
                                     file: file, line: line)
        }
    }

    /// EXIF ミラー系 4 方位（upMirrored/downMirrored/leftMirrored/rightMirrored）も
    /// エンコード前に正規化されること。解析的アンカー（upMirrored 左上=元画像右上の緑、
    /// downMirrored 左上=元画像左下の青）でグラウンドトゥルース自体の破損も検知する。
    func test_encode_normalizesMirroredEXIFOrientationsBeforeEncoding() async throws {
        let base = try XCTUnwrap(quadrantImage(width: 64, height: 32).cgImage)
        let corners = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                       CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
        for orientation in [UIImage.Orientation.upMirrored, .downMirrored,
                            .leftMirrored, .rightMirrored] {
            let oriented = UIImage(cgImage: base, scale: 1, orientation: orientation)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let expected = try XCTUnwrap(
                UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
                    oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
                }.cgImage)
            let encoded = try await PhotoClipEncoder().encode(image: oriented, seconds: 0.2)
            defer { try? FileManager.default.removeItem(at: encoded.url) }
            let frame = try firstFrame(of: encoded.url)
            XCTAssertEqual(frame.width, expected.width, "orientation=\(orientation.rawValue): 幅不一致")
            XCTAssertEqual(frame.height, expected.height, "orientation=\(orientation.rawValue): 高さ不一致")
            for corner in corners {
                assertColor(pixelColor(in: frame, atNormalized: corner),
                            near: pixelColor(in: expected, atNormalized: corner),
                            "orientation=\(orientation.rawValue) corner=\(corner)")
            }
        }
        // 解析的アンカー（グラウンドトゥルース自体の破損検知）
        let upMirrored = try await PhotoClipEncoder().encode(
            image: UIImage(cgImage: base, scale: 1, orientation: .upMirrored), seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: upMirrored.url) }
        assertColor(pixelColor(in: try firstFrame(of: upMirrored.url),
                               atNormalized: CGPoint(x: 0.25, y: 0.25)),
                    near: [0, 255, 0], ".upMirrored の左上が元画像の右上（緑）でない")
        let downMirrored = try await PhotoClipEncoder().encode(
            image: UIImage(cgImage: base, scale: 1, orientation: .downMirrored), seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: downMirrored.url) }
        assertColor(pixelColor(in: try firstFrame(of: downMirrored.url),
                               atNormalized: CGPoint(x: 0.25, y: 0.25)),
                    near: [0, 0, 255], ".downMirrored の左上が元画像の左下（青）でない")
    }

    /// 尺の上限クランプ（60s）・15fps・音声トラックなし、が出力に反映されること。
    func test_encode_clampsDurationTo60s_at15fps_withoutAudio() async throws {
        let encoded = try await PhotoClipEncoder().encode(
            image: solidImage(width: 320, height: 240), seconds: 100)
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        XCTAssertEqual(encoded.duration, 60.0, accuracy: 1e-9, "返り値の尺が 60s にクランプされていない")

        let asset = AVURLAsset(url: encoded.url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 60.0, accuracy: 0.1,
                       "出力 mp4 の実尺が 60s にクランプされていない")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let fps = try await videoTrack.load(.nominalFrameRate)
        XCTAssertEqual(Double(fps), 15.0, accuracy: 0.5, "フレームレートが 15fps でない")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "写真クリップに音声トラックが入っている")
    }

    /// 指定秒数（クランプ内）がそのまま実尺になること。
    func test_encode_producesRequestedDuration() async throws {
        let encoded = try await PhotoClipEncoder().encode(
            image: solidImage(width: 320, height: 240), seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        XCTAssertEqual(encoded.duration, 3.0, accuracy: 1e-9)
        let duration = try await AVURLAsset(url: encoded.url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.0, accuracy: 0.05,
                       "指定秒数どおりの実尺になっていない")
    }

    /// 長辺 1920px 超の画像が、アスペクト比を保って 1920px 上限へ縮小されること。
    func test_encode_capsLongSideTo1920() async throws {
        let encoded = try await PhotoClipEncoder().encode(
            image: solidImage(width: 2560, height: 1440), seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        let tracks = try await AVURLAsset(url: encoded.url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1920, accuracy: 1, "長辺が 1920px に縮小されていない")
        XCTAssertEqual(size.height, 1080, accuracy: 1, "アスペクト比が維持されていない")
    }

    /// EXIF 4 方位（up/down/left/right）の写真が、**エンコード前に**向き正規化され、
    /// 出力フレームのピクセルが表示どおりの向きになること（正規化前エンコード事故の検出）。
    func test_encode_normalizesEXIFOrientationBeforeEncoding() async throws {
        let base = try XCTUnwrap(quadrantImage(width: 64, height: 32).cgImage)
        let corners = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                       CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
        for orientation in [UIImage.Orientation.up, .down, .left, .right] {
            let oriented = UIImage(cgImage: base, scale: 1, orientation: orientation)
            // UIKit の描画（orientation 適用済み）を期待値のグラウンドトゥルースにする。
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let expected = try XCTUnwrap(
                UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
                    oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
                }.cgImage)

            let encoded = try await PhotoClipEncoder().encode(image: oriented, seconds: 0.2)
            defer { try? FileManager.default.removeItem(at: encoded.url) }
            let frame = try firstFrame(of: encoded.url)

            XCTAssertEqual(frame.width, expected.width,
                           "orientation=\(orientation.rawValue): 出力幅が表示向きと一致しない")
            XCTAssertEqual(frame.height, expected.height,
                           "orientation=\(orientation.rawValue): 出力高さが表示向きと一致しない")
            for corner in corners {
                assertColor(pixelColor(in: frame, atNormalized: corner),
                            near: pixelColor(in: expected, atNormalized: corner),
                            "orientation=\(orientation.rawValue) corner=\(corner): " +
                            "向き正規化がエンコード前に行われていない")
            }
        }
        // 解析的な検証（グラウンドトゥルース自体の破損検知）: .down は 180° 回転なので
        // 表示の左上 = 元画像の右下（白）。.up は元のまま左上 = 赤。
        let up = try await PhotoClipEncoder().encode(
            image: UIImage(cgImage: base, scale: 1, orientation: .up), seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: up.url) }
        assertColor(pixelColor(in: try firstFrame(of: up.url), atNormalized: corners[0]),
                    near: [255, 0, 0], ".up の左上が元画像の左上（赤）でない")
        let down = try await PhotoClipEncoder().encode(
            image: UIImage(cgImage: base, scale: 1, orientation: .down), seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: down.url) }
        assertColor(pixelColor(in: try firstFrame(of: down.url), atNormalized: corners[0]),
                    near: [255, 255, 255], ".down の左上が元画像の右下（白）でない")
    }
}

/// S6: 写真クリップのモデル層テスト（appendPhotoClip・素材時刻 clamp・検出抑止）。
@MainActor
final class PhotoClipModelTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // **「顔モザイクをかける」までを再現する。** 動画モードの既定は OFF
        // （開いただけでは掛からない）で、ライブ検出も描画も `faceMosaicOn` を見ている。
        // 既定そのものを検証したいテストは `MosaicReapplyFlowTests` にある。
        model.faceMosaicOn = true
        return model
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

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// テスト用の単色動画（320x240 = PhotoClipEncoder 出力と同解像度。
    /// S6 時点の builder は解像度混在を明示エラーにするため揃える）。
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
        for i in 0..<Int(seconds * 30) {
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
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
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

    /// appendPhotoClip が「動画素材を追加」経路へ無分岐で合流すること:
    /// クリップ末尾追加・kind=.photo 登録・t=0 seed・合成尺追随・composition 再構築・
    /// 下書き素材列（draftSources）への追随・undo/redo まで既存機構で動く。
    func test_appendPhotoClip_joinsExistingSourceAppendPath() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)

        await model.appendPhotoClip(image: solidImage(width: 320, height: 240), seconds: 2.0)
        await model.awaitPendingTimelineRebuild()

        XCTAssertNil(model.errorMessage, "写真クリップの追加でエラーになった")
        XCTAssertEqual(model.clips.count, 2, "写真クリップが追加されていない")
        let photoClip = try XCTUnwrap(model.clips.last)
        XCTAssertEqual(photoClip.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(photoClip.sourceEnd, 2.0, accuracy: 0.05, "写真クリップの尺が指定秒数でない")
        XCTAssertEqual(model.timeline.sourceKind(of: photoClip.sourceID), .photo,
                       "素材種別が .photo で登録されていない")
        XCTAssertEqual(model.videoDuration, 3.0, accuracy: 0.1, "合成尺が写真クリップ分伸びていない")
        XCTAssertTrue(model.cacheStore.hasEntry(sourceID: photoClip.sourceID, time: 0),
                      "写真の検出が素材時刻 t=0 に seed されていない")
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration)
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), 3.0, accuracy: 0.1,
                       "composition が写真クリップ込みで再構築されていない")
        XCTAssertEqual(model.draftSources.count, 2,
                       "写真素材が下書き保存の素材列（draftSources）に載っていない")
        XCTAssertTrue(model.timeline.validate())

        // 既存の undo/redo 機構にそのまま乗ること（専用機構を作っていない証明）
        model.undo()
        XCTAssertEqual(model.clips.count, 1, "undo で写真クリップの追加が取り消されない")
        model.redo()
        XCTAssertEqual(model.clips.count, 2, "redo で写真クリップが復元されない")
        XCTAssertEqual(model.timeline.sourceKind(of: photoClip.sourceID), .photo,
                       "redo 後に素材種別が失われた")
    }

    /// **契約の更新（S6 → S8）**: 解像度不一致の写真 append は、S6 では
    /// 「一切の状態変異より前に reject（`mixedVideoFormats` と同一基準）」だった。
    /// S8 で `AVVideoComposition` による解像度混在を正式解禁したので、
    /// **追加され、合成される**のが正しい契約になった。
    ///
    /// 併せて「reject 時に残していた不整合（壊れたクリップ・世代不一致 = export 恒久
    /// 拒否・汎用エラー）が起きない」ことは、成功経路の不変条件として引き続き見る。
    func test_appendPhotoClip_mismatchedResolution_isComposedWithLetterbox() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()

        let clipsBefore = model.clips.count

        // 320x240 の動画に 100x80 の写真（S6 までは mixedVideoFormats で reject していた組）
        await model.appendPhotoClip(image: solidImage(width: 100, height: 80), seconds: 2.0)
        await model.awaitPendingTimelineRebuild()

        XCTAssertNil(model.errorMessage, "解像度混在の写真追加が拒否された（S8 で解禁済み）")
        XCTAssertEqual(model.clips.count, clipsBefore + 1, "写真クリップが追加されていない")
        XCTAssertEqual(model.compositionGeneration, model.timelineGeneration,
                       "追加後に世代不一致（export 恒久拒否状態）が残った")
        XCTAssertTrue(model.timeline.validate())
        let composition = try XCTUnwrap(model.composition)
        XCTAssertEqual(CMTimeGetSeconds(composition.duration), 3.0, accuracy: 0.15,
                       "混在クリップ込みで composition が再構築されていない")
        // 混在 → videoComposition が装着され、renderSize は先頭（動画）クリップ基準。
        let videoComposition = try XCTUnwrap(model.videoComposition,
                                             "解像度混在なのに videoComposition が装着されていない")
        XCTAssertEqual(videoComposition.renderSize, CGSize(width: 320, height: 240))
        // 写真クリップは左右に帯（100x80 = 5:4 を 4:3 のフレームへフィット）。
        let photoClipID = try XCTUnwrap(model.clips.last?.id)
        let placement = model.renderLayout.placement(for: photoClipID)
        XCTAssertLessThan(placement.width, 1.0, "レターボックスの配置が計算されていない")
        XCTAssertEqual(placement.height, 1.0, accuracy: 1e-6)
        XCTAssertEqual(placement.minX, (1 - placement.width) / 2, accuracy: 1e-6,
                       "レターボックスが中央寄せになっていない")
    }

    /// クリップ未構築（動画ロード前）では追加せず、理由を errorMessage で知らせること。
    func test_appendPhotoClip_withoutTimeline_reportsError() async {
        let model = makeModel()
        await model.appendPhotoClip(image: solidImage(width: 320, height: 240))
        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertNotNil(model.errorMessage, "追加できない理由が通知されない（無言 no-op）")
    }

    /// 写真クリップ区間の素材時刻が 0 に clamp され、t=0 seed 後は
    /// 2 回目以降の実検出（shouldDetectPreviewFrame）が発火しないこと。
    /// ライブ検出の書き込みも bucket 0 へ集約され、キャッシュが 1 エントリのまま増えないこと。
    func test_photoRegion_clampsSourceTimeToZero_andSuppressesRedetection() {
        let model = makeModel()
        let videoID = model.currentSourceID
        let photoID = UUID()
        model.setTimelineForTesting(TimelineState(
            clips: [
                TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2),
                TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)
            ],
            sources: [photoID: TimelineSource(id: photoID, kind: .photo)]))

        // 写像 → clamp: 写真区間（合成 [2,5)）は常に素材時刻 0
        let resolved = model.resolveSourceTime(atComposition: 3.5)
        XCTAssertEqual(resolved.sourceID, photoID)
        XCTAssertEqual(resolved.time, 0, "写真区間の素材時刻が 0 に clamp されない")
        // 動画区間は恒等（挙動不変）
        let videoResolved = model.resolveSourceTime(atComposition: 1.0)
        XCTAssertEqual(videoResolved.sourceID, videoID)
        XCTAssertEqual(videoResolved.time, 1.0, accuracy: 1e-9)

        // seed 前は検出対象、seed 後は写真区間のどの時刻でも検出しない。
        // **ライブ検出は `faceMosaicOn` を見ている**（掛けないなら検出も走らせない）。
        // 動画モードの既定は OFF なので、ここで「掛ける」状態にしないと
        // 何を測っても常に false になる。
        model.faceMosaicOn = true
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 3.5), "seed 前に検出が抑止されている")
        model.cacheStore.store([fakeFace()], sourceID: photoID, time: 0)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 2.0),
                       "seed 済みの写真区間で 2 回目の実検出が発火する")
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 4.9),
                       "seed 済みの写真区間（別バケット相当の時刻）で実検出が発火する")

        // lookup も全時刻が seed にヒットする
        XCTAssertFalse(model.lookupFaces(at: 2.1).isEmpty, "写真区間の lookup が seed にヒットしない")
        XCTAssertFalse(model.lookupFaces(at: 4.5).isEmpty)

        // ライブ検出の書き込みも bucket 0 に集約され、エントリが増殖しない
        let entriesBefore = model.cacheStore.allEntries.keys.filter { $0.sourceID == photoID }
        model.storeLiveDetection([fakeFace()], at: 4.0, source: UIImage())
        let entriesAfter = model.cacheStore.allEntries.keys.filter { $0.sourceID == photoID }
        XCTAssertEqual(entriesBefore.count, 1)
        XCTAssertEqual(entriesAfter.count, 1,
                       "写真区間のライブ検出書き込みが素材時刻 0 以外のバケットを作った")
        XCTAssertEqual(entriesAfter.first?.bucket, 0)
    }
}

/// S8: トランジションの重なり区間におけるモデル層の振る舞い
/// （両クリップの顔の union・選択照合スコープ・ライブ検出の停止）。
@MainActor
final class TransitionOverlapModelTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // **「顔モザイクをかける」までを再現する。** 動画モードの既定は OFF
        // （開いただけでは掛からない）で、ライブ検出も描画も `faceMosaicOn` を見ている。
        // 既定そのものを検証したいテストは `MosaicReapplyFlowTests` にある。
        model.faceMosaicOn = true
        return model
    }

    private func fakeFace(cx: Double, cy: Double, size: Double = 0.1) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// 2 クリップ + crossfade（重なり [1.5, 2.0)）のモデルを組み、
    /// 各素材の検出キャッシュに 1 顔ずつ入れる。
    private func makeOverlapModel(kind: TransitionKind = .crossfade)
    -> (model: MosaicEditorModel, sourceA: UUID, sourceB: UUID) {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 2)
        // S11: 区間 0 本 = 全区間 OFF なので、新規プロジェクトの既定（クリップ全体を
        // 覆う区間）を明示的に入れる。ここで見たいのは重なり区間の顔の union であって
        // 適用区間ゲートではない。
        model.setTimelineForTesting(TimelineState(
            clips: [clipA, clipB],
            transitions: [clipA.id: TransitionSpec(kind: kind, duration: 0.5)],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: [])))
        // 重なり区間（合成 [1.5, 2.0)）に対応する素材時刻に顔を仕込む。
        // A は素材時刻 1.5〜2.0、B は素材時刻 0.0〜0.5。
        for time in stride(from: 1.5, through: 2.0, by: 0.1) {
            model.cacheStore.store([fakeFace(cx: 0.25, cy: 0.5)], sourceID: sourceA, time: time)
        }
        for time in stride(from: 0.0, through: 0.5, by: 0.1) {
            model.cacheStore.store([fakeFace(cx: 0.75, cy: 0.5)], sourceID: sourceB, time: time)
        }
        return (model, sourceA, sourceB)
    }

    /// 重なり区間では**両クリップの顔**が返ること（片側だけだと画面に映っている
    /// もう片方の顔が素通しになる）。重なり外は従来どおり 1 クリップぶん。
    func test_displayFacesUnionsBothClipsInsideOverlap() {
        let (model, _, _) = makeOverlapModel()
        // 重なり [1.5, 2.0) の中央。
        let faces = model.displayFaces(at: 1.75)
        XCTAssertEqual(faces.count, 2, "重なり区間で片側の顔しか返っていない（モザイク漏れ）")
        let centers = faces.map { Double($0.points[0].x + $0.points[1].x) / 2 }.sorted()
        XCTAssertEqual(centers[0], 0.25, accuracy: 0.02, "outgoing 側の顔位置がずれている")
        XCTAssertEqual(centers[1], 0.75, accuracy: 0.02, "incoming 側の顔位置がずれている")

        // 重なり外（A 単独区間）は 1 顔。
        XCTAssertEqual(model.displayFaces(at: 1.0).count, 1)
        // 単一位置の経路（lookupFaces）は重なり中でも incoming 側だけを返す
        // （検出キャッシュの書き込みキーなど、単一で正しい用途のために残してある）。
        XCTAssertEqual(model.lookupFaces(at: 1.75).count, 1)
    }

    /// スライドでは顔が画面移動量ぶん平行移動し、画面外へ出た側は落ちること
    /// （instruction のランプと同じ純関数から生成されている証拠）。
    func test_displayFacesFollowSlideTranslation() {
        let (model, _, _) = makeOverlapModel(kind: .slideLeft)

        // progress 0.2（合成 1.6）: outgoing（中心 0.25）は −0.2 移動して画面内、
        // incoming（中心 0.75）は +0.8 移動してまだ画面外。
        let early = model.displayFaces(at: 1.6)
        XCTAssertEqual(early.count, 1, "まだ画面に入っていない側の顔が残っている")
        XCTAssertEqual(Double(early[0].points[0].x + early[0].points[1].x) / 2, 0.25 - 0.2,
                       accuracy: 0.02, "outgoing 側がスライド量ぶん移動していない")

        // progress 0.8（合成 1.9）: outgoing は −0.8 で画面外、incoming は +0.2 で画面内。
        let late = model.displayFaces(at: 1.9)
        XCTAssertEqual(late.count, 1, "画面外へ抜けた側の顔が残っている")
        XCTAssertEqual(Double(late[0].points[0].x + late[0].points[1].x) / 2, 0.75 + 0.2,
                       accuracy: 0.02, "incoming 側がスライド量ぶん移動していない")
    }

    /// 選択顔の照合スコープが重なり区間では 2 素材ぶんに広がること。
    /// incoming 側だけにすると、画面に映っている outgoing 側の顔が選択照合で落ちる。
    func test_selectedLandmarksKeepsBothSidesInsideOverlap() {
        let (model, sourceA, sourceB) = makeOverlapModel()
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.25, cy: 0.5),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceA),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.75, cy: 0.5),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceB),
            // 非選択の顔を 1 つ混ぜて「全選択バイパス」に落ちないようにする。
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.5, cy: 0.9),
                       thumbnail: UIImage(), isSelected: false, sourceID: sourceB)
        ]
        XCTAssertEqual(model.selectedLandmarks(at: 1.75).count, 2,
                       "重なり区間で片側の選択顔が照合スコープから落ちている")
    }

    /// 重なり区間ではライブ検出を submit しないこと
    /// （合成済みフレームの検出結果を素材キーで書くとキャッシュが汚染される）。
    func test_liveDetectionIsSuspendedInsideOverlap() {
        let (model, _, _) = makeOverlapModel()
        model.faceMosaicOn = true
        // 未検出の時刻（重なり外）は検出対象。
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 0.5),
                      "重なり外の未検出フレームが検出対象になっていない")
        // 重なり区間は検出しない。
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 1.6),
                       "重なり区間でライブ検出が走る（キャッシュ汚染）")
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 1.99))
        // 重なりを抜けたら再開する。
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 2.5))
    }

    // MARK: - m-1: 選択顔の照合は素材座標で行う（座標系を混ぜない）

    /// 選択顔の照合が**視覚変換の前・素材座標**で行われること。
    ///
    /// スライドの重なり区間では顔が画面上で大きく平行移動する。合成座標の顔と
    /// 素材座標の `FaceTarget` を直接比べていた旧実装では、
    /// 「選択した顔にモザイクが乗らず、選択していないもう片方に乗る」という
    /// 取り違えが起きる（下のコメントの実測値）。
    func test_selectedLandmarksMatchesTargetsInSourceCoordinates() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 2)
        model.setTimelineForTesting(TimelineState(
            clips: [clipA, clipB],
            transitions: [clipA.id: TransitionSpec(kind: .slideLeft, duration: 0.5)],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: [])))
        // 重なり [1.5, 2.0)。t=1.85 → progress 0.7。
        // outgoing(A) は dx=−0.7、incoming(B) は dx=+0.3 平行移動する。
        for time in stride(from: 1.5, through: 2.0, by: 0.1) {
            model.cacheStore.store([fakeFace(cx: 0.95, cy: 0.5)], sourceID: sourceA, time: time)
        }
        for time in stride(from: 0.0, through: 0.5, by: 0.1) {
            model.cacheStore.store([fakeFace(cx: 0.5, cy: 0.5)], sourceID: sourceB, time: time)
        }
        model.detectedFaces = [
            // 選択するのは A 側の顔だけ（素材座標 cx=0.95 → 画面上は 0.25）。
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.95, cy: 0.5),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceA),
            // B 側は非選択（画面上は 0.8）。「全選択バイパス」に落ちないためにも要る。
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.5, cy: 0.5),
                       thumbnail: UIImage(), isSelected: false, sourceID: sourceB)
        ]

        // 画面には 2 顔（A:0.25 / B:0.8）が映っている。
        let shown = model.displayFaces(at: 1.85)
        XCTAssertEqual(shown.count, 2)

        let selected = model.selectedLandmarks(at: 1.85)
        XCTAssertEqual(selected.count, 1, "選択していない側の顔にもモザイクが乗っている")
        let centroid = Double(selected[0].points[0].x + selected[0].points[1].x) / 2
        // 旧実装（合成座標 0.25 と素材座標 0.95 を直接比較）では
        // |0.95−0.25|=0.70 で選択顔が落ち、|0.95−0.8|=0.15 で**非選択の顔**が通っていた。
        XCTAssertEqual(centroid, 0.25, accuracy: 0.02,
                       "選択した顔ではなく、もう片方の顔にモザイクが乗っている")
    }

    /// レターボックス（解像度混在）でも、選択顔の照合が素材座標のまま行われ、
    /// 返る顔だけが合成座標へ写ること（写像の順序の退行ガード）。
    func test_selectedLandmarksAppliesLayoutAfterMatching() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        model.setTimelineForTesting(TimelineState(
            clips: [clip], applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [])))
        // 240x320 を 320x240 のフレームへフィットした配置（x=0.21875 / 幅 0.5625）。
        let placement = AspectFit.placement(of: CGSize(width: 240, height: 320),
                                            in: CGSize(width: 320, height: 240))
        model.renderLayout = TimelineRenderLayout(placements: [clip.id: placement])
        for time in stride(from: 0.0, through: 1.0, by: 0.1) {
            model.cacheStore.store([fakeFace(cx: 0.10, cy: 0.5), fakeFace(cx: 0.90, cy: 0.5)],
                                   sourceID: sourceA, time: time)
        }
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.10, cy: 0.5),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceA),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.90, cy: 0.5),
                       thumbnail: UIImage(), isSelected: false, sourceID: sourceA)
        ]
        let selected = model.selectedLandmarks(at: 0.5)
        XCTAssertEqual(selected.count, 1, "非選択の顔まで通っている")
        let centroid = Double(selected[0].points[0].x + selected[0].points[1].x) / 2
        // 素材 0.10 → 合成 0.21875 + 0.10*0.5625 = 0.275。
        XCTAssertEqual(centroid, 0.275, accuracy: 1e-6,
                       "選択顔がレターボックス配置へ写っていない")
    }

    // MARK: - M-1: 矩形サーチはレターボックスの逆写像を通る

    /// プレビュー（合成フレーム）に描いた矩形が、クリップごとに**素材フレーム基準**へ
    /// 戻ってから走査されること。先頭クリップ（単位配置）では矩形が変わらないこと。
    func test_scanSegmentsMapsSearchRectBackToSourceFrame() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 2)
        model.setTimelineForTesting(TimelineState(clips: [clipA, clipB]))
        // scanSegments は asset の中身を読まない（存在確認のみ）。
        let stub = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        model.sources = [sourceA: stub, sourceB: stub]
        // 先頭クリップは全面、後続クリップはレターボックス（x=0.21875 / 幅 0.5625）。
        let placement = AspectFit.placement(of: CGSize(width: 240, height: 320),
                                            in: CGSize(width: 320, height: 240))
        model.renderLayout = TimelineRenderLayout(placements: [
            clipA.id: CGRect(x: 0, y: 0, width: 1, height: 1),
            clipB.id: placement
        ])

        // 合成 x=0.275 幅 0.05*0.5625 → 素材 x=0.10 幅 0.05（レビューの実測表の逆向き）。
        let drawn = CGRect(x: 0.275, y: 0.2, width: 0.05 * 0.5625, height: 0.3)
        let segments = model.scanSegments(searchRect: drawn)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].rect, drawn, "先頭クリップ（単位配置）で矩形が変化した")
        XCTAssertEqual(Double(segments[1].rect.minX), 0.10, accuracy: 1e-9,
                       "レターボックスの逆写像が掛かっていない")
        XCTAssertEqual(Double(segments[1].rect.width), 0.05, accuracy: 1e-9)
        XCTAssertEqual(segments[1].rect.minY, drawn.minY, accuracy: 1e-9, "縦は全面なので不変")

        // 黒帯の中だけを指した矩形: 先頭クリップだけが残る。
        let inBar = model.scanSegments(searchRect: CGRect(x: 0.02, y: 0, width: 0.1, height: 1))
        XCTAssertEqual(inBar.count, 1, "対応領域の無いクリップが走査対象に残っている")
        XCTAssertEqual(inBar[0].sourceID, sourceA)
    }

}

/// S12: 写真クリップの尺（capacity 方式）とクリップ音量のモデル層テスト。
///
/// - 写真素材は `PhotoClipEncoder.clipCapacitySeconds` の headroom 付きでエンコードし、
///   クリップの `sourceEnd` だけ `defaultClipSeconds` にする。トリムは `sourceEnd` を
///   素材尺までしか伸ばせないため、この方式でないと「3 秒より長くできない」ままになる。
/// - `setClipVolume` は `applyTimelineEdit` 経由なので undo/redo にそのまま載る。
@MainActor
final class PhotoClipDurationAndVolumeTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // **「顔モザイクをかける」までを再現する。** 動画モードの既定は OFF
        // （開いただけでは掛からない）で、ライブ検出も描画も `faceMosaicOn` を見ている。
        // 既定そのものを検証したいテストは `MosaicReapplyFlowTests` にある。
        model.faceMosaicOn = true
        return model
    }

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 追加直後は既定尺（3s）でも、**トリムで既定尺より長く** capacity まで伸ばせること。
    /// capacity を超える指定は素材尺へクランプされること（trimClip の既存契約）。
    func test_appendedPhotoClip_canBeTrimmedLongerThanDefault() async throws {
        let model = makeModel()
        model.setClipsForTesting([TimelineClip(sourceID: model.currentSourceID,
                                               sourceStart: 0, sourceEnd: 5)])
        model.commitEdit()
        // **「モザイクを掛けている編集」にしてから素材を足す。** 新規は区間 0 本
        // （レイヤーを出さない）で始まり、素材追加は既に区間がある編集にしか
        // 区間を足さないので、これが無いと追加した写真にも区間が付かない。
        model.ensureApplyRangesExist()

        await model.appendPhotoClip(image: solidImage(width: 320, height: 240))
        await model.awaitPendingTimelineRebuild()

        XCTAssertNil(model.errorMessage)
        let photo = try XCTUnwrap(model.clips.last)
        XCTAssertEqual(photo.sourceEnd, PhotoClipEncoder.defaultClipSeconds, accuracy: 0.1,
                       "追加直後のクリップ尺が既定尺でない")
        let materialSeconds = try XCTUnwrap(model.sourceDuration(forClipID: photo.id))
        XCTAssertGreaterThanOrEqual(materialSeconds, PhotoClipEncoder.clipCapacitySeconds - 0.2,
                                    "素材が headroom 付きでエンコードされていない（伸ばせない）")

        // 既定尺より長い範囲へトリム（これが 3 秒の壁の解消そのもの）。
        let longer = PhotoClipEncoder.defaultClipSeconds + 5
        model.trimClip(id: photo.id, sourceStart: 0, sourceEnd: longer)
        let trimmed = try XCTUnwrap(model.clips.last)
        XCTAssertEqual(trimmed.sourceEnd, longer, accuracy: 1e-6,
                       "写真クリップを既定尺より長くできない")
        XCTAssertTrue(model.timeline.validate())
        // **`validate()` だけ見ても足りない**（区間が孤児化してもクリップは健全なため）。
        // 伸ばした先までゲートが ON かを実測で固定する。
        assertPhotoClipFullyMosaicked(model, clipID: photo.id, label: "右端を伸ばした後")

        // 左端トリム（伸ばした後に左を詰める）でも区間が孤児化しないこと。
        // 写真の区間は [0, sourceEnd) 固定なので、`sourceStart` が動くと追従しない限り交差が切れる。
        model.trimClip(id: photo.id, sourceStart: 4, sourceEnd: longer)
        XCTAssertTrue(model.timeline.validate())
        assertPhotoClipFullyMosaicked(model, clipID: photo.id, label: "左端を詰めた後")

        // capacity を超える指定は素材尺でクランプ（実体のない区間を作らない）。
        model.trimClip(id: photo.id, sourceStart: 0, sourceEnd: 999)
        let clamped = try XCTUnwrap(model.clips.last)
        XCTAssertEqual(clamped.sourceEnd, materialSeconds, accuracy: 1e-6,
                       "素材尺を超える範囲が素通りしている")
    }

    /// 写真クリップを分割しても、そのクリップの合成区間が全部 ON のままであること。
    ///
    /// 写真の素材時刻は常に 0 へ丸められるので、区間を分割点で割ると後半が
    /// 永久にヒットしない（帯は 2 本出たままモザイクだけ消える = 不変条件 I1 違反）。
    func test_splitPhotoClip_keepsMosaicActiveOnBothHalves() async throws {
        let model = makeModel()
        model.setClipsForTesting([TimelineClip(sourceID: model.currentSourceID,
                                               sourceStart: 0, sourceEnd: 5)])
        model.commitEdit()
        // 上と同じ理由で、先に「掛けている編集」にしておく。
        model.ensureApplyRangesExist()
        await model.appendPhotoClip(image: solidImage(width: 320, height: 240))
        await model.awaitPendingTimelineRebuild()

        let photo = try XCTUnwrap(model.clips.last)
        let layouts = TimelineBandLayout.clipLayouts(mapping: model.mapping)
        let span = try XCTUnwrap(layouts.first { $0.clipID == photo.id })
        let splitTime = (span.bandStart + span.bandEnd) / 2
        model.playbackPosition = splitTime / model.videoDuration
        XCTAssertTrue(model.timeline.canSplit(clipID: photo.id, atDisplayTime: splitTime))
        model.splitClip(id: photo.id)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.clips.count, 3, "写真クリップが分割されていない")
        XCTAssertTrue(model.timeline.validate())
        for clip in model.clips.dropFirst() {
            assertPhotoClipFullyMosaicked(model, clipID: clip.id, label: "分割後")
        }
    }

    /// 指定クリップの合成区間を等間隔にサンプルし、全点でゲートが ON かつ帯が 1 本あること。
    private func assertPhotoClipFullyMosaicked(_ model: MosaicEditorModel,
                                               clipID: UUID, label: String,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let layouts = TimelineBandLayout.clipLayouts(mapping: model.mapping)
        guard let layout = layouts.first(where: { $0.clipID == clipID }) else {
            XCTFail("\(label): クリップが見つからない", file: file, line: line)
            return
        }
        let bands = TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges,
                                                  mapping: model.mapping,
                                                  photoSourceIDs: model.timeline.photoSourceIDs)
            .filter { $0.anchorClipID == clipID }
        XCTAssertEqual(bands.count, 1, "\(label): 帯が 1 本でない", file: file, line: line)
        var off = 0
        let samples = 40
        for index in 0..<samples {
            let t = layout.bandStart
                + (layout.bandEnd - layout.bandStart) * Double(index) / Double(samples)
            if !model.isMosaicActive(atComposition: t) { off += 1 }
        }
        XCTAssertEqual(off, 0, "\(label): 写真クリップ内で OFF の時刻が \(off)/\(samples) 点ある",
                       file: file, line: line)
    }

    /// 高ディテールの画像（圧縮の worst case。単色だと尺による差が出ない）。
    private func noisyImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    UIColor(red: CGFloat(Int(x) * 7 % 255) / 255,
                            green: CGFloat(Int(y) * 13 % 255) / 255,
                            blue: CGFloat(Int(x) * Int(y) % 255) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    /// エンコード済み mp4 の（同期サンプル数, 総サンプル数）。圧縮サンプルのまま読む。
    private func sampleCounts(of url: URL) async throws -> (sync: Int, total: Int) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var sync = 0
        var total = 0
        while let sample = output.copyNextSampleBuffer() {
            total += 1
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !notSync { sync += 1 }
        }
        return (sync, total)
    }

    /// 長 GOP（`AVVideoMaxKeyFrameIntervalKey`）が効いていること。
    ///
    /// 静止画の連続なので I フレームを絞れば以降は P フレームだけになり、ファイルサイズが下がる。
    /// 写真素材は素材時刻 0 以外へシークされない（`TimelineState.clampedSourceTime`）ため
    /// 長 GOP のデメリットが無い。
    ///
    /// **「I フレームちょうど 1 枚」は要求できない**: このキーは上限のヒントであり、
    /// エンコーダは自身の判断で IDR を追加してよい（Simulator の実測は 4s / 64 サンプル中
    /// 同期サンプル 5 枚）。ここでは「毎秒 IDR が入るような短い GOP になっていない」ことだけを見る。
    func test_photoClipEncode_usesLongGOP() async throws {
        let encoded = try await PhotoClipEncoder().encode(image: noisyImage(width: 720, height: 1280),
                                                          seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        let counts = try await sampleCounts(of: encoded.url)
        print("[PHOTOCLIP] keyframes=\(counts.sync)/\(counts.total)")
        XCTAssertGreaterThanOrEqual(counts.total, 60, "15fps × 4s 分のサンプルが書けていない")
        XCTAssertLessThanOrEqual(counts.sync, max(1, counts.total / 8),
                                 "I フレームが多すぎる（長 GOP 設定が効いていない）")
    }

    /// capacity 尺のエンコードの実測（所要時間・ファイルサイズ）。
    ///
    /// 複数選択の追加は 1 枚ずつ直列 await されるので、1 枚あたりのコストが枚数倍で効く。
    /// **capacity を上げるときは必ずこの数字を見ること。** サイズは長 GOP でも尺に対して
    /// 横ばいにはならない（同一フレームでも P フレームにビットが乗る）ため、
    /// ここでは「比例していないこと」ではなく絶対値の上限を見る。
    ///
    /// **所要時間は「3 秒版との比」で見る**（絶対秒は実行環境の負荷に丸ごと引きずられる）。
    /// 同じ実行の中で採った 2 点なので、マシンが遅ければ両方が同じだけ遅くなり比は保たれる。
    /// 絶対秒の上限も残すが、これは「桁で遅くなった」ときだけ鳴る**大雑把な安全弁**に留める。
    func test_photoClipEncode_capacityCostIsAcceptable() async throws {
        let image = noisyImage(width: 1080, height: 1920)

        let startDefault = Date()
        let short = try await PhotoClipEncoder().encode(image: image,
                                                        seconds: PhotoClipEncoder.defaultClipSeconds)
        let shortElapsed = Date().timeIntervalSince(startDefault)
        defer { try? FileManager.default.removeItem(at: short.url) }

        let startCapacity = Date()
        let long = try await PhotoClipEncoder().encode(image: image,
                                                       seconds: PhotoClipEncoder.clipCapacitySeconds)
        let longElapsed = Date().timeIntervalSince(startCapacity)
        defer { try? FileManager.default.removeItem(at: long.url) }

        let shortBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: short.url.path)[.size] as? NSNumber).intValue
        let longBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: long.url.path)[.size] as? NSNumber).intValue
        print("[PHOTOCLIP] \(PhotoClipEncoder.defaultClipSeconds)s: \(shortElapsed)s / \(shortBytes) bytes")
        print("[PHOTOCLIP] \(PhotoClipEncoder.clipCapacitySeconds)s: \(longElapsed)s / \(longBytes) bytes")

        XCTAssertEqual(long.duration, PhotoClipEncoder.clipCapacitySeconds, accuracy: 0.1)
        XCTAssertGreaterThan(shortBytes, 0)
        // 尺は 3s → 15s の 5 倍。エンコードは尺に対しておおむね線形（固定コストがあるぶん
        // 比は 5 未満に落ち着く）なので、**線形の 2 倍**を超えたら構造的な悪化とみなす。
        //
        // 実測（Simulator iPhone 17e）: 無負荷（load avg 約 3）で 4.31 倍（0.950s / 0.220s）×2、
        // 並行ビルド下（load avg 約 9.5）で 4.45 倍（2.687s / 0.604s）・4.46 倍（2.602s / 0.584s）・
        // 5.92 倍（3.032s / 0.512s）、6.90 倍（1.777s / 0.258s。全件実行の中で暖まった状態）。
        // **比が跳ねるのは 3s 側**（固定コストの割合が大きく 0.26〜0.60s とばらつく）ため、
        // 上限は実測最大 6.90 の 1.45 倍にあたる 10.0 まで見る。
        // capacity を 60s へ上げれば比は 19 前後になりここで落ちる。**30s 程度の小さな引き上げは
        // この比では捕まえきれないので、変更時は上の print を必ず目視すること。**
        XCTAssertGreaterThan(shortElapsed, 0)
        XCTAssertLessThan(longElapsed / shortElapsed, 10.0,
                          "capacity 尺のエンコードが尺に対して線形以上に重い（capacity を下げること）")
        // 絶対秒の安全弁。旧版は 4.0s だったが、これは**ホストが空いているときの実測 0.85s**
        // （無負荷での再実測も 0.95s で一致）を基準にした値で、並行ビルド下の実測 2.6〜3.0s に
        // 対しては余裕が 1.3 倍しか無く、負荷次第で落ちていた（過去に 4.6s の失敗報告あり）。
        // 負荷時実測の約 3 倍を上限に置く。**エンコード自体の速さはこの値ではなく比で見ること。**
        XCTAssertLessThan(longElapsed, 8.0, "capacity 尺のエンコードが桁で遅い（環境かエンコーダ設定を疑う）")
        XCTAssertLessThan(longBytes, 8 * 1_048_576, "capacity 尺のファイルが大きすぎる")
    }

    /// setClipVolume が状態へ反映され、undo/redo で戻ること（合成尺は変わらない）。
    func test_setClipVolume_isUndoable_andKeepsDuration() {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        model.commitEdit()   // 履歴基準を確立
        XCTAssertFalse(model.canUndo)

        model.setClipVolume(id: clip.id, volume: 0.25)
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0.25, accuracy: 1e-6)
        XCTAssertEqual(model.videoDuration, 10.0, accuracy: 1e-9, "音量で合成尺が変わった")
        XCTAssertTrue(model.canUndo, "音量変更が履歴に積まれていない")

        model.undo()
        XCTAssertEqual(model.clips[0].originalAudioVolume, 1.0, accuracy: 1e-6,
                       "undo で音量が戻らない")
        model.redo()
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0.25, accuracy: 1e-6,
                       "redo で音量が復元されない")

        // 同値の再設定は世代・履歴を進めない（settingVolume の self 契約が通っていること）。
        let generation = model.timelineGeneration
        model.setClipVolume(id: clip.id, volume: 0.25)
        XCTAssertEqual(model.timelineGeneration, generation,
                       "変化の無い音量設定で世代トークンが進んでいる")
    }

    // MARK: - 一時ファイルの掃除（配線）

    /// `TempMediaJanitor.sweep` が「期限切れの中間ファイルだけ」を消すこと。
    ///
    /// 判定そのものは `TempFileSweeper`（コア層）のテストが担うので、ここは配線
    /// （ディレクトリ列挙・更新日時の読み取り・削除対象の取り違え）を見る。
    /// **`source-*` / `thumb-*` / 索引 JSON を消したら下書きが壊れる**ので、
    /// それらが残ることを明示的に固定する。
    func test_tempMediaJanitor_deletesOnlyAgedIntermediateFiles() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent("janitor-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let now = Date()
        func write(_ name: String, ageHours: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-ageHours * 3600)],
                                          ofItemAtPath: url.path)
            return url
        }
        let deletable = [try write("picked-old.mov", ageHours: 48),
                         try write("photoclip-old.mp4", ageHours: 48),
                         try write("mosaic-old.mp4", ageHours: 48)]
        let kept = [try write("picked-fresh.mov", ageHours: 1),      // 編集中のセッションの実体
                    try write("source-old.mov", ageHours: 48),       // 下書きの素材本体
                    try write("thumb-old.jpg", ageHours: 48),
                    try write("drafts.json", ageHours: 48)]

        let removed = TempMediaJanitor.sweep(directory: dir, now: now)

        XCTAssertEqual(removed, deletable.count)
        for url in deletable {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path),
                           "期限切れの中間ファイルが残った: \(url.lastPathComponent)")
        }
        for url in kept {
            XCTAssertTrue(fileManager.fileExists(atPath: url.path),
                          "消してはならないファイルを削除した: \(url.lastPathComponent)")
        }
    }
}

/// S12(UI): クリップ音量シート（`TimelineVolumeSheet`）の配線。
///
/// View そのものは描画を伴うので、テストで固定するのは
/// 1. 活性判定（`TimelineVolumeAvailability`。View から切り出した純ロジック）
/// 2. シートが受け取るコールバック経由の値変更が undo/redo に載ること
/// の 2 点だけ。スライダーの見た目・ミュートボタンの表示は実機での目視に委ねる。
@MainActor
final class TimelineVolumeSheetWiringTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // **「顔モザイクをかける」までを再現する。** 動画モードの既定は OFF
        // （開いただけでは掛からない）で、ライブ検出も描画も `faceMosaicOn` を見ている。
        // 既定そのものを検証したいテストは `MosaicReapplyFlowTests` にある。
        model.faceMosaicOn = true
        return model
    }

    /// 写真クリップでは音量メニューが活性にならないこと（音声トラックが無く、
    /// `AudioMixFactory` が `originalAudioVolume` を無視するため）。
    func test_volumeAvailability_excludesPhotoClips() {
        let videoSourceID = UUID()
        let photoSourceID = UUID()
        let unregisteredSourceID = UUID()
        let videoClip = TimelineClip(sourceID: videoSourceID, sourceStart: 0, sourceEnd: 4)
        let photoClip = TimelineClip(sourceID: photoSourceID, sourceStart: 0, sourceEnd: 3)
        let legacyClip = TimelineClip(sourceID: unregisteredSourceID, sourceStart: 0, sourceEnd: 2)
        let timeline = TimelineState(
            clips: [videoClip, photoClip, legacyClip],
            sources: [videoSourceID: TimelineSource(id: videoSourceID, kind: .video),
                      photoSourceID: TimelineSource(id: photoSourceID, kind: .photo)])

        XCTAssertTrue(TimelineVolumeAvailability.isEnabled(timeline: timeline, clipID: videoClip.id),
                      "動画クリップで音量メニューが活性にならない")
        XCTAssertFalse(TimelineVolumeAvailability.isEnabled(timeline: timeline, clipID: photoClip.id),
                       "写真クリップで音量メニューが活性になっている（設定しても無視される）")
        XCTAssertTrue(TimelineVolumeAvailability.isEnabled(timeline: timeline, clipID: legacyClip.id),
                      "素材メタ未登録（= 動画扱い）のクリップが除外されている")
        XCTAssertFalse(TimelineVolumeAvailability.isEnabled(timeline: timeline, clipID: nil),
                       "未選択で音量メニューが活性になっている")
        XCTAssertFalse(TimelineVolumeAvailability.isEnabled(timeline: timeline, clipID: UUID()),
                       "存在しないクリップIDで音量メニューが活性になっている")
    }

    /// **消音の見た目は、音量ボタンが実際に指している対象を見て決めること。**
    ///
    /// クリップと BGM は同じ音量ボタンを共有する（ユーザー決定 2026-08-02）。
    /// 対象の決定を `target(timeline:selection:)` へ通さずに書くと、
    /// 「クリップを選んでいるのに BGM の消音状態でアイコンが変わる」取り違えが起きる。
    func test_isMuted_音量ボタンが指している対象の消音だけを見る() {
        let videoSourceID = UUID()
        let audioSourceID = UUID()
        var loudClip = TimelineClip(sourceID: videoSourceID, sourceStart: 0, sourceEnd: 4)
        loudClip.originalAudioVolume = 1
        var mutedClip = TimelineClip(sourceID: videoSourceID, sourceStart: 0, sourceEnd: 4)
        mutedClip.originalAudioVolume = 0
        let mutedAudio = AudioItem(sourceID: audioSourceID, sourceStart: 0, sourceEnd: 3,
                                   compositionStart: 0, volume: 0)
        let timeline = TimelineState(
            clips: [loudClip, mutedClip], audioItems: [mutedAudio],
            sources: [videoSourceID: TimelineSource(id: videoSourceID, kind: .video),
                      audioSourceID: TimelineSource(id: audioSourceID, kind: .audio)])

        func selecting(clip id: UUID) -> TimelineSelection {
            var selection = TimelineSelection()
            selection.selectClip(id)
            return selection
        }

        XCTAssertFalse(
            TimelineVolumeAvailability.isMuted(timeline: timeline, selection: selecting(clip: loudClip.id)),
            "消音していないクリップが消音として出ている")
        XCTAssertTrue(
            TimelineVolumeAvailability.isMuted(timeline: timeline, selection: selecting(clip: mutedClip.id)),
            "消音したクリップが消音として出ていない")
        // **BGM が消音でも、クリップを選んでいるならクリップ側を見ること。**
        // （BGM は `volume: 0` で登録してあるので、対象の取り違えがあればここが落ちる）
        XCTAssertFalse(
            TimelineVolumeAvailability.isMuted(timeline: timeline, selection: selecting(clip: loudClip.id)),
            "BGM の消音状態がクリップ選択時に漏れている")
        // BGM を選んでいるときは BGM 側を見る。
        var audioSelection = TimelineSelection()
        audioSelection.selectLayer(TimelineLayerSelection(kind: .audio, id: mutedAudio.id))
        XCTAssertTrue(
            TimelineVolumeAvailability.isMuted(timeline: timeline, selection: audioSelection),
            "消音した BGM が消音として出ていない")
        // 何も選んでいなければボタン自体が非活性なので消音の見た目にしない。
        XCTAssertFalse(
            TimelineVolumeAvailability.isMuted(timeline: timeline, selection: TimelineSelection()),
            "未選択で消音の見た目になっている")
    }

    /// シートのコールバック（`TimelineVolumeSheet.onApply`）を通した値変更が
    /// undo で戻り、redo で復元されること。ミュート（0）も同じ経路に載ること。
    func test_volumeSheetCallback_appliesAndIsUndoable() throws {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 8)
        model.setClipsForTesting([clip])
        model.commitEdit()   // 履歴基準を確立
        XCTAssertFalse(model.canUndo)

        // `TimelineEditSheetsModifier` が渡しているのと同じクロージャを組み立てる。
        let sheet = TimelineVolumeSheet(initialVolume: clip.originalAudioVolume) { volume in
            model.setClipVolume(id: clip.id, volume: volume)
        }

        sheet.onApply(0.4)
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0.4, accuracy: 1e-6,
                       "シート経由の音量がモデルへ反映されていない")

        // ミュート（0）。範囲下端も同じ経路に載る。
        sheet.onApply(0)
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0, accuracy: 1e-6,
                       "ミュートがモデルへ反映されていない")
        XCTAssertEqual(model.videoDuration, 8.0, accuracy: 1e-9, "音量で合成尺が変わった")

        model.undo()
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0.4, accuracy: 1e-6,
                       "undo でミュート前の音量に戻らない")
        model.undo()
        XCTAssertEqual(model.clips[0].originalAudioVolume, 1.0, accuracy: 1e-6,
                       "undo で初期音量に戻らない")
        model.redo()
        XCTAssertEqual(model.clips[0].originalAudioVolume, 0.4, accuracy: 1e-6,
                       "redo で音量が復元されない")

        // 範囲外は `TimelineClip.clampedVolume` で切られる（UI から壊れた値を入れられない）。
        sheet.onApply(1.8)
        XCTAssertEqual(model.clips[0].originalAudioVolume, 1.0, accuracy: 1e-6,
                       "範囲外の音量が素通りしている")
    }
}

// MARK: - BGM の UI 配線と下書き（E2-3b）

/// BGM を段の仕組みへ載せたぶんの契約。
///
/// **下書きの穴の回帰が主目的**。`draftSources` / `sessionReferencedSourceIDs` は
/// クリップだけを走査していたので、BGM の音源が下書きへコピーされず、
/// 再開したときに帯だけ残って音が消えていた。
@MainActor
final class BackgroundAudioWiringTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.faceMosaicOn = true
        return model
    }

    /// 動画 1 本 + BGM 1 曲を積んだ状態を作る（音源は AVURLAsset で登録する）。
    private func makeModelWithAudio() throws -> (MosaicEditorModel, UUID, URL) {
        let model = makeModel()
        let videoSource = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 10)])

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0x00]).write(to: audioURL)
        let audioSource = UUID()
        model.registerAudioSource(id: audioSource, asset: AVURLAsset(url: audioURL))
        model.addAudioItem(sourceID: audioSource, sourceDuration: 4, atCompositionTime: 1)
        return (model, audioSource, audioURL)
    }

    /// **下書きへ BGM の音源も持っていく。**
    ///
    /// 漏らすと、下書きを再開したとき帯だけ残って音源が `sources` に無く、
    /// BGM が黙って鳴らない（`rebuildComposition` が音源未登録の曲を落とす）。
    func test_draftSources_includeBackgroundAudioSource() throws {
        let (model, audioSource, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        XCTAssertEqual(model.timeline.audioItems.count, 1, "前提が崩れている（BGM が入っていない）")
        XCTAssertTrue(model.draftSources.contains { $0.id == audioSource },
                      "BGM の音源が下書き保存対象に出てこない（再開すると音が消える）")
    }

    /// **GC 保護にも BGM の音源を含める。**
    ///
    /// 含めないと「BGM を消して再保存 → undo で戻す」で音源の実体だけが消え、
    /// 帯はあるのに鳴らない状態になる。
    func test_sessionReferencedSourceIDs_includeBackgroundAudioAcrossUndo() throws {
        let (model, audioSource, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        model.commitEdit()

        let itemID = try XCTUnwrap(model.timeline.audioItems.first?.id)
        model.removeAudioItem(id: itemID)
        model.commitEdit()
        XCTAssertTrue(model.timeline.audioItems.isEmpty, "前提が崩れている（BGM が消えていない）")

        XCTAssertTrue(model.sessionReferencedSourceIDs.contains(audioSource),
                      "undo で戻せる BGM の音源が GC 保護から漏れている")
    }

    /// BGM の帯は**合成尺で切った実効**だけを見せる。
    func test_audioSpans_showOnlyEffectiveItems() throws {
        let (model, _, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let spans = TimelineBandLayout.audioSpans(items: model.timeline.audioItems,
                                                   totalDuration: model.mapping.totalDuration)
        XCTAssertEqual(spans.count, 1)
        XCTAssertNil(spans[0].anchorClipID, "BGM の帯がクリップに紐づいている")
        XCTAssertEqual(spans[0].kind, .audio)
    }

    /// 音量 UI の対象は**選択しているもので切り替わる**。
    ///
    /// 活性判定（押せるか）と実行（どちらの音量を変えるか）が同じ純関数を通ることの契約。
    /// 別々に書くと「押せるのに何も起きない」が作れる。
    func test_volumeTarget_switchesWithSelection() throws {
        let (model, _, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let clipID = try XCTUnwrap(model.timeline.clips.first?.id)
        let itemID = try XCTUnwrap(model.timeline.audioItems.first?.id)

        model.timelineSelection.selectClip(clipID)
        XCTAssertEqual(TimelineVolumeAvailability.target(timeline: model.timeline,
                                                        selection: model.timelineSelection),
                       .clip(clipID), "クリップを選んでいるのに BGM の音量が出る")

        model.timelineSelection.selectLayer(TimelineLayerSelection(kind: .audio, id: itemID))
        XCTAssertEqual(TimelineVolumeAvailability.target(timeline: model.timeline,
                                                        selection: model.timelineSelection),
                       .audio(itemID), "BGM を選んでいるのにクリップの音量が出る")

        model.timelineSelection.clear()
        XCTAssertNil(TimelineVolumeAvailability.target(timeline: model.timeline,
                                                      selection: model.timelineSelection),
                     "何も選んでいないのに音量 UI が出る")
    }

    /// 消えた BGM を選んだままだと音量 UI を出さない（空のシートを開かない）。
    func test_volumeTarget_afterRemovingAudio_isNil() throws {
        let (model, _, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let itemID = try XCTUnwrap(model.timeline.audioItems.first?.id)
        model.timelineSelection.selectLayer(TimelineLayerSelection(kind: .audio, id: itemID))
        model.removeAudioItem(id: itemID)

        XCTAssertNil(TimelineVolumeAvailability.target(timeline: model.timeline,
                                                      selection: model.timelineSelection),
                     "消えた BGM を対象にしたまま音量 UI が開く")
    }


    /// **BGM を選んだ状態で削除ボタンが効く**（種の取り違えの回帰）。
    ///
    /// かつては帯をタップして選ぶと内部で `.mosaic` としてタグ付けされ、削除が
    /// 「存在しない適用区間の id」を消しにいって no-op になっていた。
    /// ここではモデル層で「選択の種が正しければ正しい API へ届く」ことを固定する
    /// （UI の Binding そのものは `TimelineSelection.layerID(of:)` の型が守る）。
    func test_selectedAudioLayer_resolvesToAudioNotMosaic() throws {
        let (model, _, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let itemID = try XCTUnwrap(model.timeline.audioItems.first?.id)
        model.timelineSelection.selectLayer(TimelineLayerSelection(kind: .audio, id: itemID))

        XCTAssertEqual(model.timelineSelection.layerID(of: .audio), itemID)
        XCTAssertNil(model.timelineSelection.layerID(of: .mosaic),
                     "BGM を選んでいるのにモザイク区間として解決されている"
                     + "（削除も音量も効かなくなる）")

        // 削除が実際に BGM へ届く。
        model.removeAudioItem(id: itemID)
        XCTAssertTrue(model.timeline.audioItems.isEmpty, "選んだ BGM が削除されない")
    }

    /// BGM の編集は undo で戻る（`applyTimelineEdit` を通していることの実測）。
    func test_audioEdits_areUndoable() throws {
        let (model, _, audioURL) = try makeModelWithAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        model.commitEdit()
        let itemID = try XCTUnwrap(model.timeline.audioItems.first?.id)

        model.setAudioVolume(id: itemID, volume: 0.25)
        model.commitEdit()
        XCTAssertEqual(model.timeline.audioItems[0].volume, 0.25, accuracy: 1e-6)

        model.undo()
        XCTAssertEqual(model.timeline.audioItems[0].volume, 1.0, accuracy: 1e-6,
                       "BGM の音量が undo で戻らない")
        model.redo()
        XCTAssertEqual(model.timeline.audioItems[0].volume, 0.25, accuracy: 1e-6,
                       "BGM の音量が redo で戻らない")
    }
}
