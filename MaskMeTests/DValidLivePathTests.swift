import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// ライブプレビュー経路の検出精度計測。
///
/// 実機/シミュレータの再生中モザイクは `MosaicPreviewController.detectionCGImage`
/// （`MosaicEditorModel.liveDetectionTargetWidth` px 幅縮小）+ IMAGE モード
/// スキャナーという「本スキャンより軽い経路」で検出される。本スキャン（フル解像度 VIDEO モード + enhance/ROI/flow）を測る
/// DValidVideoTests とは別に、この経路単体の実力を同じ検証動画で計測する。
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

        // アプリのライブ検出と同一: IMAGE モード + アプリ既定 DetectionSettings
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
