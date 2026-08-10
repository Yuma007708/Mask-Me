import XCTest
@testable import MosaicCore

/// S12: トリム下書き中の**表示専用**リップル（`TimelineTrimPreview.swift`）と、
/// 吸着 → クランプの合成順序を固定する。
///
/// ここで固定するのは「モデルを変えずに表示だけを先送りする」写像なので、
/// 入力の `layouts` / `spans` が書き換わらないこと（純関数であること）も含めて見る。
final class TimelineTrimPreviewTests: XCTestCase {
    private func clip(start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: UUID(), sourceStart: start, sourceEnd: end, rate: rate)
    }

    /// 2 秒 × 3 本（継ぎ目なし）の帯レイアウト。
    private func threeClipLayouts() -> [TimelineClipLayout] {
        let clips = [clip(start: 0, end: 2), clip(start: 0, end: 2), clip(start: 0, end: 2)]
        return TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: clips))
    }

    /// 帯が「接するが重ならない」ことを確認する（隙間も重なりも許さない）。
    private func assertContiguous(_ layouts: [TimelineClipLayout],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for (previous, next) in zip(layouts, layouts.dropFirst()) {
            XCTAssertEqual(previous.bandEnd, next.bandStart, accuracy: 1e-12,
                           "帯 \(previous.index)→\(next.index) に隙間または重なりがある",
                           file: file, line: line)
        }
    }

    // MARK: - previewLayouts

    /// `.end` 側を外向きに伸ばすと、掴んだ帯の右端と**以降の全クリップ**が同量動く。
    /// 掴んだクリップより前は不変で、帯は接したまま。
    func test_previewLayouts_endEdgeRipplesFollowingClips() {
        let layouts = threeClipLayouts()
        let snapshot = layouts
        let preview = TimelineBandLayout.previewLayouts(layouts: layouts,
                                                        trimmingClipID: layouts[1].clipID,
                                                        edge: .end,
                                                        effectiveDeltaSeconds: 0.5)
        XCTAssertEqual(preview[0], layouts[0], "掴んだクリップより前が動いている")
        XCTAssertEqual(preview[1].bandStart, 2, accuracy: 1e-12, "掴んだ帯の左端が動いている")
        XCTAssertEqual(preview[1].bandEnd, 4.5, accuracy: 1e-12)
        XCTAssertEqual(preview[2].bandStart, 4.5, accuracy: 1e-12)
        XCTAssertEqual(preview[2].bandEnd, 6.5, accuracy: 1e-12)
        assertContiguous(preview)
        XCTAssertEqual(layouts, snapshot, "入力を書き換えている")
    }

    /// `.start` 側は「正 = 内向き」なので、帯は**縮み**後続は左へ寄る。
    func test_previewLayouts_startEdgeShrinksBandAndPullsFollowingClips() {
        let layouts = threeClipLayouts()
        let preview = TimelineBandLayout.previewLayouts(layouts: layouts,
                                                        trimmingClipID: layouts[0].clipID,
                                                        edge: .start,
                                                        effectiveDeltaSeconds: 0.5)
        XCTAssertEqual(preview[0].bandStart, 0, accuracy: 1e-12, "start トリムでも左端は動かさない")
        XCTAssertEqual(preview[0].bandEnd, 1.5, accuracy: 1e-12)
        XCTAssertEqual(preview[1].bandStart, 1.5, accuracy: 1e-12)
        XCTAssertEqual(preview[2].bandEnd, 5.5, accuracy: 1e-12)
        assertContiguous(preview)
    }

    /// `.start` を外向き（負の実効差分）に伸ばすと帯は伸び、後続は右へ寄る。
    func test_previewLayouts_startEdgeOutwardGrowsBand() {
        let layouts = threeClipLayouts()
        let preview = TimelineBandLayout.previewLayouts(layouts: layouts,
                                                        trimmingClipID: layouts[1].clipID,
                                                        edge: .start,
                                                        effectiveDeltaSeconds: -1)
        XCTAssertEqual(preview[1].bandStart, 2, accuracy: 1e-12)
        XCTAssertEqual(preview[1].bandEnd, 5, accuracy: 1e-12)
        XCTAssertEqual(preview[2].bandStart, 5, accuracy: 1e-12)
        assertContiguous(preview)
    }

    /// 差分 0・非有限・未知の clipID はいずれも恒等（表示が勝手に動かない）。
    func test_previewLayouts_identityCases() {
        let layouts = threeClipLayouts()
        for edge in TimelineTrimEdge.allCases {
            XCTAssertEqual(TimelineBandLayout.previewLayouts(layouts: layouts,
                                                             trimmingClipID: layouts[1].clipID,
                                                             edge: edge, effectiveDeltaSeconds: 0),
                           layouts, "delta 0 で恒等でない（\(edge)）")
            for value in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(TimelineBandLayout.previewLayouts(layouts: layouts,
                                                                 trimmingClipID: layouts[1].clipID,
                                                                 edge: edge, effectiveDeltaSeconds: value),
                               layouts, "非有限の差分でレイアウトが壊れている（\(edge)）")
            }
        }
        XCTAssertEqual(TimelineBandLayout.previewLayouts(layouts: layouts, trimmingClipID: UUID(),
                                                         edge: .end, effectiveDeltaSeconds: 1),
                       layouts, "未知の clipID で全体が動いている")
    }

    /// トランジションで重なった帯（`bandStart > spanStart`）でも接触は保たれる。
    func test_previewLayouts_keepsContiguityWithTransition() {
        let clips = [clip(start: 0, end: 2), clip(start: 0, end: 2), clip(start: 0, end: 2)]
        let mapping = TimelineMapping(clips: clips,
                                      transitions: [clips[0].id: TransitionSpec(kind: .crossfade, duration: 0.5)])
        let layouts = TimelineBandLayout.clipLayouts(mapping: mapping)
        XCTAssertGreaterThan(layouts[1].bandStart, layouts[1].spanStart, "前提: 重なりで帯が食い込む")
        for edge in TimelineTrimEdge.allCases {
            for delta in [-0.4, 0.4] {
                assertContiguous(TimelineBandLayout.previewLayouts(layouts: layouts,
                                                                   trimmingClipID: layouts[1].clipID,
                                                                   edge: edge, effectiveDeltaSeconds: delta))
            }
        }
    }

    // MARK: - previewApplySpans

    /// 後続クリップのスパンだけが帯と同量シフトする（前は不変）。
    func test_previewApplySpans_shiftsOnlyFollowingClips() {
        let layouts = threeClipLayouts()
        let spans = layouts.map { layout in
            TimelineApplySpan(rangeID: UUID(), clipID: layout.clipID, kind: .mosaic,
                              start: layout.bandStart + 0.5, end: layout.bandEnd - 0.5)
        }
        let preview = TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                           trimmingClipID: layouts[1].clipID,
                                                           edge: .end, effectiveDeltaSeconds: 0.5)
        XCTAssertEqual(preview[0], spans[0], "掴んだクリップより前のスパンが動いている")
        XCTAssertEqual(preview[1].start, spans[1].start, accuracy: 1e-12, ".end では中身は動かない")
        XCTAssertEqual(preview[1].end, spans[1].end, accuracy: 1e-12)
        XCTAssertEqual(preview[2].start, spans[2].start + 0.5, accuracy: 1e-12)
        XCTAssertEqual(preview[2].end, spans[2].end + 0.5, accuracy: 1e-12)
    }

    /// `.start` では掴んだクリップの中身も一緒に流れ、プレビュー帯の外へは出ない
    /// （帯だけ動いて区間が置いていかれる／トリムで消える領域に区間が残る、を防ぐ）。
    func test_previewApplySpans_startEdgeMovesGrabbedClipContentAndClamps() {
        let layouts = threeClipLayouts()
        let rangeID = UUID()
        let spans = [TimelineApplySpan(rangeID: rangeID, clipID: layouts[1].clipID, kind: .mosaic, start: 2, end: 4)]
        let preview = TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                           trimmingClipID: layouts[1].clipID,
                                                           edge: .start, effectiveDeltaSeconds: 0.5)
        // 帯は [2, 3.5) へ縮み、中身は 0.5 秒ぶん左へ流れる（先頭は帯の左端で止まる）。
        XCTAssertEqual(preview[0].start, 2, accuracy: 1e-12)
        XCTAssertEqual(preview[0].end, 3.5, accuracy: 1e-12)
    }

    /// `.end` を内向きに縮めたとき、掴んだクリップのスパンはプレビュー帯の右端で止まる。
    func test_previewApplySpans_endEdgeClampsGrabbedClipToPreviewBand() {
        let layouts = threeClipLayouts()
        let spans = [TimelineApplySpan(rangeID: UUID(), clipID: layouts[1].clipID, kind: .mosaic, start: 2.2, end: 4)]
        let preview = TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                           trimmingClipID: layouts[1].clipID,
                                                           edge: .end, effectiveDeltaSeconds: -0.8)
        XCTAssertEqual(preview[0].start, 2.2, accuracy: 1e-12)
        XCTAssertEqual(preview[0].end, 3.2, accuracy: 1e-12, "縮んだ帯の外へ区間がはみ出している")
    }

    /// `layouts` に載っていない clipID のスパン・差分 0 は素通し。
    func test_previewApplySpans_identityCases() {
        let layouts = threeClipLayouts()
        let stranger = TimelineApplySpan(rangeID: UUID(), clipID: UUID(), kind: .mosaic, start: 0, end: 1)
        let spans = [stranger]
        XCTAssertEqual(TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                            trimmingClipID: layouts[0].clipID,
                                                            edge: .end, effectiveDeltaSeconds: 1),
                       spans, "未知の clipID のスパンを動かしている")
        XCTAssertEqual(TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                            trimmingClipID: layouts[0].clipID,
                                                            edge: .end, effectiveDeltaSeconds: 0),
                       spans)
    }

    /// `isEdgeAdjustable`（写真クリップのハンドル抑止）はシフトで失われない。
    func test_previewApplySpans_preservesEdgeAdjustableFlag() {
        let layouts = threeClipLayouts()
        let spans = [TimelineApplySpan(rangeID: UUID(), clipID: layouts[2].clipID, kind: .mosaic,
                                       start: 4.2, end: 5.8, isEdgeAdjustable: false)]
        let preview = TimelineBandLayout.previewApplySpans(spans: spans, layouts: layouts,
                                                           trimmingClipID: layouts[0].clipID,
                                                           edge: .end, effectiveDeltaSeconds: 0.5)
        XCTAssertFalse(preview[0].isEdgeAdjustable)
        XCTAssertEqual(preview[0].start, 4.7, accuracy: 1e-12)
    }

    // MARK: - .start 外向きトリムのサムネイル素材時刻

    /// `.start` を外向きに伸ばしたプレビューでは、帯に出るコマが
    /// **現行 `sourceStart` より前**の素材から単調増加で並ぶこと。
    ///
    /// `.start` のプレビューは `band.start` を動かさず右端だけ伸ばすので、未編集の
    /// `clip` と `spanStart: layout.spanStart` を渡すと `bandOffset` が 0 のままになり、
    /// 帯には現行 `sourceStart` から**先**のコマが並ぶ（確定後に入るのはそれより前の素材）。
    /// 下書き適用済みクリップ + `spanStart: band.start` でこの食い違いが消える。
    /// `.end` 側の対（`test_thumbnailSlots_sourceDurationAllowsFramesBeyondClipEnd`）と対称。
    func test_thumbnailSlots_startEdgeOutwardTrimUsesEarlierSource() {
        let target = clip(start: 4, end: 6)
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        let bounds = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                      deltaCompositionSeconds: -1, sourceDuration: 10)
        XCTAssertEqual(bounds.sourceStart, 3, accuracy: 1e-12, "前提: 素材 1 秒ぶん手前へ伸びる")
        // 帯は左端据え置きで右端が 1 秒伸びる（`previewShift` の符号どおり）。
        let band = CompositionInterval(start: 0, end: 3)

        let naive = TimelineThumbnailLayout.slots(clip: target, spanStart: 0, band: band,
                                                  geometry: geometry, preferredSlotWidth: 20,
                                                  sourceDuration: 10)
        XCTAssertGreaterThanOrEqual(naive.sourceTimes[0], 4,
                                    "前提の確認: 未編集クリップでは伸ばした領域が sourceStart より先を指す")

        var preview = target
        preview.sourceStart = bounds.sourceStart
        preview.sourceEnd = bounds.sourceEnd
        let slots = TimelineThumbnailLayout.slots(clip: preview, spanStart: band.start, band: band,
                                                  geometry: geometry, preferredSlotWidth: 20,
                                                  sourceDuration: 10)
        XCTAssertLessThan(slots.sourceTimes[0], 4, "確定後に足される手前の素材が帯に出ていない")
        XCTAssertGreaterThanOrEqual(slots.sourceTimes[0], 3)
        for (previous, next) in zip(slots.sourceTimes, slots.sourceTimes.dropFirst()) {
            XCTAssertLessThan(previous, next, "素材時刻が単調増加でない")
        }
        XCTAssertLessThan(slots.sourceTimes[slots.count - 1], 6, "使用範囲の外のコマを引いている")
    }

    // MARK: - 吸着 → クランプの合成

    /// View が組む「端の絶対時刻 → 吸着 → 差分 → `trimmedBounds`」の順で、
    /// 最小合成尺を割らないこと。**逆順（クランプ → 吸着）にすると割る。**
    func test_snapThenClamp_inTrimDeltaForm_keepsMinimumDuration() {
        let target = clip(start: 0, end: 2)
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        let tolerance = geometry.duration(forWidth: TimelineSnap.defaultTolerancePixels)
        let bandEnd = 2.0
        // 帯の右端を最小尺の内側（0.05 秒）へ引き込む候補（他クリップの端・プレイヘッド等）。
        let candidates = [0.05]

        let snapped = TimelineSnap.snapped(time: bandEnd + (-1.96), candidates: candidates, tolerance: tolerance)
        XCTAssertEqual(snapped.snappedTo, 0.05)
        let bounds = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                      deltaCompositionSeconds: snapped.time - bandEnd,
                                                      sourceDuration: 10)
        XCTAssertEqual(bounds.sourceEnd - bounds.sourceStart,
                       TimelineEditOperations.minimumClipDuration, accuracy: 1e-12,
                       "吸着 → クランプで最小尺を割っている")

        // 逆順（クランプ → 吸着）は最小尺を割る。
        let clampedFirst = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                            deltaCompositionSeconds: -1.96,
                                                            sourceDuration: 10)
        let reversed = TimelineSnap.snapped(time: clampedFirst.sourceEnd, candidates: candidates,
                                            tolerance: tolerance)
        XCTAssertLessThan(reversed.time - clampedFirst.sourceStart,
                          TimelineEditOperations.minimumClipDuration,
                          "前提の確認: 逆順なら最小尺を割るはず")
    }

    /// 吸着の許容量は px 由来（ズームしても指の感覚が一定）。
    func test_snapTolerance_isDerivedFromPixels() {
        let coarse = TimelineGeometry(pixelsPerSecond: 10)
        let fine = TimelineGeometry(pixelsPerSecond: 160)
        let coarseTolerance = coarse.duration(forWidth: TimelineSnap.defaultTolerancePixels)
        let fineTolerance = fine.duration(forWidth: TimelineSnap.defaultTolerancePixels)
        XCTAssertGreaterThan(coarseTolerance, fineTolerance)
        XCTAssertEqual(coarse.width(forDuration: coarseTolerance),
                       fine.width(forDuration: fineTolerance), accuracy: 1e-12,
                       "px 換算の許容量がズーム段で変わっている")
    }
}
