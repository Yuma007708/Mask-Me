import XCTest
@testable import MosaicCore

final class TimelineLayerScrollMathTests: XCTestCase {

    private let spacing = 4.0
    /// モザイク・音声・テキストの 3 段（各 28pt）。
    private let rows = [28.0, 28.0, 28.0]

    private func viewport(visible: Double) -> TimelineLayerViewport {
        TimelineLayerViewport(
            contentHeight: TimelineLayerScrollMath.contentHeight(rowHeights: rows, spacing: spacing),
            visibleHeight: visible)
    }

    // MARK: - 高さの合計

    /// 間隔は段の**間**にだけ入る。末尾に付けると、可視高ちょうどでも
    /// 数 px スクロールできてしまい一番下の段が揺れる。
    func test_contentHeight_putsSpacingOnlyBetweenRows() {
        XCTAssertEqual(TimelineLayerScrollMath.contentHeight(rowHeights: rows, spacing: spacing),
                       28 * 3 + 4 * 2, accuracy: 1e-9)
        XCTAssertEqual(TimelineLayerScrollMath.contentHeight(rowHeights: [28], spacing: spacing),
                       28, accuracy: 1e-9)
        XCTAssertEqual(TimelineLayerScrollMath.contentHeight(rowHeights: [], spacing: spacing), 0)
    }

    /// 壊れた高さ（0・負・非有限）は無視する。段の高さは定数から来るが、
    /// 将来 UI 側で可変にしたときに NaN を frame へ流さないため。
    func test_contentHeight_ignoresBrokenRows() {
        let heights = [28.0, 0, -5, .nan, 28.0]
        XCTAssertEqual(TimelineLayerScrollMath.contentHeight(rowHeights: heights, spacing: spacing),
                       28 * 2 + 4, accuracy: 1e-9)
    }

    // MARK: - クランプ

    func test_clampedOffset_staysInsideRange() {
        let vp = viewport(visible: 60)                  // 92 - 60 = 32 が上限
        XCTAssertEqual(vp.maximumOffset, 32, accuracy: 1e-9)
        XCTAssertEqual(TimelineLayerScrollMath.clampedOffset(-20, viewport: vp), 0)
        XCTAssertEqual(TimelineLayerScrollMath.clampedOffset(10, viewport: vp), 10)
        XCTAssertEqual(TimelineLayerScrollMath.clampedOffset(999, viewport: vp), 32)
        XCTAssertEqual(TimelineLayerScrollMath.clampedOffset(.nan, viewport: vp), 0)
    }

    /// 段が可視高に収まるならスクロールしない（0 に固定）。
    func test_clampedOffset_isPinnedWhenEverythingFits() {
        let vp = viewport(visible: 200)
        XCTAssertEqual(vp.maximumOffset, 0)
        XCTAssertFalse(vp.isScrollable)
        XCTAssertEqual(TimelineLayerScrollMath.clampedOffset(50, viewport: vp), 0)
    }

    // MARK: - 段を見せる

    /// 下へはみ出している段は、**その段の下端が可視域の下端に来る**ところまで送る
    /// （行き過ぎない。送りすぎると上の段が理由なく隠れる）。
    func test_offsetToReveal_scrollsDownJustEnough() {
        let vp = viewport(visible: 60)
        let offset = TimelineLayerScrollMath.offsetToReveal(
            rowIndex: 2, rowHeights: rows, spacing: spacing, currentOffset: 0, viewport: vp)
        // 3 段目の下端 = 92、可視 60 → 32
        XCTAssertEqual(offset, 32, accuracy: 1e-9)
    }

    /// 上へはみ出している段は、その段の上端まで戻す。
    func test_offsetToReveal_scrollsUpToRowTop() {
        let vp = viewport(visible: 60)
        let offset = TimelineLayerScrollMath.offsetToReveal(
            rowIndex: 0, rowHeights: rows, spacing: spacing, currentOffset: 32, viewport: vp)
        XCTAssertEqual(offset, 0, accuracy: 1e-9)
    }

    /// **既に見えている段では動かさない。** 段をタップするたびに一覧が
    /// 微妙に動くと、狙った段を押し続けられない。
    func test_offsetToReveal_leavesVisibleRowAlone() {
        let vp = viewport(visible: 60)
        let offset = TimelineLayerScrollMath.offsetToReveal(
            rowIndex: 1, rowHeights: rows, spacing: spacing, currentOffset: 10, viewport: vp)
        XCTAssertEqual(offset, 10, accuracy: 1e-9)
    }

    /// 範囲外の添字では現在値を丸めて返すだけ（段の削除と行き違っても壊れない）。
    func test_offsetToReveal_toleratesOutOfRangeIndex() {
        let vp = viewport(visible: 60)
        XCTAssertEqual(TimelineLayerScrollMath.offsetToReveal(
            rowIndex: 99, rowHeights: rows, spacing: spacing, currentOffset: 999, viewport: vp), 32)
    }
}
