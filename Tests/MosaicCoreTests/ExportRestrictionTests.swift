import CoreGraphics
import XCTest
@testable import MosaicCore

final class ExportRestrictionTests: XCTestCase {
    private let hdResolution = CGSize(width: 1920, height: 1080)
    private let portraitHDResolution = CGSize(width: 1080, height: 1920)
    private let fourK = CGSize(width: 3840, height: 2160)

    // MARK: - Pro は常に無制限

    func test_pro_isAlwaysUnrestricted() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: true, durationSeconds: 3600, resolution: fourK),
            .none)
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: true, durationSeconds: 0, resolution: .zero),
            .none)
    }

    // MARK: - 尺の境界値（ちょうど60秒 / 60.1秒）

    func test_duration_exactlyAtLimit_isAllowed() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 60, resolution: hdResolution),
            .watermarkOnly)
    }

    func test_duration_justOverLimit_isBlocked() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 60.1, resolution: hdResolution),
            .exceedsDuration(limit: 60))
    }

    func test_duration_justUnderLimit_isAllowed() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 59.9, resolution: hdResolution),
            .watermarkOnly)
    }

    // MARK: - 解像度の境界値（短辺ちょうど1080 / 1081）

    func test_resolution_shortSideExactlyAtLimit_isAllowed() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10, resolution: hdResolution),
            .watermarkOnly)
        // 縦動画（短辺1080）も同様に許容。
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10, resolution: portraitHDResolution),
            .watermarkOnly)
    }

    func test_resolution_shortSideJustOverLimit_isDownscaled() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10,
                                           resolution: CGSize(width: 1921, height: 1081)),
            .exceedsResolution(limit: 1080))
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10,
                                           resolution: CGSize(width: 1081, height: 1921)),
            .exceedsResolution(limit: 1080))
    }

    func test_resolution_fourK_isDownscaled() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10, resolution: fourK),
            .exceedsResolution(limit: 1080))
    }

    // MARK: - 尺超過が解像度超過より優先される

    func test_durationExceeded_takesPriorityOverResolution() {
        // 尺・解像度の両方が超過していても、書き出しを止める判定（尺）が勝つ。
        // 「縮小すれば通る」と誤読させないため。
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 61, resolution: fourK),
            .exceedsDuration(limit: 60))
    }

    // MARK: - 範囲内は透かしのみ（無料なら常に）

    func test_withinLimits_stillGetsWatermark() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 1, resolution: CGSize(width: 4, height: 4)),
            .watermarkOnly)
    }

    // MARK: - 異常値は安全側（制限なし・書き出しを止めない）に倒す

    func test_nonFiniteDuration_isTreatedAsZero() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: .nan, resolution: hdResolution),
            .watermarkOnly)
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: -5, resolution: hdResolution),
            .watermarkOnly)
    }

    func test_zeroOrNonFiniteResolution_isTreatedAsWithinLimit() {
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10, resolution: .zero),
            .watermarkOnly)
        XCTAssertEqual(
            ExportRestrictionPolicy.decide(isPro: false, durationSeconds: 10,
                                           resolution: CGSize(width: CGFloat.nan, height: 1080)),
            .watermarkOnly)
    }

    // MARK: - clampedResolution: 縮小の純関数

    func test_clampedResolution_scalesDownPreservingAspect() {
        let clamped = ExportRestrictionPolicy.clampedResolution(fourK, shortSideLimit: 1080)
        // 3840x2160 -> 短辺 2160 を 1080 へ（scale=0.5）-> 1920x1080
        XCTAssertEqual(clamped, CGSize(width: 1920, height: 1080))
    }

    func test_clampedResolution_portraitPreservesAspect() {
        let clamped = ExportRestrictionPolicy.clampedResolution(
            CGSize(width: 2160, height: 3840), shortSideLimit: 1080)
        XCTAssertEqual(clamped, CGSize(width: 1080, height: 1920))
    }

    func test_clampedResolution_doesNotUpscale() {
        XCTAssertEqual(
            ExportRestrictionPolicy.clampedResolution(hdResolution, shortSideLimit: 1080),
            hdResolution)
        let small = CGSize(width: 640, height: 480)
        XCTAssertEqual(ExportRestrictionPolicy.clampedResolution(small, shortSideLimit: 1080), small)
    }

    func test_clampedResolution_resultIsEven() {
        // 3 の倍数など丸めが割り切れないサイズでも偶数に丸まること
        // （HEVC/H.264 は奇数サイズで扱いが崩れるため）。
        let clamped = ExportRestrictionPolicy.clampedResolution(
            CGSize(width: 3001, height: 2001), shortSideLimit: 1080)
        XCTAssertEqual(clamped.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(clamped.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func test_clampedResolution_handlesDegenerateInput() {
        XCTAssertEqual(ExportRestrictionPolicy.clampedResolution(.zero, shortSideLimit: 1080), .zero)
        let nanSize = CGSize(width: CGFloat.nan, height: 2000)
        let result = ExportRestrictionPolicy.clampedResolution(nanSize, shortSideLimit: 1080)
        XCTAssertTrue(result.width.isNaN, "NaN width should pass through unchanged")
        XCTAssertEqual(result.height, 2000)
    }

    // MARK: - needsWatermark（P2）: 4 ケース全部を固定する
    //
    // `.exceedsResolution` でも透かしを載せる（4K を縮小して書き出す無料ユーザーが
    // 透かし無しで書き出せてしまう穴を塞ぐ導出プロパティ）。`.exceedsDuration` は
    // 書き出し自体を止めるので false のままでよい。

    func test_needsWatermark_none_isFalse() {
        XCTAssertFalse(ExportRestriction.none.needsWatermark)
    }

    func test_needsWatermark_watermarkOnly_isTrue() {
        XCTAssertTrue(ExportRestriction.watermarkOnly.needsWatermark)
    }

    func test_needsWatermark_exceedsResolution_isTrue() {
        XCTAssertTrue(ExportRestriction.exceedsResolution(limit: 1080).needsWatermark)
    }

    func test_needsWatermark_exceedsDuration_isFalse() {
        XCTAssertFalse(ExportRestriction.exceedsDuration(limit: 60).needsWatermark)
    }
}
