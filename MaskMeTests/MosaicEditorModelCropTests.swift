import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// クロップ編集の下書きライフサイクル（S4）を固定する。
///
/// コア層（`CropRect` / `CropHandleMath` / `CropAspectLock` / `PreviewInteractionPolicy`）は
/// S1〜S3 で固定済み（`Tests/MosaicCoreTests/CropHandleMathTests.swift` 等）。
/// ここはアプリ層の配線——`beginCropEditing` / `updateCropDraft` / `cancelCropEditing` /
/// `commitCropEditing` が undo 履歴・composition 再構築・検出キャッシュと
/// どう関係するか——だけを見る。
@MainActor
final class MosaicEditorModelCropTests: XCTestCase {
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

    // MARK: - 実素材（合成寸法・レイアウトの検証に必要）

    private func makeTestVideo(seconds: Double, width: Int = 320, height: Int = 240) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
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
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func waitUntilLoaded(_ model: MosaicEditorModel, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoading {
            if Date() > deadline {
                XCTFail("動画の読み込みが \(timeout)s 以内に完了しない")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 1. 編集中は合成が全面で組まれる

    /// **合成の寸法（`outputRenderSize`）とレイアウトの配置（`renderLayout`）の
    /// 両方を見る。** 片方だけだと「合成は非クロップ寸法に戻ったのに、モザイクの
    /// 写像だけクロップ済みのまま」という食い違いを見逃す。
    func test_クロップ編集を始めるとプレビュー合成が全面で組まれる() async throws {
        let url = try await makeTestVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel()
        model.load(videoURL: url)
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()

        let clipID = try XCTUnwrap(model.clips.first).id
        let fullRenderSize = try XCTUnwrap(model.outputRenderSize, "前提が崩れている: 読み込み直後に出力寸法が無い")
        let fullPlacement = model.renderLayout.placement(for: clipID)

        // クロップを確定し、実際に効いていることを前提として確かめる。
        let crop = CropRect(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        model.setCrop(crop)
        await model.awaitPendingTimelineRebuild()
        let croppedRenderSize = try XCTUnwrap(model.outputRenderSize)
        XCTAssertNotEqual(croppedRenderSize, fullRenderSize, "前提が崩れている: クロップが合成へ効いていない")

        // クロップ編集を始めると、合成は crop = .full（非クロップ寸法）へ組み直される。
        model.beginCropEditing()
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.outputRenderSize, fullRenderSize,
                      "クロップ編集中の合成寸法が非クロップ寸法と一致しない")
        let editingPlacement = model.renderLayout.placement(for: clipID)
        XCTAssertEqual(editingPlacement.minX, fullPlacement.minX, accuracy: 1e-9)
        XCTAssertEqual(editingPlacement.minY, fullPlacement.minY, accuracy: 1e-9)
        XCTAssertEqual(editingPlacement.width, fullPlacement.width, accuracy: 1e-9)
        XCTAssertEqual(editingPlacement.height, fullPlacement.height, accuracy: 1e-9)
    }

    // MARK: - 2. 取消

    func test_取消で編集前のクロップへ戻り履歴が増えない() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let original = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        model.setCrop(original)
        XCTAssertEqual(model.timeline.crop, original, "前提が崩れている: クロップを設定できていない")
        let undoCountBefore = model.undoStack.count

        model.beginCropEditing()
        XCTAssertEqual(model.timeline.crop, .full,
                      "前提が崩れている: 編集開始でプレビュー合成が全面になっていない")
        model.updateCropDraft(CropRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        model.cancelCropEditing()

        XCTAssertEqual(model.timeline.crop, original, "取消で編集前のクロップへ戻っていない")
        XCTAssertNil(model.cropDraft, "取消後も下書きが残っている")
        XCTAssertEqual(model.undoStack.count, undoCountBefore, "取消で undo 履歴が増えている")
    }

    // MARK: - 3. 確定

    /// **確定直後に `timeline.crop == 新しい値` を先に確かめる。** これをしないと
    /// 「確定時に何もしない」実装でも次の undo アサーションだけは（たまたま）緑になり得る。
    func test_確定はundo1回で編集前へ戻る() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let before = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        model.setCrop(before)
        XCTAssertEqual(model.timeline.crop, before, "前提が崩れている")

        let after = CropRect(rect: CGRect(x: 0.2, y: 0, width: 0.4, height: 1))
        model.beginCropEditing()
        model.updateCropDraft(after)
        model.commitCropEditing()

        XCTAssertEqual(model.timeline.crop, after, "確定でクロップが新しい値になっていない")

        model.undo()

        XCTAssertEqual(model.timeline.crop, before, "undo 1 回で編集前のクロップへ戻らない")
    }

    /// **`commitCropEditing` が「一旦 `cropBeforeEditing` へ戻してから `setCrop`」する
    /// ことの唯一の番人。**
    ///
    /// 親の変異検証で分かったこと: revert を外しても `test_確定はundo1回で編集前へ戻る`
    /// は緑のまま通る（`beginCropEditing` が履歴に積まないので、undo の戻り先は
    /// どちらの実装でも編集前の値になる）。差が出るのは**値を変えずに確定した**とき。
    ///
    /// revert があると `setCrop` の時点で `timeline.crop == draft` なので
    /// `applyEditResult` の `guard result.state != timeline` が働き、履歴は増えない。
    /// revert が無いと編集中の `timeline.crop` は `.full` なので「`.full` → 元の値」の
    /// 変更に見え、**何も変えていないのに undo が 1 段積まれる**（取消と同じ操作なのに
    /// 履歴の見え方が食い違う）。
    func test_値を変えずに確定しても履歴が増えない() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        model.setCrop(crop)
        XCTAssertEqual(model.timeline.crop, crop, "前提が崩れている")

        let undoCountBefore = model.undoStack.count
        model.beginCropEditing()
        model.updateCropDraft(crop)
        model.commitCropEditing()

        XCTAssertEqual(model.timeline.crop, crop, "確定でクロップが変わってしまっている")
        XCTAssertEqual(model.undoStack.count, undoCountBefore,
                       "値を変えていないのに undo 履歴が増えている（確定前の戻しが効いていない）")
    }

    // MARK: - 4. 背景へ回っても失わない

    /// `EditorView` は `scenePhase != .active` / `onDisappear` / `handleBack()` で
    /// `persistDraft()` より先に `cancelCropEditing()` を呼ぶ（`EditorView.swift` 参照）。
    /// ここではモデル層の契約——`cancelCropEditing()` が確定済みのクロップを保つこと——を
    /// 直接検証する（View 層の呼び出し順序そのものはこのテストの対象外）。
    func test_編集中に背景へ回ってもクロップを失わない() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let before = CropRect(rect: CGRect(x: 0.15, y: 0.15, width: 0.5, height: 0.5))
        model.setCrop(before)

        model.beginCropEditing()
        model.updateCropDraft(CropRect(rect: CGRect(x: 0, y: 0, width: 0.9, height: 0.9)))

        // EditorView の scenePhase ハンドラが persistDraft() より先に呼ぶのと同じ操作。
        model.cancelCropEditing()

        XCTAssertEqual(model.timeline.crop, before,
                      "背景へ回っただけで確定済みのクロップが失われている")
        XCTAssertNil(model.cropDraft)
    }

    // MARK: - 5. ドラッグ中は再構築しない

    func test_ドラッグ中は合成を組み直さない() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])

        model.beginCropEditing()
        let generationAfterBegin = model.timelineGeneration

        model.updateCropDraft(CropRect(rect: CGRect(x: 0.1, y: 0, width: 0.5, height: 1)))
        model.updateCropDraft(CropRect(rect: CGRect(x: 0.2, y: 0, width: 0.4, height: 1)))
        model.updateCropDraft(CropRect(rect: CGRect(x: 0.3, y: 0, width: 0.3, height: 1)))

        XCTAssertEqual(model.timelineGeneration, generationAfterBegin,
                      "ドラッグ中の下書き更新が composition の再構築（世代インクリメント）を起こしている")
        XCTAssertEqual(model.cropDraft?.rect, CGRect(x: 0.3, y: 0, width: 0.3, height: 1))
        // composition 自体もまだ触っていないこと（タイムラインは crop=.full のまま）。
        XCTAssertEqual(model.timeline.crop, .full)
    }

    // MARK: - 6. 検出キャッシュへ触らないことの番人

    /// **これは初日から緑になる**（クロップの実装が `cacheStore` / `signatureCache` へ
    /// 一切触れないため）。素通りのテストではなく、将来クロップの実装が誤って検出
    /// キャッシュを消す・書き換える方向へ変わるのを止める**番人**である。
    ///
    /// 番人が生きていることは、`beginCropEditing()` に `cacheStore` を消す 1 行
    /// （例: `cacheStore.store([], sourceID: source, time: 1.0)`）を仮に入れて
    /// このテストが落ちることで確認済み（D フェーズの変異検証で実施・復元済み）。
    func test_クロップを変えても検出キャッシュが消えず座標も変わらない() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let face = fakeFace()
        model.cacheStore.store([face], sourceID: source, time: 1.0)
        XCTAssertEqual(model.cacheStore.count, 1, "前提が崩れている: キャッシュに書き込めていない")

        model.setCrop(CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        model.beginCropEditing()
        model.updateCropDraft(CropRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        model.commitCropEditing()

        XCTAssertEqual(model.cacheStore.count, 1,
                      "クロップ編集で検出キャッシュのエントリ数が変わった")
        let stored = model.cacheStore.faces(sourceID: source, time: 1.0)
        XCTAssertEqual(stored?.first?.points.map(\.x), face.points.map(\.x),
                      "クロップ編集で検出済み顔の座標が変わった"
                          + "（検出結果は素材フレーム基準で、出力枠のクロップとは独立のはず）")
    }

    // MARK: - 7. 比率変更はクロップを全面へ戻す（既存挙動の固定）

    func test_比率変更はクロップを全面へ戻す() {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])
        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        model.setCrop(crop)
        XCTAssertEqual(model.timeline.crop, crop, "前提が崩れている")

        model.setOutputAspectRatio(.portrait9x16)

        XCTAssertEqual(model.timeline.aspectRatio, .portrait9x16)
        XCTAssertEqual(model.timeline.crop, .full,
                      "比率変更でクロップが全面へ戻っていない（不可逆な二重変換の温床になる）")
    }

}

#endif
