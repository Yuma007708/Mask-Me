import XCTest
import CoreGraphics
@testable import MosaicCore

final class LandmarkSmootherTests: XCTestCase {
    /// 中心 `(cx, cy)`・辺 `span` の正方形顔。
    private func face(cx: Float, cy: Float, span: Float = 0.2) -> FaceLandmarkSet {
        let half = span / 2
        let points = [
            FaceLandmark(x: cx - half, y: cy - half),
            FaceLandmark(x: cx + half, y: cy - half),
            FaceLandmark(x: cx - half, y: cy + half),
            FaceLandmark(x: cx + half, y: cy + half)
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    private func centroidX(_ set: FaceLandmarkSet) -> Float {
        set.points.map(\.x).reduce(0, +) / Float(set.points.count)
    }

    func testFirstFramePassesThrough() {
        let smoother = LandmarkSmoother(alpha: 0.5)
        let f = face(cx: 0.5, cy: 0.5)
        XCTAssertEqual(smoother.smooth([f]), [f])
    }

    func testSmallJitterIsDamped() {
        let smoother = LandmarkSmoother(alpha: 0.5)
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        // +0.02 の移動 → 速度適応 alpha = 0.5 + 0.5 * (0.02 / 0.05) = 0.7 で減衰
        let out = smoother.smooth([face(cx: 0.52, cy: 0.5)])
        XCTAssertEqual(centroidX(out[0]), 0.514, accuracy: 0.0001)
    }

    func testAdaptiveAlphaTracksFastMotionCloser() {
        let smoother = LandmarkSmoother(alpha: 0.5, snapDistance: 0.05)
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        // snapDistance 直下の速い移動 → alpha がほぼ 1 に上がり遅れがほぼ消える
        let out = smoother.smooth([face(cx: 0.548, cy: 0.5)])
        let lag = 0.548 - centroidX(out[0])
        XCTAssertLessThan(lag, 0.002, "高速移動で EMA 遅延が残っている")
        // 一方、ごく微小なジッタには基準 alpha 近くの減衰が効いている
        smoother.reset()
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        let jitter = smoother.smooth([face(cx: 0.505, cy: 0.5)])
        XCTAssertEqual(centroidX(jitter[0]), 0.50275, accuracy: 0.0005)
    }

    func testLargeJumpSnapsWithoutSmoothing() {
        let smoother = LandmarkSmoother(alpha: 0.5, snapDistance: 0.05)
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        // 0.1 の移動は snapDistance 超え → スナップ（素通し）
        let out = smoother.smooth([face(cx: 0.6, cy: 0.5)])
        XCTAssertEqual(centroidX(out[0]), 0.6, accuracy: 0.0001)
    }

    func testUnmatchedFacePassesThrough() {
        let smoother = LandmarkSmoother(alpha: 0.5)
        _ = smoother.smooth([face(cx: 0.2, cy: 0.2)])
        // 前フレームと IoU が取れない別位置の顔はそのまま
        let newFace = face(cx: 0.8, cy: 0.8)
        XCTAssertEqual(smoother.smooth([newFace]), [newFace])
    }

    func testResetDropsState() {
        let smoother = LandmarkSmoother(alpha: 0.5)
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        smoother.reset()
        // reset 後は初回扱い（平滑化されない）
        let out = smoother.smooth([face(cx: 0.52, cy: 0.5)])
        XCTAssertEqual(centroidX(out[0]), 0.52, accuracy: 0.0001)
    }

    func testSmoothingConvergesOverFrames() {
        let smoother = LandmarkSmoother(alpha: 0.5, snapDistance: 1.0)
        _ = smoother.smooth([face(cx: 0.5, cy: 0.5)])
        var last: Float = 0
        for _ in 0..<10 {
            last = centroidX(smoother.smooth([face(cx: 0.52, cy: 0.5)])[0])
        }
        // 同じ観測を繰り返せば観測値に収束する
        XCTAssertEqual(last, 0.52, accuracy: 0.001)
    }
}
