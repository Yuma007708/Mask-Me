import XCTest
@testable import MosaicCore

final class DetectionRateMeterTests: XCTestCase {
    func testEmptyMeterIsZero() {
        let meter = DetectionRateMeter()
        XCTAssertEqual(meter.total, 0)
        XCTAssertEqual(meter.detectedCount, 0)
        XCTAssertEqual(meter.missedCount, 0)
        XCTAssertEqual(meter.detectionRate, 0)
    }

    func testAllDetectedIsHundredPercent() {
        var meter = DetectionRateMeter()
        for _ in 0..<5 { meter.record(detected: true) }
        XCTAssertEqual(meter.total, 5)
        XCTAssertEqual(meter.detectedCount, 5)
        XCTAssertEqual(meter.detectionRate, 100, accuracy: 0.0001)
    }

    func testNoneDetectedIsZeroPercent() {
        var meter = DetectionRateMeter()
        for _ in 0..<4 { meter.record(detected: false) }
        XCTAssertEqual(meter.total, 4)
        XCTAssertEqual(meter.detectedCount, 0)
        XCTAssertEqual(meter.missedCount, 4)
        XCTAssertEqual(meter.detectionRate, 0)
    }

    func testMixedRate() {
        var meter = DetectionRateMeter()
        // 3 detected out of 4 → 75%.
        meter.record(detected: true)
        meter.record(detected: false)
        meter.record(detected: true)
        meter.record(detected: true)
        XCTAssertEqual(meter.detectedCount, 3)
        XCTAssertEqual(meter.missedCount, 1)
        XCTAssertEqual(meter.detectionRate, 75, accuracy: 0.0001)
    }

    func testLandmarkSetOverloadCountsNilAsMiss() {
        var meter = DetectionRateMeter()
        meter.record(nil)
        meter.record(FaceLandmarkSet(points: [FaceLandmark(x: 0.5, y: 0.5)], confidence: 1.0))
        XCTAssertEqual(meter.total, 2)
        XCTAssertEqual(meter.detectedCount, 1)
        XCTAssertEqual(meter.detectionRate, 50, accuracy: 0.0001)
    }

    func testLandmarkSetOverloadHonorsMinConfidence() {
        var meter = DetectionRateMeter()
        let lowConfidence = FaceLandmarkSet(points: [FaceLandmark(x: 0.1, y: 0.1)], confidence: 0.3)
        meter.record(lowConfidence, minConfidence: 0.5)
        XCTAssertEqual(meter.detectedCount, 0)

        let highConfidence = FaceLandmarkSet(points: [FaceLandmark(x: 0.1, y: 0.1)], confidence: 0.9)
        meter.record(highConfidence, minConfidence: 0.5)
        XCTAssertEqual(meter.detectedCount, 1)
    }

    func testLandmarkSetOverloadHonorsRequireFullMesh() {
        var meter = DetectionRateMeter()
        let partial = FaceLandmarkSet(points: [FaceLandmark(x: 0.5, y: 0.5)], confidence: 1.0)
        meter.record(partial, requireFullMesh: true)
        XCTAssertEqual(meter.detectedCount, 0, "partial mesh must count as a miss")

        let full = FaceLandmarkSet(
            points: Array(repeating: FaceLandmark(x: 0.5, y: 0.5), count: FaceLandmarkSet.fullMeshCount),
            confidence: 1.0
        )
        meter.record(full, requireFullMesh: true)
        XCTAssertEqual(meter.detectedCount, 1)
    }

    func testReproducesTrackingTrajectoryFromDetectionSequence() {
        // A detection sequence drives both the rate meter and the tracking
        // evaluator: detected frames lock tracking, gaps drop it.
        let sequence: [Float?] = [0.9, 0.95, nil, nil, 0.9]
        var meter = DetectionRateMeter()
        var evaluator = TrackingEvaluator()
        for confidence in sequence {
            meter.record(detected: (confidence ?? 0) >= evaluator.lockThreshold)
            evaluator.update(confidence: confidence)
        }
        // 3 of 5 frames detected → 60%.
        XCTAssertEqual(meter.detectionRate, 60, accuracy: 0.0001)
        // The final confident frame re-locks tracking.
        XCTAssertEqual(evaluator.status.state, .tracking)
    }
}
