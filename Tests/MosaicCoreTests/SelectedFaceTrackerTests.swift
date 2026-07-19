import XCTest
import CoreGraphics
@testable import MosaicCore

/// エクスポート／プレビュー共通の「選択顔の時系列追跡」検証。
/// 旧実装（選択時の静的位置と距離照合）では移動した顔・再入した顔のモザイクが
/// 書き出し動画から消えていた回帰のテスト。
final class SelectedFaceTrackerTests: XCTestCase {
    private func face(cx: Float, cy: Float, size: Float = 0.2) -> FaceLandmarkSet {
        let h = size / 2
        return FaceLandmarkSet(points: [
            FaceLandmark(x: cx - h, y: cy - h), FaceLandmark(x: cx + h, y: cy - h),
            FaceLandmark(x: cx - h, y: cy + h), FaceLandmark(x: cx + h, y: cy + h)
        ], confidence: 1)
    }

    func testEmptySelectionPassesAllFaces() {
        var tracker = SelectedFaceTracker(initialCentroids: [])
        XCTAssertEqual(tracker.filter([face(cx: 0.1, cy: 0.1), face(cx: 0.9, cy: 0.9)]).count, 2)
    }

    /// 画面を横断する移動でも追跡位置が更新され、モザイクが外れないこと
    /// （旧実装は初期位置から 0.3 で打ち切られ、移動しただけで消えていた）。
    func testTracksFaceMovingAcrossFrame() {
        var tracker = SelectedFaceTracker(initialCentroids: [CGPoint(x: 0.1, y: 0.5)])
        var x: Float = 0.1
        while x < 0.9 {
            x += 0.1
            XCTAssertEqual(tracker.filter([face(cx: x, cy: 0.5)]).count, 1,
                           "x=\(x) で移動中の選択顔がフィルタで棄却された")
        }
    }

    /// 単一選択 × 単一検出はフレームアウト→反対側から再インしても再捕捉すること。
    func testSoleFaceReacquiredAfterFarReentry() {
        var tracker = SelectedFaceTracker(initialCentroids: [CGPoint(x: 0.15, y: 0.3)])
        XCTAssertEqual(tracker.filter([face(cx: 0.15, cy: 0.3)]).count, 1)
        // フレームアウト（検出なしフレームが続く）
        for _ in 0..<20 { XCTAssertTrue(tracker.filter([]).isEmpty) }
        // 反対側から再イン（距離 ≈ 0.79）
        XCTAssertEqual(tracker.filter([face(cx: 0.85, cy: 0.7)]).count, 1,
                       "再入した唯一の顔を再捕捉できない")
        // 以降は新しい位置から追跡が続く
        XCTAssertEqual(tracker.filter([face(cx: 0.83, cy: 0.68)]).count, 1)
    }

    /// 複数検出のフレームでは無条件再捕捉が発動せず、非選択の顔を巻き込まないこと。
    func testMultiFaceFrameKeepsOnlySelected() {
        var tracker = SelectedFaceTracker(initialCentroids: [CGPoint(x: 0.2, y: 0.2)])
        let kept = tracker.filter([face(cx: 0.22, cy: 0.21), face(cx: 0.8, cy: 0.8)])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(SelectedFaceTracker.centroid(of: kept[0]).x, 0.22, accuracy: 0.01)
    }

    /// 選択顔がいないフレームで遠くの非選択顔へ飛び移らないこと。
    func testDoesNotJumpToDistantFaceWhenMultipleTracked() {
        var tracker = SelectedFaceTracker(initialCentroids: [
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5)
        ])
        // どの追跡位置からも 0.5 以上離れた顔のみのフレーム
        XCTAssertTrue(tracker.filter([face(cx: 0.95, cy: 0.95)]).isEmpty)
    }
}
