import XCTest
import CoreGraphics
@testable import MosaicCore

final class DetectionBridgeTests: XCTestCase {
    private let bridge = DetectionBridge()

    /// 中心 `(cx, cy)`・辺 `span` の正方形に均等配置した簡易顔を作る。
    /// bbox が (cx-span/2, cy-span/2, span, span) になるので IoU 判定を制御しやすい。
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

    func testExactHitIsReturnedDirectly() {
        let cache: [Double: [FaceLandmarkSet]] = [1.0: [face(cx: 0.5, cy: 0.5)]]
        let result = bridge.faces(in: cache, at: 1.0)
        XCTAssertEqual(result.count, 1)
    }

    func testGapWithBothSidesIsBridgedWithBeforeFaces() {
        let before = face(cx: 0.5, cy: 0.5)
        let after = face(cx: 0.52, cy: 0.5)  // わずかに移動 (IoU > 0.3)
        let cache: [Double: [FaceLandmarkSet]] = [1.0: [before], 1.2: [after]]
        let result = bridge.faces(in: cache, at: 1.1)
        XCTAssertEqual(result.count, 1)
        // ホールド型: before の座標がそのまま返る
        XCTAssertEqual(result[0], before)
    }

    func testOneSidedGapReturnsEmpty() {
        // after 側にしか検出がない（フレームイン境界）
        let cache: [Double: [FaceLandmarkSet]] = [1.2: [face(cx: 0.5, cy: 0.5)]]
        XCTAssertTrue(bridge.faces(in: cache, at: 1.1).isEmpty)
    }

    func testGapWiderThanWindowReturnsEmpty() {
        let cache: [Double: [FaceLandmarkSet]] = [
            0.0: [face(cx: 0.5, cy: 0.5)],
            1.0: [face(cx: 0.5, cy: 0.5)]
        ]
        // 両側とも bridgeWindow (5/15≒0.33s) を超えて離れている
        XCTAssertTrue(bridge.faces(in: cache, at: 0.5).isEmpty)
    }

    func testTeleportedFaceIsNotBridged() {
        // before と after で位置が大きく変わる（IoU ≒ 0）→ フレームアウト→イン と判定
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [face(cx: 0.2, cy: 0.2)],
            1.2: [face(cx: 0.8, cy: 0.8)]
        ]
        XCTAssertTrue(bridge.faces(in: cache, at: 1.1).isEmpty)
    }

    func testOnlyContinuousFacesSurviveBridging() {
        // 2顔のうち片方だけが after にも続いている
        let continuing = face(cx: 0.3, cy: 0.3)
        let vanishing = face(cx: 0.7, cy: 0.7)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [continuing, vanishing],
            1.2: [face(cx: 0.31, cy: 0.3)]
        ]
        let result = bridge.faces(in: cache, at: 1.1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], continuing)
    }

    func testEmptyDetectionEntriesAreIgnored() {
        // 空配列のキャッシュエントリ（検出0フレーム）は before/after 探索から除外される
        let before = face(cx: 0.5, cy: 0.5)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [before],
            1.1: [],
            1.2: [face(cx: 0.5, cy: 0.5)]
        ]
        let result = bridge.faces(in: cache, at: 1.1)
        XCTAssertEqual(result.count, 1)
    }

    func testInterpolatingBridgeLerpsTowardAfter() {
        let lerp = DetectionBridge(interpolates: true)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [face(cx: 0.5, cy: 0.5)],
            1.2: [face(cx: 0.56, cy: 0.5)]
        ]
        // 中間時刻 (alpha=0.5) では centroid も中間の 0.53 になる
        let result = lerp.faces(in: cache, at: 1.1)
        XCTAssertEqual(result.count, 1)
        let cx = result[0].points.map(\.x).reduce(0, +) / Float(result[0].points.count)
        XCTAssertEqual(cx, 0.53, accuracy: 0.001)
    }

    func testInterpolatingBridgeAlphaFollowsTimeRatio() {
        let lerp = DetectionBridge(interpolates: true)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [face(cx: 0.5, cy: 0.5)],
            1.2: [face(cx: 0.56, cy: 0.5)]
        ]
        // before に近い時刻では before 寄り (alpha=0.25 → 0.515)
        let result = lerp.faces(in: cache, at: 1.05)
        let cx = result[0].points.map(\.x).reduce(0, +) / Float(result[0].points.count)
        XCTAssertEqual(cx, 0.515, accuracy: 0.001)
    }

    func testInterpolatingBridgeStillRejectsTeleportedFaces() {
        let lerp = DetectionBridge(interpolates: true)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [face(cx: 0.2, cy: 0.2)],
            1.2: [face(cx: 0.8, cy: 0.8)]
        ]
        // IoU マッチしないペアは lerp モードでも補間されない（別人モーフィング防止）
        XCTAssertTrue(lerp.faces(in: cache, at: 1.1).isEmpty)
    }

    func testWiderWindowBridgesLongerGap() {
        let wide = DetectionBridge(bridgeWindow: 10.0 / 15.0)
        let cache: [Double: [FaceLandmarkSet]] = [
            1.0: [face(cx: 0.5, cy: 0.5)],
            2.0: [face(cx: 0.5, cy: 0.5)]
        ]
        // 既定 (5/15) では届かないギャップも window 拡大なら埋まる
        XCTAssertTrue(bridge.faces(in: cache, at: 1.5).isEmpty)
        XCTAssertEqual(wide.faces(in: cache, at: 1.5).count, 1)
    }
}
