import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// IMAGE モード検出（timestamp 無しの `allLandmarks(in:)`）単体の検出精度計測。
///
/// **注意（実態に即した訂正）**: 本テストが呼ぶのは `scanner.allLandmarks(in: UIImage)`
/// （IMAGE モード、timestamp 無し）であり、アプリの実際のライブ検出経路
/// `MediaPipeFaceLandmarkerAdapter.liveLandmarks(in:atMediaSeconds:)`（Kalman予測 ROI
/// 再検出 + オプティカルフロー橋渡しのテンポラル追跡込み）とは別物である。「ライブプレビュー
/// 経路」を謳っているが、実際は `MosaicPreviewController.detectionCGImage`
/// （`MosaicEditorModel.liveDetectionTargetWidth` px 幅縮小）と同じ縮小規則を適用した画像に
/// 素の IMAGE モード検出をかけるだけの簡易計測であり、テンポラル追跡は一切含まない。
/// 本スキャン（フル解像度 VIDEO モード + enhance/ROI/flow）を測る DValidVideoTests とは別に、
/// この単純化した経路単体の実力を同じ検証動画で計測する。
///
/// 「体・首・肩への誤モザイク対策 第一弾」（`isSuspectBodyRegion` / `verifySuspiciousFaces`、
/// コミット `a3556db`）は VIDEO モードとアプリの `liveLandmarks` 経路にのみ配線されており、
/// この `allLandmarks(in:)` 経路には一切効かない。したがって本対策の効果はこのテストの
/// `bodyFP` 数値には現れない（測っている経路が異なるため）。
///
/// 出力: `[DVALLIVE] {json}` を stderr に 1 動画 1 行。
///   - liveRate: サンプルフレームのうちライブ検出が顔を返した割合
///   - previewCoverage: プレビューの lookup（bridge + 0.75s ホールド）を
///     シミュレートしてモザイクが描画される割合（ユーザーが体感する値）
///   - bodyFP: 縦長 bbox（ピクセル換算の h/w > 1.4）の検出数。体・首を顔として
///     拾った疑いの代理指標。正規化座標のままの縦横比は動画のアスペクト比が
///     混入する（16:9 横長動画では正方形の顔が h/w=1.78 になり全件誤カウント）
///     ため、必ず動画のピクセル寸法で換算する。
final class DValidLivePathTests: XCTestCase {
    private static let bucketFPS = 15.0
    private let ciContext = CIContext()

    private var sampleDir: String? {
        ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"]
    }

    func test_LivePath_AllSamples() async throws {
        guard let dir = sampleDir else {
            throw XCTSkip("SAMPLE_VIDEO_DIR 未設定")
        }
        for name in ["s1", "s2", "s3", "s4", "s5"] {
            let url = URL(fileURLWithPath: "\(dir)/\(name).mov")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let metrics = try await measureLivePath(name: name, url: url)
            // ライブ経路の回帰ゲート。previewCoverage はユーザーが再生中に
            // モザイクを目にする割合に相当する（値は本計測で確定した実測基準）。
            XCTAssertGreaterThanOrEqual(
                metrics.previewCoverage, 0.90,
                "\(name): ライブプレビュー被覆率が基準未満")
        }
    }

    private struct LiveMetrics {
        var frames = 0
        var liveHits = 0
        var previewHits = 0
        var bodyFP = 0
        var previewCoverage: Double { frames > 0 ? Double(previewHits) / Double(frames) : 0 }
    }

    private func measureLivePath(name: String, url: URL) async throws -> LiveMetrics {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)

        // 素の IMAGE モード検出（timestamp 無し）+ アプリ既定 DetectionSettings。
        // アプリの実際のライブ経路 `liveLandmarks(in:atMediaSeconds:)`
        // （Kalman/ROI/オプティカルフローのテンポラル追跡込み）とは異なる簡易計測。
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())

        var metrics = LiveMetrics()
        var cache: [Double: [FaceLandmarkSet]] = [:]
        var t = 0.0
        let interval = 1.0 / Self.bucketFPS
        while t <= duration {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else { return }
                let faces = scanner.allLandmarks(in: UIImage(cgImage: downscaleForLiveDetection(cg)))
                metrics.frames += 1
                if !faces.isEmpty { metrics.liveHits += 1 }
                let pxW = Double(cg.width)
                let pxH = Double(cg.height)
                metrics.bodyFP += faces.filter {
                    let bb = $0.boundingBox
                    return Double(bb.height) * pxH / max(Double(bb.width) * pxW, 1) > 1.4
                }.count
                cache[t] = faces   // ライブ検出は空も記録する（storeLiveDetection と同じ）
            }
            t += interval
        }

        // プレビューの lookupFaces と同じ手順（bridge → 0.75s 最近傍ホールド）で
        // 「モザイクが描画されるフレーム」をシミュレートする。
        let bridge = DetectionBridge(interpolates: true)
        for time in stride(from: 0.0, through: duration, by: interval) {
            let bridged = bridge.faces(in: cache, at: time)
            if !bridged.isEmpty {
                metrics.previewHits += 1
            } else if let nearest = nearestEntry(in: cache, at: time, window: 0.75),
                      !nearest.isEmpty {
                metrics.previewHits += 1
            }
        }

        let json = """
        [DVALLIVE] {"video":"\(name)","frames":\(metrics.frames),\
        "liveRate":\(String(format: "%.4f", metrics.frames > 0 ? Double(metrics.liveHits) / Double(metrics.frames) : 0)),\
        "previewCoverage":\(String(format: "%.4f", metrics.previewCoverage)),\
        "bodyFP":\(metrics.bodyFP)}
        """
        fputs(json + "\n", stderr)
        return metrics
    }

    /// MosaicEditorModel.nearestCachedFaces と同じ規則（空エントリも最近傍対象）。
    private func nearestEntry(
        in cache: [Double: [FaceLandmarkSet]], at time: Double, window: Double
    ) -> [FaceLandmarkSet]? {
        var best: (dist: Double, faces: [FaceLandmarkSet])?
        for (t, faces) in cache {
            let d = abs(t - time)
            if d > window { continue }
            if best == nil || d < best!.dist { best = (d, faces) }
        }
        return best?.faces
    }

    /// MosaicPreviewController.detectionCGImage と同じ縮小規則（CIImage スケール）。
    /// 目標幅はアプリ本体と同じ定数を参照し、テストと実機の条件を常に一致させる。
    private func downscaleForLiveDetection(_ cg: CGImage) -> CGImage {
        let targetWidth = MosaicEditorModel.liveDetectionTargetWidth
        let scale = min(targetWidth / Double(cg.width), 1.0)
        guard scale < 1.0 else { return cg }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(ci, from: ci.extent) ?? cg
    }
}

#endif
