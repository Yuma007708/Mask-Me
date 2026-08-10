import CoreGraphics
import XCTest
@testable import MosaicCore

/// `PreviewZoomSession` の契約。
///
/// ジェスチャの時系列（began → changed → ended、ダブルタップ、reset）を通しても
/// `PreviewZoomMath` の不変条件（アンカー保持・可動域クランプ・跳ねない基準倍率）が
/// 保たれることを固定する。
final class PreviewZoomSessionTests: XCTestCase {
    private let fittedSize = CGSize(width: 200, height: 200)
    private let containerSize = CGSize(width: 200, height: 200)

    /// ピンチ → 離す で倍率が残る。
    func test_pinchThenEnd_scalePersists() {
        var session = PreviewZoomSession()
        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 2, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        session.ended()
        XCTAssertEqual(session.zoom.scale, 2)
        XCTAssertFalse(session.isActive)
    }

    /// **2 回目のピンチが現在倍率から始まる。** `began` → `changed(magnification: 1)` の時点で
    /// 倍率がまだ 2（指を置いた瞬間に絵が跳ばない）。
    func test_secondPinch_startsFromCurrentScale() {
        var session = PreviewZoomSession()
        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 2, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        session.ended()
        XCTAssertEqual(session.zoom.scale, 2)

        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 1, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom.scale, 2, "2 回目のピンチ開始直後に倍率が跳ねてはいけない")
    }

    /// ピンチ中のパンが可動域でクランプされる。
    func test_panDuringPinch_isClampedToBounds() {
        var session = PreviewZoomSession()
        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 2, translation: CGSize(width: 9999, height: -9999),
                        fittedSize: fittedSize, containerSize: containerSize)
        let bound = PreviewZoomMath.maxOffset(scale: 2, fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom.offset.width, bound.width, accuracy: 1e-9)
        XCTAssertEqual(session.zoom.offset.height, -bound.height, accuracy: 1e-9)
    }

    /// 1 倍では translation を与えても offset が 0 のまま。
    func test_panAtIdentityScale_offsetStaysZero() {
        var session = PreviewZoomSession()
        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 1, translation: CGSize(width: 50, height: 50),
                        fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom.offset, .zero)
    }

    /// ダブルタップの往復。
    func test_doubleTapped_roundTrips() {
        var session = PreviewZoomSession()
        session.doubleTapped(anchorFromCenter: CGSize(width: 10, height: 10),
                             fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom.scale, 3)
        session.doubleTapped(anchorFromCenter: CGSize(width: 10, height: 10),
                             fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom, .identity)
    }

    /// `reset()` 直後に `began` → `changed(magnification: 2)` で倍率が 2
    /// （1 でも 4 でもない＝古い base が残っていない）。
    func test_reset_thenPinch_startsCleanBase() {
        var session = PreviewZoomSession()
        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 2, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        session.ended()
        XCTAssertEqual(session.zoom.scale, 2)

        session.reset()
        XCTAssertEqual(session.zoom, .identity)

        session.began(anchorFromCenter: .zero)
        session.changed(magnification: 2, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertEqual(session.zoom.scale, 2, "reset 後の古い base (2) が残って 4 にならないこと")
    }

    /// `isActive` が `began`〜`ended` の間だけ真。
    func test_isActive_onlyBetweenBeganAndEnded() {
        var session = PreviewZoomSession()
        XCTAssertFalse(session.isActive)
        session.began(anchorFromCenter: .zero)
        XCTAssertTrue(session.isActive)
        session.changed(magnification: 1.5, translation: .zero, fittedSize: fittedSize, containerSize: containerSize)
        XCTAssertTrue(session.isActive)
        session.ended()
        XCTAssertFalse(session.isActive)
    }
}
