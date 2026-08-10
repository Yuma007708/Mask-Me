import XCTest
@testable import MosaicCore

/// `TimelineItemDrag`（`TimelineApplyTrackView.snappedDraft` から抜き出した純ロジック）。
///
/// 端の伸縮（`.edge`）と本体移動（`.move`）を同じ関数で扱う。移動は
/// 「先頭優先で吸着 → シフト量を決定 → [0, totalDuration-length] へクランプ →
/// さらに掴んだクリップの帯へクランプ」という順序が要（`TimelineItemDrag.swift` の doc 参照）。
final class TimelineItemDragTests: XCTestCase {
    private func makeSpan(rangeID: UUID = UUID(), clipID: UUID = UUID(),
                          start: Double, end: Double, isEdgeAdjustable: Bool = true) -> TimelineApplySpan {
        TimelineApplySpan(rangeID: rangeID, clipID: clipID, kind: .mosaic, start: start, end: end,
                          isEdgeAdjustable: isEdgeAdjustable)
    }

    /// トランジションが無いクリップの並び（帯 = 合成区間）。
    private func makeLayout(clipID: UUID, bandStart: Double, bandEnd: Double) -> TimelineClipLayout {
        TimelineClipLayout(clipID: clipID, sourceID: UUID(), index: 0,
                           spanStart: bandStart, spanEnd: bandEnd,
                           bandStart: bandStart, bandEnd: bandEnd)
    }

    /// トランジションがある後続クリップ。`bandStart = 重なりの終わり` で
    /// **`spanStart` より右**になる（`TimelineBandLayout.clipLayouts`）。
    private func makeOverlappedLayout(clipID: UUID, spanStart: Double, spanEnd: Double,
                                      overlap: Double) -> TimelineClipLayout {
        TimelineClipLayout(clipID: clipID, sourceID: UUID(), index: 1,
                           spanStart: spanStart, spanEnd: spanEnd,
                           bandStart: spanStart + overlap, bandEnd: spanEnd)
    }

    private func makeContext(geometry: TimelineGeometry,
                             layouts: [TimelineClipLayout] = [],
                             applySpans: [TimelineApplySpan] = [],
                             playheadTime: Double = -1,
                             totalDuration: Double) -> TimelineItemDragContext {
        TimelineItemDragContext(geometry: geometry, layouts: layouts, applySpans: applySpans,
                                playheadTime: playheadTime, totalDuration: totalDuration)
    }

    // MARK: 1. 端ドラッグ: 吸着 → クランプの順序で最小尺を割らない

    /// 吸着候補が最小尺の内側（0.06 秒）にあっても、クランプが後に効いて
    /// 結果は最小尺（既定 0.1 秒）を割らない。`TimelineSnapTests.test_snapThenClamp_keepsMinimumDuration`
    /// と同じ数値設定（吸着 0.06 / クランプ下限 0.1）を移植した。
    func test_edgeDrag_snapsThenClamps_keepsMinimumSpan() {
        let span = makeSpan(start: 0, end: 5)
        // pixelsPerSecond は `TimelineGeometry.zoomLevels` の範囲内でなければ既定段へ
        // クランプされる（`TimelineGeometry.clampedPixelsPerSecond`）ため、最大段 160 を使う。
        // tolerance(12px) = 12/160 = 0.075 秒。
        let geometry = TimelineGeometry(pixelsPerSecond: 160)
        // end を 5 → 0.08 秒へドラッグする delta（吸着候補 0.06 まで距離 0.02 ≦ tolerance）。
        let delta = 0.08 - 5.0
        let translationPixels = delta * 160
        let context = makeContext(geometry: geometry, applySpans: [span], playheadTime: 0.06, totalDuration: 10)

        let result = TimelineItemDrag.snappedDraft(span: span, kind: .edge(.end),
                                                    translationPixels: translationPixels, context: context)

        // 吸着自体は 0.06 に当たる。
        XCTAssertEqual(result.snappedTo ?? -1, 0.06, accuracy: 1e-9)
        // しかしクランプ（start + minimumSpan = 0.1）が後に効き、最小尺を割らない。
        XCTAssertEqual(result.end, 0.1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result.end - result.start, TimelineItemDrag.defaultMinimumSpan - 1e-12)
    }

    // MARK: 2. 移動: 両端が同じ量だけシフトする

    /// 任意の translation で `end - start` が入力と bit 一致する（長さが変わらない）。
    func test_move_shiftsBothEdgesByEqualAmount() {
        let clipID = UUID()
        let span = makeSpan(clipID: clipID, start: 2, end: 5)
        let band = makeLayout(clipID: clipID, bandStart: 0, bandEnd: 1_000)
        let geometry = TimelineGeometry(pixelsPerSecond: 10)
        let context = makeContext(geometry: geometry, layouts: [band], applySpans: [span], totalDuration: 10_000)
        let originalLength = span.end - span.start

        for translationPixels: Double in [17, -3, 0, 250] {
            let result = TimelineItemDrag.snappedDraft(span: span, kind: .move,
                                                        translationPixels: translationPixels, context: context)
            XCTAssertEqual(result.end - result.start, originalLength,
                           "translation=\(translationPixels) で長さが変わった")
        }
    }

    // MARK: 3. 移動: クリップ帯へクランプする

    /// 帯の外へ引っ張っても `bandStart` / `bandEnd` で止まり、長さは保たれる。
    func test_move_clampsToClipBand() {
        let clipID = UUID()
        let span = makeSpan(clipID: clipID, start: 2, end: 5)
        let band = makeLayout(clipID: clipID, bandStart: 0, bandEnd: 10)
        let geometry = TimelineGeometry(pixelsPerSecond: 10)
        let context = makeContext(geometry: geometry, layouts: [band], applySpans: [span], totalDuration: 100)

        // 帯の右端を大きく超える方向へ。
        let overRight = TimelineItemDrag.snappedDraft(span: span, kind: .move,
                                                       translationPixels: 10_000, context: context)
        XCTAssertEqual(overRight.start, 7, accuracy: 1e-9)   // bandEnd(10) - length(3)
        XCTAssertEqual(overRight.end, 10, accuracy: 1e-9)    // bandEnd
        XCTAssertEqual(overRight.end - overRight.start, 3, accuracy: 1e-9)

        // 帯の左端を大きく超える方向へ。
        let overLeft = TimelineItemDrag.snappedDraft(span: span, kind: .move,
                                                      translationPixels: -10_000, context: context)
        XCTAssertEqual(overLeft.start, 0, accuracy: 1e-9)    // bandStart
        XCTAssertEqual(overLeft.end, 3, accuracy: 1e-9)
        XCTAssertEqual(overLeft.end - overLeft.start, 3, accuracy: 1e-9)
    }

    /// **可動域は「表示用の帯」ではなくクリップの合成区間で決まる。**
    ///
    /// トランジションのある後続クリップでは `bandStart = spanStart + 重なり長` になる
    /// （`TimelineBandLayout.clipLayouts`）。ここで帯を可動域に使うと、確定側
    /// （`MosaicApplyGate.ranges(movingRangeID:)` は `span.start` / `span.end` で
    /// クランプする）と食い違い、**掴んで動かせるのに指を離すと元へ戻る**。
    ///
    /// この 1 本を落とすには、`TimelineItemDrag` の `band.spanStart` を
    /// `band.bandStart` に戻すだけでよい（＝この穴を実際に踏む）。
    func test_move_clampsToCompositionSpan_notToDisplayBand() {
        let clipID = UUID()
        // クリップの合成区間 [10, 20)、先頭 2 秒が前のクリップとの重なり。
        let span = makeSpan(clipID: clipID, start: 12, end: 15)
        let layout = makeOverlappedLayout(clipID: clipID, spanStart: 10, spanEnd: 20, overlap: 2)
        let geometry = TimelineGeometry(pixelsPerSecond: 10)
        let context = makeContext(geometry: geometry, layouts: [layout], applySpans: [span],
                                  totalDuration: 100)

        // 左へ大きく引く。帯で止めると 12（= bandStart）だが、正しくは合成区間の頭 10。
        let overLeft = TimelineItemDrag.snappedDraft(span: span, kind: .move,
                                                     translationPixels: -10_000, context: context)
        XCTAssertEqual(overLeft.start, 10, accuracy: 1e-9,
                       "重なり区間へ入れない（表示用の帯を可動域に使っている）")
        XCTAssertEqual(overLeft.end, 13, accuracy: 1e-9)
        XCTAssertEqual(overLeft.end - overLeft.start, 3, accuracy: 1e-9)
    }

    // MARK: 4. 移動: 吸着候補から自分自身の両端を外す

    /// 掴んだ区間自身の両端（`applySpans` に自分を渡しても）は候補から外れる。
    /// delta = 0 なら「自分の start へ吸着」が起きるはずの位置だが、除外されていれば
    /// 他に候補が無い限り吸着しない。
    func test_move_snapCandidateExcludesSelf() {
        let clipID = UUID()
        let span = makeSpan(clipID: clipID, start: 2, end: 5)
        let band = makeLayout(clipID: clipID, bandStart: 0, bandEnd: 1_000)
        let geometry = TimelineGeometry(pixelsPerSecond: 10)
        let context = makeContext(geometry: geometry, layouts: [band], applySpans: [span], totalDuration: 100)

        // delta = 0: 補正前の start(2) / end(5) がちょうど自分の両端と一致する。
        // 候補から自分の両端が外れていれば、他候補（0・totalDuration）は遠すぎて吸着しない。
        let result = TimelineItemDrag.snappedDraft(span: span, kind: .move,
                                                    translationPixels: 0, context: context)

        XCTAssertNil(result.snappedTo, "掴んだ区間自身の端に吸着してしまっている")
        XCTAssertEqual(result.start, 2, accuracy: 1e-9)
        XCTAssertEqual(result.end, 5, accuracy: 1e-9)
    }

    // MARK: 5. 写真クリップ: 伸縮も移動も no-op

    /// `isEdgeAdjustable == false` の入力は、伸縮も移動も入力そのまま（no-op）を返す。
    func test_drag_photoSpan_isNoOp() {
        let clipID = UUID()
        let span = makeSpan(clipID: clipID, start: 2, end: 5, isEdgeAdjustable: false)
        let band = makeLayout(clipID: clipID, bandStart: 0, bandEnd: 10)
        let geometry = TimelineGeometry(pixelsPerSecond: 10)
        let context = makeContext(geometry: geometry, layouts: [band], applySpans: [span],
                                  playheadTime: 1, totalDuration: 100)

        for kind: TimelineItemDragKind in [.edge(.start), .edge(.end), .move] {
            let result = TimelineItemDrag.snappedDraft(span: span, kind: kind,
                                                        translationPixels: 250, context: context)
            XCTAssertEqual(result.start, span.start, "kind=\(kind) で start が変わった")
            XCTAssertEqual(result.end, span.end, "kind=\(kind) で end が変わった")
            XCTAssertNil(result.snappedTo, "kind=\(kind) で吸着が発生した")
        }
    }
}
