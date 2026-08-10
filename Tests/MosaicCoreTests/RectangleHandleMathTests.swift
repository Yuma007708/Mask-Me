import CoreGraphics
import XCTest
@testable import MosaicCore

/// 傾いた矩形をつまむ計算の契約。
///
/// ここが狂うと「指と別の方向へ伸びる」「掴んだ瞬間に跳ねる」という、
/// 触った瞬間に分かるが原因は分からない壊れ方をする。
final class RectangleHandleMathTests: XCTestCase {
    private let square = CGRect(x: 100, y: 100, width: 100, height: 100)

    // MARK: - ローカル軸への変換

    func test_localDelta_withoutRotation_isUnchanged() {
        let delta = CGSize(width: 12, height: -7)
        XCTAssertEqual(RectangleHandleMath.localDelta(delta, angle: 0), delta)
    }

    /// **90° 傾いた矩形では、画面の右方向が矩形にとっての下方向になる。**
    func test_localDelta_rotatesIntoTheRectangleAxes() {
        let result = RectangleHandleMath.localDelta(CGSize(width: 10, height: 0),
                                                    angle: .pi / 2)
        XCTAssertEqual(result.width, 0, accuracy: 1e-9)
        XCTAssertEqual(result.height, -10, accuracy: 1e-9)
    }

    /// 変換しても長さは変わらない（回転なので）。
    func test_localDelta_preservesLength() {
        let delta = CGSize(width: 3, height: 4)
        for angle in [0.3, 1.0, -2.2, Double.pi] {
            let result = RectangleHandleMath.localDelta(delta, angle: angle)
            XCTAssertEqual(hypot(result.width, result.height), 5, accuracy: 1e-9,
                           "angle=\(angle) で長さが変わっている")
        }
    }

    func test_localDelta_withNonFiniteAngle_isUnchanged() {
        let delta = CGSize(width: 5, height: 6)
        XCTAssertEqual(RectangleHandleMath.localDelta(delta, angle: .nan), delta)
    }

    // MARK: - 大きさを変える

    /// **中心が動かないこと。** 動くと、傾けた矩形を大きくしただけで位置がずれる。
    func test_resizedAroundCenter_keepsTheCenter() {
        let result = RectangleHandleMath.resizedAroundCenter(square,
                                                             byLocal: CGSize(width: 20, height: 5))
        XCTAssertEqual(result.midX, square.midX, accuracy: 1e-9)
        XCTAssertEqual(result.midY, square.midY, accuracy: 1e-9)
    }

    /// 片側へ 20pt 引いたら、幅は両側ぶんの 40pt 増える。
    func test_resizedAroundCenter_growsOnBothSides() {
        let result = RectangleHandleMath.resizedAroundCenter(square,
                                                             byLocal: CGSize(width: 20, height: 10))
        XCTAssertEqual(result.width, 140, accuracy: 1e-9)
        XCTAssertEqual(result.height, 120, accuracy: 1e-9)
    }

    /// **潰しきれないこと。** 0 まで縮むと、掴む場所ごと消えて元へ戻せなくなる。
    func test_resizedAroundCenter_stopsAtTheMinimumSide() {
        let result = RectangleHandleMath.resizedAroundCenter(
            square, byLocal: CGSize(width: -999, height: -999))
        XCTAssertEqual(result.width, RectangleHandleMath.minimumSide)
        XCTAssertEqual(result.height, RectangleHandleMath.minimumSide)
        XCTAssertEqual(result.midX, square.midX, accuracy: 1e-9, "最小まで縮めて中心がずれた")
    }

    func test_resizedAroundCenter_withNonFiniteDelta_isUnchanged() {
        XCTAssertEqual(RectangleHandleMath.resizedAroundCenter(
            square, byLocal: CGSize(width: CGFloat.nan, height: 0)), square)
    }

    // MARK: - 角度

    func test_angle_pointsRightIsZero() {
        let angle = RectangleHandleMath.angle(from: CGPoint(x: 0, y: 0),
                                              to: CGPoint(x: 10, y: 0))
        XCTAssertEqual(angle ?? .nan, 0, accuracy: 1e-9)
    }

    func test_angle_pointsDownIsQuarterTurn() {
        let angle = RectangleHandleMath.angle(from: CGPoint(x: 0, y: 0),
                                              to: CGPoint(x: 0, y: 10))
        XCTAssertEqual(angle ?? .nan, .pi / 2, accuracy: 1e-9)
    }

    /// **中心と指が重なったら nil。** 0 を返すと、指が中心を通った瞬間に
    /// 矩形が水平へ跳ねる。
    func test_angle_atTheCenterIsNil() {
        XCTAssertNil(RectangleHandleMath.angle(from: CGPoint(x: 5, y: 5),
                                               to: CGPoint(x: 5, y: 5)))
        XCTAssertNil(RectangleHandleMath.angle(from: CGPoint(x: 5, y: 5),
                                               to: CGPoint(x: 5.5, y: 5)))
    }

    // MARK: - 回す

    /// **掴んだ瞬間は動かないこと。** 指の位置をそのまま角度にすると、
    /// つまみは矩形の外にあるので掴むだけで矩形が回ってしまう。
    func test_rotated_doesNotJumpOnGrab() {
        let grabbed = RectangleHandleMath.rotated(from: 1.2, by: 1.2, initial: 0.3)
        XCTAssertEqual(grabbed, 0.3, accuracy: 1e-9)
    }

    func test_rotated_appliesTheDifference() {
        let result = RectangleHandleMath.rotated(from: 1.0, by: 1.5, initial: 0.2)
        XCTAssertEqual(result, 0.7, accuracy: 1e-9)
    }

    /// 結果は ±π に畳まれる（何周も回して貯めない）。
    func test_rotated_wrapsIntoPlusMinusPi() {
        let result = RectangleHandleMath.rotated(from: 0, by: .pi * 2 + 0.4, initial: 0)
        XCTAssertEqual(result, 0.4, accuracy: 1e-9)
    }

    func test_rotated_withNonFiniteInput_keepsTheInitialAngle() {
        XCTAssertEqual(RectangleHandleMath.rotated(from: .nan, by: 1, initial: 0.5), 0.5)
        XCTAssertEqual(RectangleHandleMath.rotated(from: 1, by: .infinity, initial: 0.5), 0.5)
    }
}
