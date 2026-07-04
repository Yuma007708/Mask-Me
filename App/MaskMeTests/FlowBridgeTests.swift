import XCTest
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// `MediaPipeFaceLandmarkerAdapter` の「検出全滅フレームをオプティカルフローで
/// ブリッジする」状態機械（src=flow・連続上限30・実検出復帰で再seed）を検証する。
///
/// MediaPipe の実検出を決定論的に全滅させるため、Adapter の DEBUG 専用テストシーム
/// `simulateDetectionFailureForTesting` を使う（true の間は検出パイプライン全段を
/// スキップし、そのフレームを「検出全滅」として扱う）。実顔画像は
/// `DetectionAccuracyTests` と同じ `Fixtures/faces` を流用し、既知量だけ平行移動した
/// フレームを CoreGraphics で生成して与える（余白は黒。移動後も顔領域自体は写っている
/// ので疎 LK は追跡できる）。
///
/// MediaPipe pod・モデル・実顔フィクスチャが必要なため、欠けている場合や実顔フィク
/// スチャがこの環境で検出できない場合は、失敗ではなく `XCTSkip` する
/// （`DetectionAccuracyTests` と同じ方針）。
final class FlowBridgeTests: XCTestCase {

    private func makeAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません（Fixtures に配置してください）")
        }
        return try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)
    }

    private func firstFaceImage() throws -> UIImage {
        let faces = FixtureLoader.images(in: "faces")
        try XCTSkipIf(faces.isEmpty, "Fixtures/faces に顔画像がありません")
        return faces[0]
    }

    /// `image` を黒背景の同サイズキャンバスに (dx, dy) だけずらして描き直す。
    /// 余白は黒でよい。移動後も顔領域自体はフレーム内に残るので LK は追跡できる。
    private func translated(_ image: UIImage, dx: CGFloat, dy: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: image.size))
            image.draw(at: CGPoint(x: dx, y: dy))
        }
    }

    /// UIImage のピクセル寸法（UIImage.size はポイント単位で scale 依存のため CGImage を使う）。
    private func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }

    /// 種フレームを実検出させ、trackedFaces / flowStates を seed する。
    /// 実顔フィクスチャがこの環境の MediaPipe で検出できない場合は XCTSkip する
    /// （フロー状態機械そのものの欠陥ではなく環境依存の検出可否のため）。
    @discardableResult
    private func seedWithRealDetection(
        _ adapter: MediaPipeFaceLandmarkerAdapter,
        image: UIImage,
        timestampMs: Int
    ) throws -> FaceLandmarkSet {
        adapter.simulateDetectionFailureForTesting = false
        let result = adapter.allLandmarks(in: image, timestampMs: timestampMs)
        try XCTSkipIf(
            result.isEmpty,
            "実顔フィクスチャがこの環境の MediaPipe で検出されませんでした（BLOCKED候補）"
        )
        XCTAssertEqual(adapter.lastSource, .mp, "seed フレームは src=mp で検出されるはず")
        return result[0]
    }

    // MARK: - (a) 既知量の平行移動をフローが前進として反映する

    func test_flowBridge_translatesLandmarksOnKnownShift() throws {
        #if DEBUG
        let adapter = try makeAdapter()
        let baseImage = try firstFaceImage()
        let size = pixelSize(of: baseImage)

        let seeded = try seedWithRealDetection(adapter, image: baseImage, timestampMs: 0)
        let baseFlowFrames = adapter.sourceStats.flowFrames

        let dx: CGFloat = 12, dy: CGFloat = 8
        let shifted = translated(baseImage, dx: dx, dy: dy)

        adapter.simulateDetectionFailureForTesting = true
        let result = adapter.allLandmarks(in: shifted, timestampMs: 100)

        XCTAssertFalse(result.isEmpty, "検出全滅でもフロー・ブリッジで空でない結果が返るはず")
        XCTAssertEqual(adapter.lastSource, .flow, "src=flow で記録されるはず")
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, baseFlowFrames + 1,
            "flowFrames カウンタが1件増えるはず"
        )

        let before = seeded.boundingBox
        let after = try XCTUnwrap(result.first).boundingBox
        let beforeCenter = CGPoint(x: before.midX * size.width, y: before.midY * size.height)
        let afterCenter = CGPoint(x: after.midX * size.width, y: after.midY * size.height)
        XCTAssertEqual(
            afterCenter.x - beforeCenter.x, dx, accuracy: 3.0,
            "返るbboxの水平移動量が仕込んだdxとほぼ一致するはず"
        )
        XCTAssertEqual(
            afterCenter.y - beforeCenter.y, dy, accuracy: 3.0,
            "返るbboxの垂直移動量が仕込んだdyとほぼ一致するはず"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }

    // MARK: - (b) 連続上限30フレームで打ち切られる

    func test_flowBridge_stopsAfterMaxConsecutiveFrames() throws {
        #if DEBUG
        let adapter = try makeAdapter()
        let baseImage = try firstFaceImage()
        try seedWithRealDetection(adapter, image: baseImage, timestampMs: 0)

        let shifted = translated(baseImage, dx: 12, dy: 8)
        adapter.simulateDetectionFailureForTesting = true

        var ts = 100
        for frame in 1...31 {
            ts += 10
            let result = adapter.allLandmarks(in: shifted, timestampMs: ts)
            if frame <= 30 {
                XCTAssertFalse(result.isEmpty, "フレーム \(frame) はまだフロー供給されるはず（上限30）")
                XCTAssertEqual(adapter.lastSource, .flow, "フレーム \(frame) は src=flow のはず")
            } else {
                XCTAssertTrue(result.isEmpty, "31フレーム目は連続上限で打ち切られ空になるはず")
            }
        }
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 30,
            "flowFrames は連続上限30でカウントが止まるはず"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }

    // MARK: - (c) 上限打ち切り後、実検出復帰で再seed・カウンタリセットされる

    func test_flowBridge_reseedsAfterRealDetectionReturns() throws {
        #if DEBUG
        let adapter = try makeAdapter()
        let baseImage = try firstFaceImage()
        try seedWithRealDetection(adapter, image: baseImage, timestampMs: 0)

        let shifted = translated(baseImage, dx: 12, dy: 8)
        adapter.simulateDetectionFailureForTesting = true

        var ts = 100
        for _ in 1...31 {
            ts += 10
            _ = adapter.allLandmarks(in: shifted, timestampMs: ts)
        }
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 30,
            "前提: 上限打ち切りまで到達しているはず"
        )

        // 実検出に復帰させる（フラグOFF + 元の実顔フレーム）。
        adapter.simulateDetectionFailureForTesting = false
        ts += 10
        let recovered = adapter.allLandmarks(in: baseImage, timestampMs: ts)
        try XCTSkipIf(
            recovered.isEmpty,
            "実顔フィクスチャがこの環境の MediaPipe で検出されませんでした（BLOCKED候補）"
        )
        XCTAssertEqual(adapter.lastSource, .mp, "実検出復帰フレームは src=mp のはず")

        // 再seedされているはずなので、フラグを戻せば再びフローが供給される。
        adapter.simulateDetectionFailureForTesting = true
        ts += 10
        let flowedAgain = adapter.allLandmarks(in: shifted, timestampMs: ts)
        XCTAssertFalse(flowedAgain.isEmpty, "実検出復帰による再seed後は再びフローが供給されるはず")
        XCTAssertEqual(adapter.lastSource, .flow)
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 31,
            "カウンタがリセットされた上で再カウントされているはず（30で止まらない）"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }
}
#endif
