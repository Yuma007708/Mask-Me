import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// 診断専用: 対象動画の全長にわたって 1 秒ごとに顔検出のみ実行し、
/// 何秒に顔が出るかを stderr にダンプする。画像は保存・表示しない（統計のみ）。
final class DiagFaceCoverageTests: XCTestCase {
    private var sampleDir: String {
        ProcessInfo.processInfo.environment["SAMPLE_DIR"] ?? "/Users/tatsuki/Downloads/サンプル"
    }

    func test_Diag_faceCoverageOverFullDuration() async throws {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sampleDir)) ?? []
        let urls = names
            .filter { ["mov","mp4","m4v"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { URL(fileURLWithPath: "\(sampleDir)/\($0)") }
        try XCTSkipIf(urls.isEmpty)

        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let ctx = CIContext()

        for url in urls {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            fputs("[COV] === \(url.lastPathComponent) duration=\(String(format: "%.1f", duration)) ===\n", stderr)
            var t = 0.0
            var hits = 0, samples = 0
            var firstHit: Double? = nil
            while t <= duration {
                autoreleasepool {
                    guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return }
                    // 実機ライブと同一の 480px 縮小
                    let scale = min(480.0 / Double(cg.width), 1.0)
                    let img: UIImage
                    if scale < 0.99, let out = ctx.createCGImage(CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale)), from: CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale)).extent) {
                        img = UIImage(cgImage: out)
                    } else {
                        img = UIImage(cgImage: cg)
                    }
                    samples += 1
                    let faces = scanner.allLandmarks(in: img)
                    if !faces.isEmpty {
                        hits += 1
                        if firstHit == nil { firstHit = t }
                    }
                    // 顔がある時のみ位置とサイズを出す（画像は出さない）
                    if let f = faces.first {
                        let bb = f.boundingBox
                        fputs(String(format: "[COV] t=%.1f face bb(x=%.2f y=%.2f w=%.2f h=%.2f) conf=%.2f\n",
                                     t, bb.minX, bb.minY, bb.width, bb.height, f.confidence), stderr)
                    }
                }
                t += 1.0
            }
            fputs(String(format: "[COV] SUMMARY %@: samples=%d hits=%d firstHit=%@\n",
                         url.lastPathComponent, samples, hits,
                         firstHit.map { String(format: "%.1f", $0) } ?? "none"), stderr)
        }
    }

    /// フル解像度・0.5 秒刻みで video 2 の全長を精査する（480px 縮小が原因かを切り分け）。
    func test_Diag_video2_fullResFineScan() async throws {
        let url = URL(fileURLWithPath: "\(sampleDir)/ScreenRecording_07-08-2026 13-55-11_1.MP4")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path))
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        var t = 0.0, samples = 0, hits = 0
        while t <= duration {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return }
                samples += 1
                let faces = scanner.allLandmarks(in: UIImage(cgImage: cg))
                if !faces.isEmpty {
                    hits += 1
                    let bb = faces[0].boundingBox
                    fputs(String(format: "[FULL] t=%.1f face bb(x=%.2f y=%.2f w=%.2f h=%.2f) conf=%.2f\n",
                                 t, bb.minX, bb.minY, bb.width, bb.height, faces[0].confidence), stderr)
                }
            }
            t += 0.5
        }
        fputs(String(format: "[FULL] SUMMARY samples=%d hits=%d\n", samples, hits), stderr)
    }
}

#endif
