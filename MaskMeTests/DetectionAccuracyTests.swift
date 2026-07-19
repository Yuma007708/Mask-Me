import XCTest
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// Measures real-image face-detection accuracy by running the actual MediaPipe
/// landmarker against bundled fixtures. Requires the pod + model + images, so it
/// runs on a Simulator / device; missing inputs `XCTSkip` instead of failing.
final class DetectionAccuracyTests: XCTestCase {
    /// faces fixtures must be detected at least this often.
    private let minDetectionRate = 90.0
    /// nonfaces fixtures may be (mis)detected at most this often.
    private let maxFalsePositiveRate = 10.0

    private func makeAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません（Fixtures に配置してください）")
        }
        return try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .image)
    }

    func testDetectionRateOnFaceImages() throws {
        let adapter = try makeAdapter()
        let faces = FixtureLoader.images(in: "faces")
        try XCTSkipIf(faces.isEmpty, "Fixtures/faces に顔画像がありません")

        var meter = DetectionRateMeter()
        for image in faces {
            meter.record(adapter.landmarks(in: image))
        }

        XCTAssertGreaterThanOrEqual(
            meter.detectionRate,
            minDetectionRate,
            "顔検出率 \(meter.detectionRate)% が目標 \(minDetectionRate)% を下回りました "
                + "(\(meter.detectedCount)/\(meter.total))"
        )
    }

    func testFalsePositiveRateOnNonFaceImages() throws {
        let adapter = try makeAdapter()
        let nonFaces = FixtureLoader.images(in: "nonfaces")
        try XCTSkipIf(nonFaces.isEmpty, "Fixtures/nonfaces に画像がありません")

        var meter = DetectionRateMeter()
        for image in nonFaces {
            meter.record(adapter.landmarks(in: image))
        }

        XCTAssertLessThanOrEqual(
            meter.detectionRate,
            maxFalsePositiveRate,
            "誤検出率 \(meter.detectionRate)% が許容 \(maxFalsePositiveRate)% を超えました "
                + "(\(meter.detectedCount)/\(meter.total))"
        )
    }

    func testDetectedLandmarksAreWellFormed() throws {
        let adapter = try makeAdapter()
        let faces = FixtureLoader.images(in: "faces")
        try XCTSkipIf(faces.isEmpty, "Fixtures/faces に顔画像がありません")

        var checkedAtLeastOne = false
        for image in faces {
            guard let set = adapter.landmarks(in: image) else { continue }
            checkedAtLeastOne = true
            XCTAssertTrue(set.isFullMesh, "478 点のフルメッシュであるべき (got \(set.points.count))")
            for point in set.points {
                XCTAssertTrue((0...1).contains(point.x), "x が [0,1] 外: \(point.x)")
                XCTAssertTrue((0...1).contains(point.y), "y が [0,1] 外: \(point.y)")
            }
        }
        XCTAssertTrue(checkedAtLeastOne, "少なくとも 1 枚は検出されるべき")
    }
}
#endif
