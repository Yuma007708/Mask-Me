import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// Runs the real MediaPipe landmarker over a short fixture clip frame-by-frame,
/// measuring the per-video detection rate and confirming tracking locks on.
/// Requires the pod + model + `Fixtures/sample_face.mov`; otherwise `XCTSkip`.
final class VideoDetectionTests: XCTestCase {
    /// faces in the clip should be detected across most frames.
    private let minVideoDetectionRate = 80.0
    /// Sample at ~5 fps; enough to exercise tracking without long test runs.
    private let frameInterval = 0.2

    func testDetectionRateAndTrackingOverVideo() throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let url = FixtureLoader.videoURL(named: "sample_face") else {
            throw XCTSkip("Fixtures/sample_face.mov がありません")
        }

        let adapter = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)
        let frames = try Self.extractFrames(from: url, interval: frameInterval)
        try XCTSkipIf(frames.isEmpty, "動画からフレームを抽出できませんでした")

        var meter = DetectionRateMeter()
        var evaluator = TrackingEvaluator()
        var didLock = false

        for (index, frame) in frames.enumerated() {
            let timestampMs = Int(Double(index) * frameInterval * 1000)
            let set = adapter.landmarks(in: frame, timestampMs: timestampMs)
            meter.record(set)
            let status = evaluator.update(confidence: set?.confidence)
            if status.state == .tracking { didLock = true }
        }

        XCTAssertGreaterThanOrEqual(
            meter.detectionRate,
            minVideoDetectionRate,
            "動画の検出率 \(meter.detectionRate)% が目標 \(minVideoDetectionRate)% 未満 "
                + "(\(meter.detectedCount)/\(meter.total))"
        )
        XCTAssertTrue(didLock, "追従が一度も .tracking にロックしませんでした")
    }

    /// Decodes frames at a fixed interval into `UIImage`s.
    private static func extractFrames(from url: URL, interval: Double) throws -> [UIImage] {
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var images: [UIImage] = []
        var time = 0.0
        while time < duration {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                images.append(UIImage(cgImage: cgImage))
            }
            time += interval
        }
        return images
    }
}
#endif
