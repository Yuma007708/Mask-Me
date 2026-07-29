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

    /// 実顔素材で検出できたフレーム数の下限（15fps・先頭 10 秒・実機ライブと同じ縮小幅）。
    ///
    /// 2026-07-29 の実測値そのまま。**この数字を下げる変更は検出の退行**であり、
    /// 誤検出がいくら下がっても採ってはいけない（プライバシーアプリなので顔の見逃しのほうが重い）。
    /// `probe_hard_backlight` は元から 0 フレームなので下限を置けず、対象外。
    private static let detectedFrameFloor: [String: Int] = [
        "profile": 91,
        "sample_face": 75,
        "probe_hard_dark": 41,
        "probe_hard_motion": 45,
        "probe_hard_occluded": 18,
        "probe_beach_01": 36,
        "probe_crowd_01": 19,
    ]

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

    /// 診断: crop 再検証（`verifySuspiciousFaces`）が横顔と体誤フィットをそれぞれ
    /// **どのゲートで**落としているかの内訳を出す。
    ///
    /// 内訳の出力に加えて、**実顔素材の検出フレーム数が減っていないこと**を判定する。
    /// 誤検出を下げる修正（`isTrustedFlowSeed` など）が実顔を巻き添えにする事故は実際に
    /// 起きており（`MediaPipeFaceLandmarkerAdapter` の「棄却の記憶」不採用記録）、
    /// 誤検出率テスト（`SampleFalsePositiveTests`）だけでは片側しか守れない。
    ///
    /// 合否を持つのでファイルを分けたいが、`MaskMeTests` は新規ファイルが XcodeGen 経由で
    /// ターゲットに入らず**無言で実行されない**ため、走査ループを持つこのテストに同居させる。
    func test_verifyRejectionBreakdown_realFaceDetectionIsNotReduced() async throws {
        var targets: [(String, URL)] = []
        if let profile = FixtureLoader.videoURL(named: "profile") {
            targets.append(("profile(実顔・横顔)", profile))
        }
        if let sample = FixtureLoader.videoURL(named: "sample_face") {
            targets.append(("sample_face(実顔)", sample))
        }
        // 検出が難しい実顔（逆光・暗所・動きブレ・遮蔽）。棄却が連続しやすいのはここなので、
        // 「実顔の連続棄却はどこまで伸びるか」の上限はこの 4 本で決まる。
        for name in ["probe_hard_backlight", "probe_hard_dark", "probe_hard_motion",
                     "probe_hard_occluded", "probe_beach_01", "probe_crowd_01"] {
            if let url = Bundle(for: Self.self)
                .url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/probe") {
                targets.append(("\(name)(実顔)", url))
            }
        }
        for name in ["probe_body_torso_01", "probe_body_yoga_01"] {
            let url = URL(fileURLWithPath: "\(sampleDir)/nonfaces/\(name).mov")
            if FileManager.default.fileExists(atPath: url.path) {
                targets.append(("\(name)(顔なし)", url))
            }
        }
        try XCTSkipIf(targets.isEmpty, "profile.mov も nonfaces も無い")

        for (label, url) in targets {
            let scanner = makeFaceLandmarker(forVideo: true, settings: DetectionSettings())
            guard let adapter = scanner as? MediaPipeFaceLandmarkerAdapter else {
                throw XCTSkip("MediaPipe が結線されていない（pod install 済みか確認）")
            }
            adapter.resetVerifyStats()

            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.067, preferredTimescale: 600)

            var frames = 0, hits = 0
            var missed: [String] = []
            var t = 0.0
            while t <= min(duration, 10.0) {
                autoreleasepool {
                    guard let cg = try? gen.copyCGImage(
                        at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                    ) else { return }
                    frames += 1
                    // 実機ライブ検出と同じ幅に縮小してから通す。フル解像度で走査すると
                    // 誤検出が起きず（実測: torso 0%）、計測したい条件そのものが消える。
                    let img = UIImage(cgImage: SampleFalsePositiveTests.downscaleForLiveDetection(cg))
                    if scanner.allLandmarks(in: img, timestampMs: Int(t * 1000)).isEmpty {
                        missed.append(String(format: "%.2f", t))
                    } else {
                        hits += 1
                    }
                }
                t += 1.0 / 15.0
            }
            let s = adapter.verifyStats
            fputs("""
            [VERIFY] \(label) frames=\(frames) detected=\(hits) \
            examined=\(s.examined) passed=\(s.passed) grace=\(s.savedByGrace) \
            preGate=\(s.preGate) noRedetect=\(s.noRedetection) geometry=\(s.geometry) \
            conf=\(s.confidence) bodyShape=\(s.bodyShape) displaced=\(s.displaced) \
            streaks=\(s.rejectStreaks.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")) \
            passAfter=\(s.passAfterStreaks.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")) \
            missedAt=[\(missed.prefix(6).joined(separator: ","))]\n
            """, stderr)

            if let floor = Self.detectedFrameFloor[url.deletingPathExtension().lastPathComponent] {
                XCTAssertGreaterThanOrEqual(
                    hits, floor,
                    "\(label): 実顔の検出が \(floor) → \(hits) フレームに減っている。"
                    + "誤検出を下げる修正が実顔を巻き添えにしていないか確認すること")
            }
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
