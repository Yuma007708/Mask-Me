import XCTest
import CoreGraphics
@testable import MosaicCore

/// リアルタイム撮影のオプトアウト選択（タップで OFF にした顔だけ除外）の検証。
/// 焼き込み撮影は失敗が不可逆のため、迷ったら「モザイク ON」に倒れることを確認する。
final class CameraFaceSelectionTests: XCTestCase {
    private func face(cx: Float, cy: Float, size: Float = 0.2) -> FaceLandmarkSet {
        let h = size / 2
        return FaceLandmarkSet(points: [
            FaceLandmark(x: cx - h, y: cy - h), FaceLandmark(x: cx + h, y: cy - h),
            FaceLandmark(x: cx - h, y: cy + h), FaceLandmark(x: cx + h, y: cy + h)
        ], confidence: 1)
    }

    /// 既定（オプトアウトなし）は全ての顔にモザイクが掛かる。
    func testDefaultMasksAllFaces() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4), face(cx: 0.7, cy: 0.4)]
        XCTAssertEqual(sel.facesToMask(from: faces).count, 2)
    }

    /// タップで OFF にした顔だけが除外され、もう一度タップすると ON に戻る。
    func testToggleExcludesAndRestoresFace() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4), face(cx: 0.7, cy: 0.4)]

        XCTAssertEqual(sel.toggle(at: CGPoint(x: 0.3, y: 0.4), in: faces), false)
        let masked = sel.facesToMask(from: faces)
        XCTAssertEqual(masked.count, 1)
        XCTAssertEqual(masked.first.map { SelectedFaceTracker.centroid(of: $0).x } ?? -1,
                       0.7, accuracy: 0.001)

        XCTAssertEqual(sel.toggle(at: CGPoint(x: 0.3, y: 0.4), in: faces), true)
        XCTAssertEqual(sel.facesToMask(from: faces).count, 2)
    }

    /// 顔の無い場所のタップは何も変えない。
    func testToggleOnEmptyAreaDoesNothing() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4)]
        XCTAssertNil(sel.toggle(at: CGPoint(x: 0.9, y: 0.9), in: faces))
        XCTAssertEqual(sel.facesToMask(from: faces).count, 1)
    }

    /// OFF にした顔が移動しても追従して除外されつづける。
    func testUnmaskedTrackFollowsMovingFace() {
        var sel = CameraFaceSelection()
        var x: Float = 0.2
        sel.toggle(at: CGPoint(x: 0.2, y: 0.5), in: [face(cx: x, cy: 0.5)])
        while x < 0.8 {
            x += 0.1
            let masked = sel.facesToMask(from: [face(cx: x, cy: 0.5), face(cx: 0.1, cy: 0.1)])
            XCTAssertEqual(masked.count, 1, "x=\(x) で OFF 顔の追従が切れた")
            XCTAssertEqual(masked.first.map { SelectedFaceTracker.centroid(of: $0).y } ?? -1,
                           0.1, accuracy: 0.001)
        }
    }

    /// フレームアウトが続いた OFF 顔はトラック破棄され、再イン時は安全側で ON に戻る。
    func testLostUnmaskedFaceRevertsToMaskedOnReentry() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.2, y: 0.5), in: [face(cx: 0.2, cy: 0.5)])

        // OFF 顔が消えて別の顔だけが映りつづける（ロストが数えられる状況）
        for _ in 0...CameraFaceSelection.lostFrameTolerance {
            _ = sel.facesToMask(from: [face(cx: 0.9, cy: 0.9)])
        }
        XCTAssertEqual(sel.unmaskedCount, 0, "ロスト超過で OFF トラックが破棄されるはず")
        XCTAssertEqual(sel.facesToMask(from: [face(cx: 0.2, cy: 0.5)]).count, 1)
    }

    /// 検出が全滅したフレームはロストに数えない（フロー上限切れ等で検出が
    /// 止まっているだけの可能性があるため、OFF 状態を維持する）。
    func testEmptyDetectionFramesDoNotCountAsLost() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [face(cx: 0.5, cy: 0.5)])

        for _ in 0..<(CameraFaceSelection.lostFrameTolerance * 3) {
            XCTAssertTrue(sel.facesToMask(from: []).isEmpty)
        }
        XCTAssertEqual(sel.unmaskedCount, 1)
        XCTAssertTrue(sel.facesToMask(from: [face(cx: 0.5, cy: 0.5)]).isEmpty,
                      "検出復帰後も OFF が維持されるはず")
    }

    /// 離れた位置に現れた別人が OFF を引き継がない（matchDistance 外）。
    func testDistantNewcomerDoesNotInheritOptOut() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.2, y: 0.2), in: [face(cx: 0.2, cy: 0.2)])
        let newcomer = face(cx: 0.8, cy: 0.8)
        XCTAssertEqual(sel.facesToMask(from: [newcomer]).count, 1,
                       "OFF 顔から離れた新顔は既定どおりモザイク ON のはず")
    }

    /// 2 つの OFF トラックが同じ顔を二重に除外しない（1:1 割り当て）。
    func testTwoTracksDoNotExcludeSameFaceTwice() {
        var sel = CameraFaceSelection()
        let two = [face(cx: 0.4, cy: 0.5), face(cx: 0.55, cy: 0.5)]
        sel.toggle(at: CGPoint(x: 0.4, y: 0.5), in: two)
        sel.toggle(at: CGPoint(x: 0.55, y: 0.5), in: two)
        // 片方だけが映るフレーム: 除外は 1 顔ぶんだけ
        XCTAssertTrue(sel.facesToMask(from: [face(cx: 0.45, cy: 0.5)]).isEmpty)
        // 3 人目が加わっても除外は 2 顔まで
        let three = two + [face(cx: 0.7, cy: 0.5)]
        XCTAssertEqual(sel.facesToMask(from: three).count, 1)
    }

    /// reset で全員 ON に戻る。
    func testResetRestoresAllMasks() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.5, cy: 0.5)]
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: faces)
        sel.reset()
        XCTAssertEqual(sel.facesToMask(from: faces).count, 1)
    }
}
