import CoreGraphics
import XCTest
@testable import MosaicCore

/// `PreviewZoomMath` の契約。
///
/// 境界（1...8）・非有限入力の丸め・アンカー保持・可動域のクランプを固定する。
/// ここが狂うと `PreviewImageGeometry` を経由する全オーバーレイが揃ってずれる。
final class PreviewZoomMathTests: XCTestCase {
    // MARK: - clampedScale

    func test_clampedScale_belowMinimum_clampsToOne() {
        XCTAssertEqual(PreviewZoomMath.clampedScale(0.3), 1)
    }

    func test_clampedScale_aboveMaximum_clampsToEight() {
        XCTAssertEqual(PreviewZoomMath.clampedScale(100), 8)
    }

    func test_clampedScale_nonFiniteOrNonPositive_fallsBackToOne() {
        XCTAssertEqual(PreviewZoomMath.clampedScale(.nan), 1)
        XCTAssertEqual(PreviewZoomMath.clampedScale(.infinity), 1)
        XCTAssertEqual(PreviewZoomMath.clampedScale(-.infinity), 1)
        XCTAssertEqual(PreviewZoomMath.clampedScale(0), 1)
        XCTAssertEqual(PreviewZoomMath.clampedScale(-2), 1)
    }

    func test_clampedScale_withinRange_isUnchanged() {
        XCTAssertEqual(PreviewZoomMath.clampedScale(4.5), 4.5)
    }

    // MARK: - scale(base:magnification:)

    /// 指を置いた瞬間（`magnification == 1`）に倍率が跳ねないこと。
    func test_scale_atMagnificationOne_returnsBaseBitIdentical() {
        XCTAssertEqual(PreviewZoomMath.scale(base: 2.5, magnification: 1), 2.5)
    }

    func test_scale_appliesMagnificationAndClamps() {
        XCTAssertEqual(PreviewZoomMath.scale(base: 2, magnification: 2), 4)
        XCTAssertEqual(PreviewZoomMath.scale(base: 2, magnification: 10), 8)
        XCTAssertEqual(PreviewZoomMath.scale(base: 2, magnification: 0.1), 1)
    }

    func test_scale_nonFiniteOrNonPositiveMagnification_returnsBase() {
        XCTAssertEqual(PreviewZoomMath.scale(base: 3, magnification: .nan), 3)
        XCTAssertEqual(PreviewZoomMath.scale(base: 3, magnification: 0), 3)
        XCTAssertEqual(PreviewZoomMath.scale(base: 3, magnification: -1), 3)
    }

    // MARK: - maxOffset / clampedOffset

    /// 1 倍では両軸ともレターボックスの有無にかかわらず可動域が 0。
    func test_maxOffset_atIdentityScale_isZeroEvenWithLetterbox() {
        let fitted = CGSize(width: 100, height: 200) // 縦長画像
        let container = CGSize(width: 400, height: 200) // 横長コンテナ（左右に黒帯）
        let bound = PreviewZoomMath.maxOffset(scale: 1, fittedSize: fitted, containerSize: container)
        XCTAssertEqual(bound.width, 0)
        XCTAssertEqual(bound.height, 0)
    }

    /// 横長コンテナ×縦長画像を 1.5 倍しても、画像幅がコンテナ幅を超えるまで x の可動域は 0。
    func test_maxOffset_pillarboxedAxis_staysZeroUntilImageExceedsContainer() {
        let fitted = CGSize(width: 100, height: 200)
        let container = CGSize(width: 400, height: 200)
        // 100 * 1.5 = 150 < 400 なのでまだ超えない。
        let stillZero = PreviewZoomMath.maxOffset(scale: 1.5, fittedSize: fitted, containerSize: container)
        XCTAssertEqual(stillZero.width, 0)
        // 100 * 4.5 = 450 > 400 なので超える。
        let exceeded = PreviewZoomMath.maxOffset(scale: 4.5, fittedSize: fitted, containerSize: container)
        XCTAssertGreaterThan(exceeded.width, 0)
    }

    /// 巨大な offset を与えても画像がコンテナを覆い続ける（画面外へ飛ばない）。
    func test_clampedOffset_hugeInput_staysWithinBound() {
        let fitted = CGSize(width: 200, height: 200)
        let container = CGSize(width: 200, height: 200)
        let clamped = PreviewZoomMath.clampedOffset(CGSize(width: 1e9, height: -1e9), scale: 2,
                                                     fittedSize: fitted, containerSize: container)
        let bound = PreviewZoomMath.maxOffset(scale: 2, fittedSize: fitted, containerSize: container)
        XCTAssertEqual(clamped.width, bound.width)
        XCTAssertEqual(clamped.height, -bound.height)
    }

    func test_clampedOffset_nonFiniteInput_isZero() {
        let fitted = CGSize(width: 200, height: 200)
        let container = CGSize(width: 200, height: 200)
        let clamped = PreviewZoomMath.clampedOffset(CGSize(width: CGFloat.nan, height: .infinity), scale: 2,
                                                     fittedSize: fitted, containerSize: container)
        XCTAssertEqual(clamped.width, 0)
        XCTAssertEqual(clamped.height, 0)
    }

    // MARK: - アンカー保持

    /// 倍率 1→3 でアンカー位置の画像上の点の正規化座標が不変。
    func test_offsetKeepingAnchor_preservesImagePointAcrossScaleChange() {
        let anchor = CGSize(width: 30, height: -20) // コンテナ中心からの画面上の点。
        let oldScale: CGFloat = 1
        let previousOffset = CGSize.zero

        // 旧倍率でのアンカーの画像上の点（中心基準・fit 済み座標）。
        let imagePoint = CGSize(width: (anchor.width - previousOffset.width) / oldScale,
                                height: (anchor.height - previousOffset.height) / oldScale)

        let newScale: CGFloat = 3
        let rawOffset = PreviewZoomMath.offsetKeepingAnchor(previous: previousOffset, anchorFromCenter: anchor,
                                                             oldScale: oldScale, newScale: newScale)
        // newOffset + newScale * imagePoint == anchor が成り立つこと（往復の定義そのもの）。
        let reconstructed = CGSize(width: rawOffset.width + newScale * imagePoint.width,
                                   height: rawOffset.height + newScale * imagePoint.height)
        XCTAssertEqual(reconstructed.width, anchor.width, accuracy: 1e-9)
        XCTAssertEqual(reconstructed.height, anchor.height, accuracy: 1e-9)
    }

    func test_offsetKeepingAnchor_invalidOldScale_returnsPrevious() {
        let previous = CGSize(width: 5, height: 5)
        XCTAssertEqual(PreviewZoomMath.offsetKeepingAnchor(previous: previous, anchorFromCenter: .zero,
                                                            oldScale: 0, newScale: 2), previous)
        XCTAssertEqual(PreviewZoomMath.offsetKeepingAnchor(previous: previous, anchorFromCenter: .zero,
                                                            oldScale: -1, newScale: 2), previous)
        XCTAssertEqual(PreviewZoomMath.offsetKeepingAnchor(previous: previous, anchorFromCenter: .zero,
                                                            oldScale: .nan, newScale: 2), previous)
    }

    // MARK: - ダブルタップ

    func test_doubleTapped_fromIdentity_zoomsToThree() {
        let fitted = CGSize(width: 200, height: 200)
        let container = CGSize(width: 200, height: 200)
        let zoomed = PreviewZoomMath.doubleTapped(.identity, anchorFromCenter: .zero,
                                                  fittedSize: fitted, containerSize: container)
        XCTAssertEqual(zoomed.scale, 3)
    }

    /// ダブルタップの往復（1 → 3 → 1）。
    func test_doubleTapped_roundTrips() {
        let fitted = CGSize(width: 200, height: 200)
        let container = CGSize(width: 200, height: 200)
        let zoomed = PreviewZoomMath.doubleTapped(.identity, anchorFromCenter: CGSize(width: 10, height: 10),
                                                  fittedSize: fitted, containerSize: container)
        let restored = PreviewZoomMath.doubleTapped(zoomed, anchorFromCenter: CGSize(width: 10, height: 10),
                                                     fittedSize: fitted, containerSize: container)
        XCTAssertEqual(restored, .identity)
    }

    /// 中途半端な倍率（ピンチ由来）からのダブルタップも、常に等倍へ戻す側になる。
    func test_doubleTapped_fromNonIdentityNonThreeScale_returnsToIdentity() {
        let fitted = CGSize(width: 200, height: 200)
        let container = CGSize(width: 200, height: 200)
        let midway = PreviewZoom(scale: 5, offset: .zero)
        let result = PreviewZoomMath.doubleTapped(midway, anchorFromCenter: .zero,
                                                   fittedSize: fitted, containerSize: container)
        XCTAssertEqual(result, .identity)
    }

    // MARK: - ゼロ入力での破綻なし

    func test_maxOffset_withZeroSizes_doesNotBreak() {
        let bound = PreviewZoomMath.maxOffset(scale: 4, fittedSize: .zero, containerSize: .zero)
        XCTAssertEqual(bound, .zero)
    }

    func test_clampedOffset_withZeroSizes_isZero() {
        let clamped = PreviewZoomMath.clampedOffset(CGSize(width: 50, height: 50), scale: 4,
                                                     fittedSize: .zero, containerSize: .zero)
        XCTAssertEqual(clamped, .zero)
    }

    func test_doubleTapped_withZeroSizes_doesNotBreak() {
        let result = PreviewZoomMath.doubleTapped(.identity, anchorFromCenter: .zero,
                                                   fittedSize: .zero, containerSize: .zero)
        XCTAssertEqual(result.scale, 3)
        XCTAssertEqual(result.offset, .zero)
    }
}
