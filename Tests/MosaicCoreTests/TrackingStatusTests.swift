import XCTest
@testable import MosaicCore

final class TrackingStatusTests: XCTestCase {
    func testStartsIdle() {
        let evaluator = TrackingEvaluator()
        XCTAssertEqual(evaluator.status.state, .idle)
        XCTAssertEqual(evaluator.status.rate, 0)
        XCTAssertFalse(evaluator.status.faceDetected)
    }

    func testConfidentDetectionEntersTracking() {
        var evaluator = TrackingEvaluator()
        let status = evaluator.update(confidence: 0.9)
        XCTAssertEqual(status.state, .tracking)
        XCTAssertTrue(status.faceDetected)
        XCTAssertGreaterThan(status.rate, 0)
    }

    func testRateConvergesTowardConfidence() {
        var evaluator = TrackingEvaluator(smoothing: 0.5)
        for _ in 0..<50 {
            evaluator.update(confidence: 0.8)
        }
        // EMA toward 80% should settle very close to 80.
        XCTAssertEqual(evaluator.status.rate, 80, accuracy: 0.5)
    }

    func testBelowThresholdConfidenceCountsAsMiss() {
        var evaluator = TrackingEvaluator(lockThreshold: 0.5)
        let status = evaluator.update(confidence: 0.2)
        XCTAssertFalse(status.faceDetected)
        XCTAssertEqual(status.state, .searching)
    }

    func testLostThenSearchingOnDropout() {
        var evaluator = TrackingEvaluator()
        evaluator.update(confidence: 0.9)            // tracking
        let lost = evaluator.update(confidence: nil) // first miss → lost
        XCTAssertEqual(lost.state, .lost)
        let searching = evaluator.update(confidence: nil) // still gone → searching
        XCTAssertEqual(searching.state, .searching)
    }

    func testRateDecaysWhileLost() {
        var evaluator = TrackingEvaluator(lostDecay: 0.5)
        evaluator.update(confidence: 1.0)
        let before = evaluator.status.rate
        evaluator.update(confidence: nil)
        XCTAssertLessThan(evaluator.status.rate, before)
    }

    func testInstantReacquisitionAfterLoss() {
        var evaluator = TrackingEvaluator()
        evaluator.update(confidence: 0.9)
        evaluator.update(confidence: nil) // lost
        evaluator.update(confidence: nil) // searching
        // A single confident frame must resume tracking immediately — no warm-up.
        let resumed = evaluator.update(confidence: 0.95)
        XCTAssertEqual(resumed.state, .tracking)
        XCTAssertTrue(resumed.faceDetected)
    }

    func testResetReturnsToIdle() {
        var evaluator = TrackingEvaluator()
        evaluator.update(confidence: 0.9)
        evaluator.reset()
        XCTAssertEqual(evaluator.status, .idle)
    }

    func testRateStaysWithinBounds() {
        var evaluator = TrackingEvaluator()
        for value in [1.0, 0.0, 1.2, -0.3, 0.5] as [Float] {
            let status = evaluator.update(confidence: value)
            XCTAssertGreaterThanOrEqual(status.rate, 0)
            XCTAssertLessThanOrEqual(status.rate, 100)
        }
    }
}
