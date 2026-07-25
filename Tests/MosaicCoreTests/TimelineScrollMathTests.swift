import XCTest
@testable import MosaicCore

/// S11: スクロール位置・可視範囲・連続ズームの算術。
///
/// 非有限値（NaN / inf）と退化入力（幅 0・コンテンツが可視幅以下・倍率 0 や負）で
/// **何が返るかを固定する**のがこのファイルの主目的。View 側はこの結果を
/// そのまま `ScrollViewReader` と frame へ流すため、NaN が 1 つ漏れると
/// スクロールが黙って無反応になる（クラッシュしないので気づけない）。
final class TimelineScrollMathTests: XCTestCase {
    private let geometry = TimelineGeometry(pixelsPerSecond: 40)

    // MARK: - TimelineViewport の正規化

    /// 非有限は 0、幅の負値は 0。スクロール位置の負は**残す**（先頭余白・ラバーバンド）。
    func test_viewport_sanitizesNonFiniteAndNegativeWidths() {
        let viewport = TimelineViewport(scrollOffset: .nan, visibleWidth: .infinity, contentWidth: -100)
        XCTAssertEqual(viewport.scrollOffset, 0)
        XCTAssertEqual(viewport.visibleWidth, 0)
        XCTAssertEqual(viewport.contentWidth, 0)

        let bounced = TimelineViewport(scrollOffset: -16, visibleWidth: 360, contentWidth: 1200)
        XCTAssertEqual(bounced.scrollOffset, -16)
        XCTAssertEqual(bounced.scrollableWidth, 840)

        // コンテンツが可視幅以下ならスクロール量 0（負にしない）。
        XCTAssertEqual(TimelineViewport(scrollOffset: 0, visibleWidth: 360, contentWidth: 100).scrollableWidth, 0)
    }

    // MARK: - 可視レンジ

    func test_visibleTimeRange_convertsBothEdges() {
        let viewport = TimelineViewport(scrollOffset: 400, visibleWidth: 360, contentWidth: 4000)
        let range = TimelineScrollMath.visibleTimeRange(viewport: viewport, geometry: geometry)
        XCTAssertEqual(range.lowerBound, 10, accuracy: 1e-12)
        XCTAssertEqual(range.upperBound, 19, accuracy: 1e-12)
    }

    /// 先頭余白が見えている間は下限が負のまま返る（0 に丸めない）。
    func test_visibleTimeRange_keepsNegativeLowerBound() {
        let viewport = TimelineViewport(scrollOffset: -16, visibleWidth: 360, contentWidth: 4000)
        let range = TimelineScrollMath.visibleTimeRange(viewport: viewport, geometry: geometry)
        XCTAssertEqual(range.lowerBound, -0.4, accuracy: 1e-12)
        XCTAssertEqual(range.upperBound, 8.6, accuracy: 1e-12)
    }

    /// 幅 0 でも空レンジとして成立する（ClosedRange の生成でクラッシュしない）。
    func test_visibleTimeRange_zeroWidthIsDegenerateRange() {
        let viewport = TimelineViewport(scrollOffset: 80, visibleWidth: 0, contentWidth: 0)
        let range = TimelineScrollMath.visibleTimeRange(viewport: viewport, geometry: geometry)
        XCTAssertEqual(range.lowerBound, 2, accuracy: 1e-12)
        XCTAssertEqual(range.upperBound, 2, accuracy: 1e-12)
    }

    // MARK: - ズームのアンカー

    /// プレイヘッドが可視ならそれをアンカーにする。
    func test_zoomAnchor_prefersVisiblePlayhead() {
        let viewport = TimelineViewport(scrollOffset: 400, visibleWidth: 360, contentWidth: 4000)
        let anchor = TimelineScrollMath.zoomAnchor(playheadTime: 12, viewport: viewport, geometry: geometry)
        XCTAssertEqual(anchor.time, 12, accuracy: 1e-12)
        // 12 秒 = 480px、可視左端 400px → 80px の位置。
        XCTAssertEqual(anchor.viewportX, 80, accuracy: 1e-12)
    }

    /// 可視外（および NaN）は可視中心へ落とす。
    func test_zoomAnchor_fallsBackToVisibleCenter() {
        let viewport = TimelineViewport(scrollOffset: 400, visibleWidth: 360, contentWidth: 4000)
        let outside = TimelineScrollMath.zoomAnchor(playheadTime: 40, viewport: viewport, geometry: geometry)
        XCTAssertEqual(outside.time, 14.5, accuracy: 1e-12)
        XCTAssertEqual(outside.viewportX, 180, accuracy: 1e-12)

        let nan = TimelineScrollMath.zoomAnchor(playheadTime: .nan, viewport: viewport, geometry: geometry)
        XCTAssertEqual(nan.time, 14.5, accuracy: 1e-12)
        XCTAssertEqual(nan.viewportX, 180, accuracy: 1e-12)
    }

    // MARK: - アンカー保持の往復

    /// ズーム後もアンカー時刻が同じ画面位置に留まること（本命の不変条件）。
    func test_scrollOffset_keepsAnchorAtSameViewportX() {
        let before = TimelineGeometry(pixelsPerSecond: 40)
        let viewport = TimelineViewport(scrollOffset: 400, visibleWidth: 360, contentWidth: 40 * 100)
        let anchor = TimelineScrollMath.zoomAnchor(playheadTime: 12, viewport: viewport, geometry: before)

        let after = TimelineGeometry(pixelsPerSecond: 80)
        let offset = TimelineScrollMath.scrollOffset(anchorTime: anchor.time,
                                                     anchorViewportX: anchor.viewportX,
                                                     geometry: after,
                                                     contentWidth: 80 * 100,
                                                     visibleWidth: 360)
        // 12 秒は 960px。画面上 80px に留めるなら左端は 880px。
        XCTAssertEqual(offset, 880, accuracy: 1e-12)
        let moved = TimelineViewport(scrollOffset: offset, visibleWidth: 360, contentWidth: 80 * 100)
        XCTAssertEqual(after.x(forTime: 12) - moved.scrollOffset, anchor.viewportX, accuracy: 1e-9)
    }

    /// 先頭余白ぶんの定数は「x 側」と「viewportX 側」の両辺に乗るので相殺される。
    /// （＝アンカー保持だけなら 16pt を無視しても結果が変わらない、の実証）。
    func test_scrollOffset_isInvariantToConstantInset() {
        let inset: Double = 16
        let before = TimelineGeometry(pixelsPerSecond: 40)
        let after = TimelineGeometry(pixelsPerSecond: 80)

        let plain = TimelineViewport(scrollOffset: 400, visibleWidth: 360, contentWidth: 4000)
        let shifted = TimelineViewport(scrollOffset: 400 + inset, visibleWidth: 360, contentWidth: 4000 + inset)
        let anchorA = TimelineScrollMath.zoomAnchor(playheadTime: 12, viewport: plain, geometry: before)
        // 余白ぶんずれた座標系では、時刻→x も同じだけずれる想定。
        let anchorBX = (before.x(forTime: 12) + inset) - shifted.scrollOffset
        XCTAssertEqual(anchorA.viewportX, anchorBX, accuracy: 1e-12)

        let offsetA = TimelineScrollMath.scrollOffset(anchorTime: 12, anchorViewportX: anchorA.viewportX,
                                                      geometry: after, contentWidth: 8000, visibleWidth: 360)
        let offsetB = TimelineScrollMath.scrollOffset(anchorTime: 12, anchorViewportX: anchorBX,
                                                      geometry: after, contentWidth: 8000, visibleWidth: 360)
        XCTAssertEqual(offsetA, offsetB, accuracy: 1e-12)
    }

    /// 範囲外へ出るアンカーはスクロール可能域へクランプされる。
    func test_scrollOffset_clampsToScrollableRange() {
        // 先頭付近: 負にならない。
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: 0.5, anchorViewportX: 180,
                                                       geometry: geometry, contentWidth: 4000,
                                                       visibleWidth: 360), 0, accuracy: 1e-12)
        // 末尾付近: contentWidth - visibleWidth で止まる。
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: 100, anchorViewportX: 0,
                                                       geometry: geometry, contentWidth: 4000,
                                                       visibleWidth: 360), 3640, accuracy: 1e-12)
        // スクロール不要な短いコンテンツでは常に 0。
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: 5, anchorViewportX: 0,
                                                       geometry: geometry, contentWidth: 100,
                                                       visibleWidth: 360), 0, accuracy: 1e-12)
    }

    /// 非有限は 0（NaN をスクロール位置に流さない）。
    func test_scrollOffset_nonFiniteInputsCollapseToZero() {
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: .nan, anchorViewportX: 80,
                                                       geometry: geometry, contentWidth: 4000,
                                                       visibleWidth: 360), 0)
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: 12, anchorViewportX: .nan,
                                                       geometry: geometry, contentWidth: 4000,
                                                       visibleWidth: 360), 480)
        XCTAssertEqual(TimelineScrollMath.scrollOffset(anchorTime: 12, anchorViewportX: 80,
                                                       geometry: geometry, contentWidth: .nan,
                                                       visibleWidth: .infinity), 0)
    }

    // MARK: - UnitPoint.x

    func test_anchorUnitPointX_mapsOffsetToFraction() {
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 0, contentWidth: 1000,
                                                           visibleWidth: 200), 0, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 400, contentWidth: 1000,
                                                           visibleWidth: 200), 0.5, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 800, contentWidth: 1000,
                                                           visibleWidth: 200), 1, accuracy: 1e-12)
    }

    /// クランプと退化入力。スクロール不要・非有限は 0。
    func test_anchorUnitPointX_degenerateInputs() {
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: -50, contentWidth: 1000,
                                                           visibleWidth: 200), 0)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 5000, contentWidth: 1000,
                                                           visibleWidth: 200), 1)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 100, contentWidth: 200,
                                                           visibleWidth: 200), 0)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 100, contentWidth: 100,
                                                           visibleWidth: 200), 0)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: .nan, contentWidth: 1000,
                                                           visibleWidth: 200), 0)
        XCTAssertEqual(TimelineScrollMath.anchorUnitPointX(scrollOffset: 100, contentWidth: .infinity,
                                                           visibleWidth: 200), 0)
    }

    // MARK: - ピンチ倍率 → px/秒

    /// 等倍は base そのまま（ジェスチャ開始で値が跳ばない）。
    func test_pixelsPerSecond_identityMagnificationKeepsBase() {
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 37.5, magnification: 1), 37.5, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1), 40, accuracy: 1e-12)
    }

    /// 量子化: 6% 未満のブレは吸収し、越えたら 1 段動く（連続値であって段ではない）。
    func test_pixelsPerSecond_quantizesMagnification() {
        let quantum = TimelineScrollMath.defaultZoomQuantumRatio
        // 1.02 は半量子未満 → 動かない。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1.02), 40, accuracy: 1e-12)
        // 1.06 はちょうど 1 段。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: quantum),
                       40 * quantum, accuracy: 1e-9)
        // 1.13 ≒ 2 段（1.06^2 = 1.1236）。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1.13),
                       40 * quantum * quantum, accuracy: 1e-9)
        // 縮小側も対称。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1 / quantum),
                       40 / quantum, accuracy: 1e-9)
        // 量子化しない指定では素の積。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1.02, quantumRatio: 1),
                       40.8, accuracy: 1e-12)
    }

    /// `zoomLevels` の範囲外は端で止まり、段には吸着しない（連続値を保つ）。
    func test_pixelsPerSecond_clampsToGeometryRange() {
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 160, magnification: 4),
                       TimelineGeometry.maximumPixelsPerSecond, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 10, magnification: 0.25),
                       TimelineGeometry.minimumPixelsPerSecond, accuracy: 1e-12)
        // 段の中間値がそのまま出る（zoomLevels へ吸着していないことの確認）。
        let continuous = TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1.5)
        XCTAssertFalse(TimelineGeometry.zoomLevels.contains { abs($0 - continuous) < 1e-9 })
        XCTAssertGreaterThan(continuous, 40)
        XCTAssertLessThan(continuous, 80)
    }

    /// 壊れた倍率は等倍扱い。オーバーフローは既定段に落とさず上下端へ寄せる。
    func test_pixelsPerSecond_nonFiniteAndNonPositiveMagnification() {
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 55, magnification: .nan), 55, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 55, magnification: 0), 55, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 55, magnification: -2), 55, accuracy: 1e-12)
        // base が壊れていれば TimelineGeometry と同じく既定段から始める（倍率は効く）。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: .nan, magnification: 2),
                       TimelineScrollMath.pixelsPerSecond(base: TimelineGeometry.defaultPixelsPerSecond,
                                                          magnification: 2),
                       accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: .nan, magnification: 1),
                       TimelineGeometry.defaultPixelsPerSecond, accuracy: 1e-12)
        // inf も「壊れた倍率」として等倍扱い（base を返す。既定段 40 ではない）。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 55, magnification: .infinity), 55, accuracy: 1e-12)
        // 有限だがオーバーフローする倍率は、既定段に落とさず拡大側の端へ寄せる。
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1e300),
                       TimelineGeometry.maximumPixelsPerSecond, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.pixelsPerSecond(base: 40, magnification: 1e-300),
                       TimelineGeometry.minimumPixelsPerSecond, accuracy: 1e-12)
    }

    // MARK: - 自動スクロール

    func test_autoScrollVelocity_rampsLinearlyAtEdges() {
        let width: Double = 360
        let inset: Double = 60
        let speed: Double = 600
        func velocity(_ x: Double) -> Double {
            TimelineScrollMath.autoScrollVelocity(fingerX: x, visibleWidth: width,
                                                  edgeInset: inset, maximumSpeed: speed)
        }
        XCTAssertEqual(velocity(180), 0, accuracy: 1e-12)      // 中央
        XCTAssertEqual(velocity(60), 0, accuracy: 1e-12)       // 帯の境界
        XCTAssertEqual(velocity(30), -300, accuracy: 1e-12)    // 左半分
        XCTAssertEqual(velocity(0), -600, accuracy: 1e-12)     // 左端
        XCTAssertEqual(velocity(330), 300, accuracy: 1e-12)    // 右半分
        XCTAssertEqual(velocity(360), 600, accuracy: 1e-12)    // 右端
        // 画面外へ出ても最大速度で頭打ち。
        XCTAssertEqual(velocity(-500), -600, accuracy: 1e-12)
        XCTAssertEqual(velocity(900), 600, accuracy: 1e-12)
    }

    /// 帯が重なる狭い画面でも中央では止まる（`edgeInset` を幅の半分に詰める）。
    func test_autoScrollVelocity_narrowViewportDoesNotOverlapZones() {
        let value = TimelineScrollMath.autoScrollVelocity(fingerX: 40, visibleWidth: 80,
                                                          edgeInset: 60, maximumSpeed: 600)
        XCTAssertEqual(value, 0, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: 0, visibleWidth: 80,
                                                             edgeInset: 60, maximumSpeed: 600),
                       -600, accuracy: 1e-12)
    }

    /// 退化入力はすべて 0（自動スクロールしない）。
    func test_autoScrollVelocity_degenerateInputsAreZero() {
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: .nan, visibleWidth: 360,
                                                             edgeInset: 60, maximumSpeed: 600), 0)
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: 10, visibleWidth: 0,
                                                             edgeInset: 60, maximumSpeed: 600), 0)
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: 10, visibleWidth: 360,
                                                             edgeInset: 0, maximumSpeed: 600), 0)
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: 10, visibleWidth: 360,
                                                             edgeInset: 60, maximumSpeed: 0), 0)
        XCTAssertEqual(TimelineScrollMath.autoScrollVelocity(fingerX: 10, visibleWidth: 360,
                                                             edgeInset: 60, maximumSpeed: .infinity), 0)
    }
}
