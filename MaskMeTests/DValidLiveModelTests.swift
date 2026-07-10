import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// 実動画 × フルモデル経路（選択層込み）の被覆率計測。
///
/// DValidLivePathTests は検出器〜lookupFaces までしか測らず、実機の描画が通る
/// 選択層（detectedFaces / isSelected / selectedLandmarks の重心マッチング）を
/// バイパスしていた。実機報告「フレームアウト→イン後に一切モザイクが掛からない」
/// はこの未検証層で起きたため、本テストは実機と同じ
/// storeLiveDetection → selectedLandmarks の経路で「ユーザーが目にするモザイク」
/// の被覆率を実動画で測る。
///
/// 出力: `[DVALMODEL] {json}` を 1 動画 1 行。
///   - modelCoverage: selectedLandmarks(at:) が非空を返したフレーム割合
///     （lookup 段の previewCoverage と比べ、選択層での取りこぼしを検出する）
final class DValidLiveModelTests: XCTestCase {
    private static let bucketFPS = 15.0
    private let ciContext = CIContext()

    private var sampleDir: String? {
        ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"]
    }

    /// 被覆率ゲート。新セット導入時はまず現状ベースラインで回帰防止し、
    /// 改修後に 0.90 へ引き上げる運用のため env で可変にしている。
    private var gate: Double {
        ProcessInfo.processInfo.environment["DVAL_GATE"].flatMap(Double.init) ?? 0.90
    }

    @MainActor
    func test_LiveModelPath_AllSamples() async throws {
        guard let dir = sampleDir else {
            throw XCTSkip("SAMPLE_VIDEO_DIR 未設定")
        }
        for name in ["s1", "s2", "s3", "s4", "s5"] {
            let url = URL(fileURLWithPath: "\(dir)/\(name).mov")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let coverage = try await measureModelPath(name: name, url: url)
            XCTAssertGreaterThanOrEqual(
                coverage, gate,
                "\(name): 選択層込みのモザイク被覆率が基準未満")
        }
    }

    /// 実機のライブ再生と同じ流れ: 各バケットのフレームを 640px に縮小 → IMAGE モード
    /// 検出 → storeLiveDetection（選択層シード・追跡込み）→ 全バケットで
    /// selectedLandmarks を引いて被覆率を出す。
    @MainActor
    private func measureModelPath(name: String, url: URL) async throws -> Double {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)

        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())

        var frames = 0
        var flowFrames = 0
        let interval = 1.0 / Self.bucketFPS
        var t = 0.0
        while t <= duration {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else { return }
                let img = UIImage(cgImage: downscaleForLiveDetection(cg))
                // 実機と同じライブ経路: IMAGE 検出 + テンポラル ROI 再検出 + フロー橋渡し
                let detection = scanner.liveLandmarks(in: img, atMediaSeconds: t)
                if detection.bridgedByFlow { flowFrames += 1 }
                model.storeLiveDetection(detection, at: model.liveBucket(t), source: img)
                // 複数顔動画は自動選択されない（ユーザーがサムネで選ぶ仕様）ため、
                // 「全員選択した」ユーザー操作を再現する。単一顔は自動選択のまま。
                if !model.detectedFaces.isEmpty,
                   !model.detectedFaces.contains(where: \.isSelected) {
                    for face in model.detectedFaces { model.toggleFace(face.id) }
                }
                frames += 1
            }
            t += interval
        }

        var hits = 0
        for time in stride(from: 0.0, through: duration, by: interval)
        where !model.selectedLandmarks(at: time).isEmpty {
            hits += 1
        }
        let coverage = frames > 0 ? Double(hits) / Double(frames) : 0
        let selectedCount = model.detectedFaces.filter(\.isSelected).count
        // どのレバー（ROI 再検出 / フロー橋渡し）が何フレーム救ったかの帰属。
        let stats = (scanner as? MediaPipeFaceLandmarkerAdapter)?.sourceStats
        let json = """
        [DVALMODEL] {"video":"\(name)","frames":\(frames),\
        "modelCoverage":\(String(format: "%.4f", coverage)),\
        "faces":\(model.detectedFaces.count),"selected":\(selectedCount),\
        "roiFrames":\(stats?.roiFrames ?? 0),"flowFrames":\(flowFrames)}
        """
        fputs(json + "\n", stderr)
        return coverage
    }

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
