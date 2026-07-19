import XCTest
import CoreGraphics
@testable import MosaicCore

final class KalmanBoxTrackerTests: XCTestCase {
    /// 静止顔（毎フレーム同じ観測）で、Kalman の予測位置が観測に収束する。
    func testConvergesOnStationaryTarget() {
        let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)
        var tracker = KalmanBoxTracker(initialBox: box)
        for _ in 0..<10 {
            tracker.predict()
            tracker.update(observation: box)
        }
        let predicted = tracker.predictedBox
        XCTAssertEqual(predicted.midX, box.midX, accuracy: 0.02)
        XCTAssertEqual(predicted.midY, box.midY, accuracy: 0.02)
        XCTAssertLessThan(tracker.speedMagnitude, 0.01)
    }

    /// 等速で移動する顔に対し、predict 後の位置が「次観測」を先取りする。
    func testPredictsForwardMotion() {
        var tracker = KalmanBoxTracker(initialBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        // 初期観測（速度を推定させる）
        for i in 0..<5 {
            let cx = 0.2 + Double(i) * 0.05
            let cy = 0.2
            let observation = CGRect(x: cx - 0.1, y: cy - 0.1, width: 0.2, height: 0.2)
            tracker.predict()
            tracker.update(observation: observation)
        }
        XCTAssertGreaterThan(tracker.speedMagnitude, 0.01,
                             "速度が推定されていない")

        // 次フレームの予測が観測位置(0.5-0.1=0.4)方向に進んでいる
        let before = tracker.cx
        tracker.predict()
        XCTAssertGreaterThan(tracker.cx, before,
                             "predict 後の cx が前進していない（速度が反映されていない）")
    }

    /// 予測 bbox が [0, 1] 範囲外に飛び出さない。
    func testPredictedBoxClamped() {
        var tracker = KalmanBoxTracker(initialBox: CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2))
        for _ in 0..<20 {
            tracker.predict()
            tracker.update(observation: CGRect(x: 0.95, y: 0.95, width: 0.2, height: 0.2))
        }
        let predicted = tracker.predictedBox
        XCTAssertGreaterThanOrEqual(predicted.minX, 0)
        XCTAssertGreaterThanOrEqual(predicted.minY, 0)
        XCTAssertLessThanOrEqual(predicted.maxX, 1.01)
        XCTAssertLessThanOrEqual(predicted.maxY, 1.01)
    }
}
