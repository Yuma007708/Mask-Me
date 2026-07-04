import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// `MediaPipeFaceLandmarkerAdapter` の「検出全滅フレームをオプティカルフローで
/// ブリッジする」状態機械（src=flow・連続上限30・実検出復帰で再seed）を検証する。
///
/// seed 用の実顔フレームは `DValidVideoTests` と同じ方式でサンプル動画から取得する:
/// 環境変数 `SAMPLE_VIDEO_DIR` の指すディレクトリの `s2.mov`（検出率が最も安定）の
/// 中盤付近から `AVAssetImageGenerator` で1フレーム切り出す。環境変数未設定 or
/// 動画不在の場合のみ `XCTSkip`（`DValidVideoTests` と同条件）。
///
/// MediaPipe の実検出を決定論的に全滅させるため、Adapter の DEBUG 専用テストシーム
/// `simulateDetectionFailureForTesting` を使う（true の間は検出パイプライン全段を
/// スキップし、そのフレームを「検出全滅」として扱う）。平行移動フレームは取得した
/// seed フレームから CoreGraphics で生成する（余白は黒。移動後も顔領域自体は
/// 写っているので疎 LK は追跡できる）。
final class FlowBridgeTests: XCTestCase {

    private var videoDir: String { ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"] ?? "" }

    /// MediaPipe モデルはテストホスト (MaskMe.app) のバンドルから解決する
    /// （`makeFaceLandmarker` と同じ経路。FixtureLoader は使わない）。
    private func makeAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            throw XCTSkip("face_landmarker.task がアプリバンドルにありません")
        }
        // DValidVideoTests の .off backend と同じ MP 単独構成（決定論性優先）。
        var settings = DetectionSettings()
        settings.faceDetectorBackend = .off
        return try MediaPipeFaceLandmarkerAdapter(
            modelPath: modelPath, runningMode: .video, settings: settings
        )
    }

    /// s2.mov の中盤付近から「実検出が成功する」フレームを1枚探して返す。
    /// s2 は検出率 88.9% で最も安定しているため、中盤±数フレームの走査で必ず見つかる想定。
    /// 動画不在時のみ XCTSkip。見つからなければ XCTFail（環境ではなく検出の退行を疑う）。
    private func loadDetectableSeedFrame() async throws -> UIImage {
        try XCTSkipIf(videoDir.isEmpty, "SAMPLE_VIDEO_DIR 未設定（ローカルでは XCTSkip）")
        let url = URL(fileURLWithPath: "\(videoDir)/s2.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path),
                      "\(url.path) が存在しません")

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.067, preferredTimescale: 600)

        // 検出可否の判定は使い捨ての probe 用 adapter で行い、本編のテスト対象 adapter の
        // 内部状態（trackedFaces / flowStates / タイムスタンプ）を汚さない。
        let probe = try makeAdapter()
        let mid = duration / 2
        let candidates = stride(from: 0.0, through: 3.0, by: 0.5).map { mid + $0 }
        for (i, t) in candidates.enumerated() where t < duration {
            guard let cg = try? gen.copyCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
            ) else { continue }
            let img = UIImage(cgImage: cg)
            if !probe.allLandmarks(in: img, timestampMs: i * 100).isEmpty {
                return img
            }
        }
        XCTFail("s2.mov 中盤 \(mid)s 付近で実検出可能なフレームが見つかりませんでした")
        throw XCTSkip("seed フレーム取得失敗")
    }

    /// `image` を黒背景の同サイズキャンバスに (dx, dy) だけずらして描き直す。
    /// AVAssetImageGenerator 由来のフレームは scale=1 なのでポイント=ピクセル。
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

    /// seed フレームを実検出させ、trackedFaces / flowStates を seed する。
    @discardableResult
    private func seedWithRealDetection(
        _ adapter: MediaPipeFaceLandmarkerAdapter,
        image: UIImage,
        timestampMs: Int
    ) -> FaceLandmarkSet? {
        adapter.simulateDetectionFailureForTesting = false
        let result = adapter.allLandmarks(in: image, timestampMs: timestampMs)
        XCTAssertFalse(result.isEmpty, "seed フレームは実検出に成功するはず（probe 済み）")
        XCTAssertNotEqual(adapter.lastSource, .flow, "seed フレームは実検出ソースのはず")
        XCTAssertNotEqual(adapter.lastSource, .none)
        return result.first
    }

    // MARK: - (a) 既知量の平行移動をフローが前進として反映する

    func test_flowBridge_translatesLandmarksOnKnownShift() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeAdapter()
        let size = pixelSize(of: baseImage)

        let seeded = try XCTUnwrap(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))
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

    func test_flowBridge_stopsAfterMaxConsecutiveFrames() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeAdapter()
        XCTAssertNotNil(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))

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

    func test_flowBridge_reseedsAfterRealDetectionReturns() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeAdapter()
        XCTAssertNotNil(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))

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
        XCTAssertFalse(recovered.isEmpty, "seed 可能フレームなので実検出に復帰するはず")
        XCTAssertNotEqual(adapter.lastSource, .flow, "復帰フレームは実検出ソースのはず")
        XCTAssertNotEqual(adapter.lastSource, .none)

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

    // MARK: - (d) 面積ゲート isFlowBridgeEligible の境界

    /// 実顔（≤0.06）は通し、s5の体誤検出相当（0.11〜0.17）は弾く面積ゲートの境界確認。
    /// 実検出・フローの状態機械には触れず、純粋関数としての境界のみを検証する。
    func test_isFlowBridgeEligible_boundary() throws {
        let adapter = try makeAdapter()

        let area006 = CGRect(x: 0, y: 0, width: 0.3, height: 0.2)
        XCTAssertTrue(
            adapter.isFlowBridgeEligible(area006),
            "面積0.06（真顔相当）は適格のはず"
        )

        // 0.4×0.2 は浮動小数点誤差で 0.08000000000000002 (> 0.08) になるため、
        // 二進表現で厳密に 0.08 になる組み合わせ (0.16×0.5) を使う。
        let area008 = CGRect(x: 0, y: 0, width: 0.16, height: 0.5)
        XCTAssertTrue(
            adapter.isFlowBridgeEligible(area008),
            "面積0.08ちょうど（上限）は適格のはず（境界含む）"
        )

        let area012 = CGRect(x: 0, y: 0, width: 0.4, height: 0.3)
        XCTAssertFalse(
            adapter.isFlowBridgeEligible(area012),
            "面積0.12（体誤検出相当）は不適格のはず"
        )
    }
}
#endif
