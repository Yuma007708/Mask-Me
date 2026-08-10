import XCTest
@testable import MosaicCore

/// S9: タイムライン UI の座標変換・配置計算（`TimelineViewGeometry.swift`）の契約を固定する。
///
/// View に生の算術を書かせないため、px⇔秒・帯の配置・適用区間の逆写像・
/// トリム量の換算・速度スライダーの対数スケールはすべてここで固定する。
final class TimelineViewGeometryTests: XCTestCase {
    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }

    // MARK: - px ⇔ 秒

    func test_pixelsPerSecond_isClampedToZoomLevelRange() {
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 1).pixelsPerSecond,
                       TimelineGeometry.minimumPixelsPerSecond)
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 10_000).pixelsPerSecond,
                       TimelineGeometry.maximumPixelsPerSecond)
        XCTAssertEqual(TimelineGeometry().pixelsPerSecond, TimelineGeometry.defaultPixelsPerSecond)
    }

    /// NaN / 無限は既定段へ落ちる（min/max を素通りしてレイアウト全体を NaN 汚染しない）。
    func test_nonFinitePixelsPerSecond_fallsBackToDefault() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(TimelineGeometry(pixelsPerSecond: value).pixelsPerSecond,
                           TimelineGeometry.defaultPixelsPerSecond)
        }
    }

    /// x(forTime:) と time(forX:) は互いの逆写像（負値も含む）。
    func test_timeAndXAreInverse() {
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        XCTAssertEqual(geometry.x(forTime: 2.5), 100, accuracy: 1e-12)
        XCTAssertEqual(geometry.time(forX: 100), 2.5, accuracy: 1e-12)
        XCTAssertEqual(geometry.time(forX: geometry.x(forTime: -1.25)), -1.25, accuracy: 1e-12)
    }

    /// width / duration は負値を 0 に落とす（SwiftUI の frame に負の幅を渡さない）。
    func test_widthAndDurationClampNegativeToZero() {
        let geometry = TimelineGeometry(pixelsPerSecond: 20)
        XCTAssertEqual(geometry.width(forDuration: -3), 0)
        XCTAssertEqual(geometry.width(forDuration: .nan), 0)
        XCTAssertEqual(geometry.duration(forWidth: -80), 0)
        XCTAssertEqual(geometry.width(forDuration: 3), 60, accuracy: 1e-12)
        XCTAssertEqual(geometry.duration(forWidth: 60), 3, accuracy: 1e-12)
    }

    func test_zoomStepsStayInsideLevels() {
        var geometry = TimelineGeometry(pixelsPerSecond: TimelineGeometry.minimumPixelsPerSecond)
        XCTAssertEqual(geometry.zoomedOut(), geometry, "最小段では変化しない")
        geometry = geometry.zoomedIn()
        XCTAssertEqual(geometry.pixelsPerSecond, TimelineGeometry.zoomLevels[1])
        let maximum = TimelineGeometry(pixelsPerSecond: TimelineGeometry.maximumPixelsPerSecond)
        XCTAssertEqual(maximum.zoomedIn(), maximum, "最大段では変化しない")
        XCTAssertEqual(maximum.zoomedOut().pixelsPerSecond,
                       TimelineGeometry.zoomLevels[TimelineGeometry.zoomLevels.count - 2])
    }

    /// 目盛り間隔はラベルが重ならない最小の候補（px 換算 >= minimumTickSpacing）。
    func test_tickInterval_growsAsZoomShrinks() {
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 160).tickInterval, 0.5)
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 40).tickInterval, 1)
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 20).tickInterval, 2)
        XCTAssertEqual(TimelineGeometry(pixelsPerSecond: 10).tickInterval, 5)
        for level in TimelineGeometry.zoomLevels {
            let geometry = TimelineGeometry(pixelsPerSecond: level)
            XCTAssertGreaterThanOrEqual(geometry.tickInterval * level,
                                        TimelineGeometry.minimumTickSpacing)
        }
    }

    /// 実効間隔は本数を maximumTicks 以下に抑える（長尺 × 高倍率でビューが爆発しない）。
    func test_effectiveTickInterval_capsTickCount() {
        let geometry = TimelineGeometry(pixelsPerSecond: 160)   // tickInterval = 0.5
        XCTAssertEqual(geometry.effectiveTickInterval(totalDuration: 60), 0.5, "短尺では素の間隔")
        let long = geometry.effectiveTickInterval(totalDuration: 3600)
        XCTAssertLessThanOrEqual(3600 / long, Double(TimelineGeometry.maximumTicks))
        XCTAssertGreaterThan(long, geometry.tickInterval)
        // 尺 0・非有限では素の間隔（0 除算・無限ループを起こさない）
        XCTAssertEqual(geometry.effectiveTickInterval(totalDuration: 0), geometry.tickInterval)
        XCTAssertEqual(geometry.effectiveTickInterval(totalDuration: .nan), geometry.tickInterval)
        XCTAssertEqual(geometry.effectiveTickInterval(totalDuration: .infinity), geometry.tickInterval)
    }

    // MARK: - サムネイル枠

    /// 枠は帯をちょうど埋め、各枠の中心が素材時刻へ写ること。
    func test_thumbnailSlots_fillBandAndMapCenters() {
        let target = clip(start: 10, end: 20)
        let geometry = TimelineGeometry(pixelsPerSecond: 40)   // 10 秒 = 400px
        let slots = TimelineThumbnailLayout.slots(clip: target, spanStart: 0,
                                                  band: CompositionInterval(start: 0, end: 10),
                                                  geometry: geometry, preferredSlotWidth: 40)

        XCTAssertEqual(slots.count, 10)
        XCTAssertEqual(slots.slotWidth, 40, accuracy: 1e-12)
        XCTAssertEqual(Double(slots.count) * slots.slotWidth, 400, accuracy: 1e-9, "帯をちょうど埋める")
        XCTAssertEqual(slots.sourceTimes.count, 10)
        XCTAssertEqual(slots.sourceTimes[0], 10.5, accuracy: 1e-9, "先頭枠の中心 = 素材 10.5 秒")
        XCTAssertEqual(slots.sourceTimes[9], 19.5, accuracy: 1e-9)
    }

    /// rate と帯オフセット（トランジションで削られた先頭）が反映されること。
    func test_thumbnailSlots_appliesRateAndBandOffset() {
        let target = clip(start: 0, end: 20, rate: 2)   // 合成尺 10 秒
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        // 先頭 2 秒が重なりで削られた帯 [2, 10)（span は [0, 10)）。
        let slots = TimelineThumbnailLayout.slots(clip: target, spanStart: 0,
                                                  band: CompositionInterval(start: 2, end: 10),
                                                  geometry: geometry, preferredSlotWidth: 80)

        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots.sourceTimes[0], (2 + 1) * 2, accuracy: 1e-9,
                       "帯オフセット 2 秒 + 枠中心 1 秒 → 素材 6 秒（rate 2）")
    }

    /// 枠数は上限で打ち切られ、そのぶん枠が広がる（帯は埋まったまま）。
    func test_thumbnailSlots_capsCountAndWidensSlots() {
        let target = clip(start: 0, end: 600)
        let geometry = TimelineGeometry(pixelsPerSecond: 160)
        let slots = TimelineThumbnailLayout.slots(clip: target, spanStart: 0,
                                                  band: CompositionInterval(start: 0, end: 600),
                                                  geometry: geometry, preferredSlotWidth: 44)

        XCTAssertEqual(slots.count, TimelineThumbnailLayout.maximumSlotsPerClip)
        XCTAssertEqual(Double(slots.count) * slots.slotWidth,
                       geometry.width(forDuration: 600), accuracy: 1e-6)
        XCTAssertGreaterThan(slots.slotWidth, 44)
    }

    /// 素材時刻は使用範囲内（半開区間）へクランプされる。幅 0 でも 1 枠は返る。
    func test_thumbnailSlots_clampsAndNeverReturnsZeroSlots() {
        let target = clip(start: 5, end: 6)
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        let degenerate = TimelineThumbnailLayout.slots(clip: target, spanStart: 0,
                                                       band: CompositionInterval(start: 0, end: 0),
                                                       geometry: geometry, preferredSlotWidth: 44)
        XCTAssertEqual(degenerate.count, 1)
        XCTAssertGreaterThanOrEqual(degenerate.sourceTimes[0], 5)
        XCTAssertLessThan(degenerate.sourceTimes[0], 6)

        let overshoot = TimelineThumbnailLayout.slots(clip: target, spanStart: 0,
                                                      band: CompositionInterval(start: 5, end: 6),
                                                      geometry: geometry, preferredSlotWidth: 44)
        for time in overshoot.sourceTimes {
            XCTAssertGreaterThanOrEqual(time, 5)
            XCTAssertLessThan(time, 6, "sourceEnd ちょうど（半開区間の外）を返してはいけない")
        }
    }

    /// 外向きトリムのプレビュー（帯が現行の合成区間より長い）では、素材実尺まで
    /// 先のコマを引けること。上限を `sourceEnd` に固定すると伸ばした領域の枠が
    /// 全部同じコマ（現行 `sourceEnd`）に張り付く。
    func test_thumbnailSlots_sourceDurationAllowsFramesBeyondClipEnd() {
        let target = clip(start: 0, end: 2)
        let geometry = TimelineGeometry(pixelsPerSecond: 40)
        // 帯を 3 秒に伸ばしたプレビュー（span は [0,2)）。
        let band = CompositionInterval(start: 0, end: 3)

        let clamped = TimelineThumbnailLayout.slots(clip: target, spanStart: 0, band: band,
                                                    geometry: geometry, preferredSlotWidth: 20)
        XCTAssertEqual(Set(clamped.sourceTimes).count < clamped.count, true,
                       "上限固定では伸ばした領域が同一コマに張り付く（前提の確認）")

        let extended = TimelineThumbnailLayout.slots(clip: target, spanStart: 0, band: band,
                                                     geometry: geometry, preferredSlotWidth: 20,
                                                     sourceDuration: 10)
        XCTAssertEqual(Set(extended.sourceTimes).count, extended.count,
                       "素材実尺を渡しても同一コマが残っている")
        XCTAssertGreaterThan(extended.sourceTimes.last ?? 0, 2.0, "sourceEnd より先のコマを引けていない")
        for time in extended.sourceTimes { XCTAssertLessThan(time, 10) }
    }

}

/// S9: 帯・継ぎ目・適用区間・トリム・並べ替えの配置計算。
///
/// 新規テストクラスに分けているのは `type_body_length`（300 行）に収めるためで、
/// 対象は同じ `TimelineViewGeometry.swift`。
final class TimelineBandLayoutTests: XCTestCase {
    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }

    // MARK: - クリップ帯の配置

    /// トランジションなし: 帯はクリップ区間そのままで、隙間なく連続する。
    func test_clipLayouts_withoutTransitions_areContiguous() {
        let clips = [clip(start: 0, end: 4), clip(start: 0, end: 6), clip(start: 0, end: 2, rate: 2)]
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: clips))

        XCTAssertEqual(layouts.count, 3)
        XCTAssertEqual(layouts.map(\.index), [0, 1, 2])
        XCTAssertEqual(layouts[0].bandStart, 0, accuracy: 1e-12)
        XCTAssertEqual(layouts[0].bandEnd, 4, accuracy: 1e-12)
        XCTAssertEqual(layouts[1].bandStart, 4, accuracy: 1e-12)
        XCTAssertEqual(layouts[1].bandEnd, 10, accuracy: 1e-12)
        // rate 2 のクリップは合成尺 1 秒
        XCTAssertEqual(layouts[2].bandEnd, 11, accuracy: 1e-12)
        for layout in layouts {
            XCTAssertEqual(layout.bandStart, layout.spanStart, accuracy: 1e-12)
            XCTAssertEqual(layout.bandEnd, layout.spanEnd, accuracy: 1e-12)
        }
    }

    /// トランジションあり: 重なりは先行クリップの帯が占有し、後続の帯は重なり終了から始まる。
    /// 帯どうしは接するが重ならない。
    func test_clipLayouts_withTransition_bandsTouchWithoutOverlapping() {
        let first = clip(start: 0, end: 4)
        let second = clip(start: 0, end: 6)
        let mapping = TimelineMapping(clips: [first, second],
                                      transitions: [first.id: TransitionSpec(kind: .crossfade, duration: 1)])
        let layouts = TimelineBandLayout.clipLayouts(mapping: mapping)

        XCTAssertEqual(layouts[0].bandStart, 0, accuracy: 1e-12)
        XCTAssertEqual(layouts[0].bandEnd, 4, accuracy: 1e-12)
        XCTAssertEqual(layouts[1].spanStart, 3, accuracy: 1e-12, "後続クリップは 1 秒前倒しで重なる")
        XCTAssertEqual(layouts[1].bandStart, 4, accuracy: 1e-12, "帯は重なり終了（= 先行の終端）から")
        XCTAssertEqual(layouts[1].bandEnd, 9, accuracy: 1e-12)
        XCTAssertEqual(layouts[0].bandEnd, layouts[1].bandStart, "帯は接する")
        XCTAssertGreaterThan(layouts[1].bandDuration, 0)
    }

    func test_clipLayouts_emptyAndSingle() {
        XCTAssertTrue(TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: [])).isEmpty)
        let single = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: [clip(start: 1, end: 3)]))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].bandStart, 0, accuracy: 1e-12)
        XCTAssertEqual(single[0].bandEnd, 2, accuracy: 1e-12)
    }

    // MARK: - 継ぎ目の配置

    func test_jointLayouts_countAndPlacement() {
        let first = clip(start: 0, end: 4)
        let second = clip(start: 0, end: 6)
        let third = clip(start: 0, end: 6)
        let mapping = TimelineMapping(clips: [first, second, third],
                                      transitions: [first.id: TransitionSpec(kind: .wipeLeft, duration: 2)])
        let joints = TimelineBandLayout.jointLayouts(mapping: mapping)

        XCTAssertEqual(joints.count, 2, "クリップ N 本なら継ぎ目は N-1")
        XCTAssertEqual(joints[0].outgoingClipID, first.id)
        XCTAssertEqual(joints[0].incomingClipID, second.id)
        XCTAssertEqual(joints[0].kind, .wipeLeft)
        XCTAssertEqual(joints[0].duration, 2, accuracy: 1e-12)
        XCTAssertEqual(joints[0].time, 3, accuracy: 1e-12, "重なり [2,4) の中心")
        XCTAssertNil(joints[1].kind, "未設定の継ぎ目は kind = nil")
        XCTAssertEqual(joints[1].duration, 0)
        XCTAssertEqual(joints[1].time, 8, accuracy: 1e-12, "クリップ境界そのまま")
    }

    func test_jointLayouts_singleClipHasNoJoint() {
        XCTAssertTrue(TimelineBandLayout.jointLayouts(mapping: TimelineMapping(clips: [clip(start: 0, end: 3)])).isEmpty)
        XCTAssertTrue(TimelineBandLayout.jointLayouts(mapping: TimelineMapping(clips: [])).isEmpty)
    }

    // MARK: - 適用区間の逆写像

    /// 素材アンカーの適用区間 → 合成時刻の区間。`MosaicApplyGate` の追加操作と往復すること。
    func test_applySpans_isInverseOfAddingCompositionInterval() {
        let source = UUID()
        let clips = [clip(source: source, start: 0, end: 5), clip(source: source, start: 5, end: 10)]
        let mapping = TimelineMapping(clips: clips)
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 7,
                                            mapping: mapping, existing: [])
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: [])

        // S11: clipID アンカーなのでクリップごとに 1 本ずつ（＝1 区間 1 セグメント。不変条件 I2）。
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(Set(spans.map(\.rangeID)).count, 2, "1 区間が複数セグメントに写っている")
        XCTAssertEqual(spans[0].start, 2, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(spans[1].start, 5, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 7, accuracy: 1e-9)
        XCTAssertEqual(spans[0].anchorClipID, clips[0].id)
        XCTAssertEqual(spans[1].anchorClipID, clips[1].id)
    }

    /// rate ≠ 1 のクリップでは素材尺を rate で割った合成区間になる。
    func test_applySpans_dividesBySourceRate() {
        let source = UUID()
        let scaled = clip(source: source, start: 0, end: 8, rate: 2)
        let mapping = TimelineMapping(clips: [scaled])
        let ranges = [MosaicApplyRange(clipID: scaled.id, sourceID: source, sourceStart: 2, sourceEnd: 6)]
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: [])

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, 1, accuracy: 1e-12)
        XCTAssertEqual(spans[0].end, 3, accuracy: 1e-12)
        XCTAssertTrue(spans[0].isEdgeAdjustable, "動画クリップは端ドラッグ可")
    }

    /// 別素材・別クリップ・使用範囲外の区間は表示に現れない。
    func test_applySpans_skipsNonOverlappingRanges() {
        let used = UUID()
        let target = clip(source: used, start: 2, end: 4)
        let mapping = TimelineMapping(clips: [target])
        let ranges = [
            // 別素材
            MosaicApplyRange(clipID: target.id, sourceID: UUID(), sourceStart: 2, sourceEnd: 4),
            // 別クリップ（S11: clipID アンカー）
            MosaicApplyRange(clipID: UUID(), sourceID: used, sourceStart: 2, sourceEnd: 4),
            // 使用範囲外
            MosaicApplyRange(clipID: target.id, sourceID: used, sourceStart: 5, sourceEnd: 6),
            // 壊れた区間
            MosaicApplyRange(clipID: target.id, sourceID: used, sourceStart: .nan, sourceEnd: 3)
        ]
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: []).isEmpty)
    }

    /// 写真素材のセグメントは端ドラッグ不可としてマークされること（UI がハンドルを出さない）。
    ///
    /// 写真の素材時刻は常に 0 へ丸められ、区間が必ずクリップ全体になるため
    /// `MosaicApplyGate.ranges(replacingRangeID:clipID:...)` が必ず `existing` を返す
    /// （＝端ドラッグが構造的に no-op）。
    func test_applySpans_marksPhotoSpansAsNotEdgeAdjustable() {
        let photoSource = UUID()
        let photo = clip(source: photoSource, start: 0, end: 3)
        let video = clip(source: UUID(), start: 0, end: 3)
        let mapping = TimelineMapping(clips: [photo, video])
        let ranges = MosaicApplyGate.fullCoverRanges(for: [photo, video], photoSourceIDs: [])
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping,
                                                  photoSourceIDs: [photoSource])
        XCTAssertEqual(spans.count, 2)
        XCTAssertFalse(spans[0].isEdgeAdjustable, "写真クリップにハンドルが出てしまう")
        XCTAssertTrue(spans[1].isEdgeAdjustable)
        // 写真素材を渡さなければ（動画だけの構成では）全部 true。
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: [])
            .allSatisfy(\.isEdgeAdjustable))
    }

    // MARK: - トリム量の換算

    func test_trimmedBounds_startEdgeMovesSourceStartByRate() {
        let target = clip(start: 1, end: 9, rate: 2)
        let result = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                      deltaCompositionSeconds: 1,
                                                      sourceDuration: 20)
        XCTAssertEqual(result.sourceStart, 3, accuracy: 1e-12, "合成 1 秒 = 素材 2 秒（rate 2）")
        XCTAssertEqual(result.sourceEnd, 9, accuracy: 1e-12)
    }

    /// start 側は 0 と「最小合成尺を残す上限」でクランプされる。
    func test_trimmedBounds_startEdgeClamps() {
        let target = clip(start: 1, end: 3)
        let tooFarLeft = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                          deltaCompositionSeconds: -100,
                                                          sourceDuration: 10)
        XCTAssertEqual(tooFarLeft.sourceStart, 0, accuracy: 1e-12)
        let tooFarRight = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                           deltaCompositionSeconds: 100,
                                                           sourceDuration: 10)
        XCTAssertEqual(tooFarRight.sourceStart,
                       3 - TimelineEditOperations.minimumClipDuration, accuracy: 1e-12)
        XCTAssertLessThan(tooFarRight.sourceStart, tooFarRight.sourceEnd)
    }

    /// end 側は素材尺と「最小合成尺を残す下限」でクランプされる。
    func test_trimmedBounds_endEdgeClampsToSourceDuration() {
        let target = clip(start: 1, end: 3)
        let tooFarRight = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                           deltaCompositionSeconds: 100,
                                                           sourceDuration: 7.5)
        XCTAssertEqual(tooFarRight.sourceEnd, 7.5, accuracy: 1e-12)
        let tooFarLeft = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                          deltaCompositionSeconds: -100,
                                                          sourceDuration: 7.5)
        XCTAssertEqual(tooFarLeft.sourceEnd,
                       1 + TimelineEditOperations.minimumClipDuration, accuracy: 1e-12)
    }

    /// 素材尺が不明（nil）なら end 側の上限は掛からない（コア層の有限性ガードに委ねる）。
    func test_trimmedBounds_withoutSourceDuration_hasNoUpperClamp() {
        let result = TimelineBandLayout.trimmedBounds(clip: clip(start: 0, end: 2), edge: .end,
                                                      deltaCompositionSeconds: 5,
                                                      sourceDuration: nil)
        XCTAssertEqual(result.sourceEnd, 7, accuracy: 1e-12)
    }

    /// 合成尺が最小尺を割ったクリップ（速度シート由来）では start 側の端トリムを拒否すること。
    ///
    /// 旧実装は上限（`sourceEnd - 最小素材尺`）が現在の `sourceStart` より小さくなるのに
    /// `min` を掛けていたため、**ドラッグと逆方向へ 0.5 秒伸びて前クリップと重複**した
    /// （10s 素材を 9.5s で分割 → 後半を 10x → 合成尺 0.05s のクリップ）。
    func test_trimmedBounds_rejectsStartTrimWhenSpanBelowMinimum() {
        let target = clip(start: 9.5, end: 10, rate: 10)   // 合成尺 0.05 < 0.1
        for delta in [0.025, -0.01, 0.001, 1.0] {
            let result = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                          deltaCompositionSeconds: delta,
                                                          sourceDuration: 10)
            XCTAssertEqual(result.sourceStart, 9.5, accuracy: 1e-12,
                           "尺不足クリップの左ハンドルが動いている（delta=\(delta)）")
            XCTAssertEqual(result.sourceEnd, 10, accuracy: 1e-12)
        }
    }

    /// 素材末尾に張り付いたクリップ（最小尺を残せない）では end 側の端トリムを拒否すること。
    /// 旧実装は素材尺クランプの**後**に下限を掛けていたため素材尺を突き抜けていた。
    func test_trimmedBounds_rejectsEndTrimWhenSourceExhausted() {
        let target = clip(start: 9.5, end: 10.5, rate: 10)   // 下限 10.5 > 素材尺 10
        for delta in [0.5, 0.05, -0.02] {
            let result = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                          deltaCompositionSeconds: delta,
                                                          sourceDuration: 10)
            XCTAssertEqual(result.sourceStart, 9.5, accuracy: 1e-12)
            XCTAssertEqual(result.sourceEnd, 10.5, accuracy: 1e-12,
                           "拒否せず素材尺を突き抜けている（delta=\(delta)）")
        }
    }

    /// end 側のクランプ順序: 素材尺の上限が下限より優先されず、素材尺を超えないこと。
    func test_trimmedBounds_endEdgeNeverExceedsSourceDuration() {
        let target = clip(start: 9, end: 9.5)
        let result = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                      deltaCompositionSeconds: 5,
                                                      sourceDuration: 10)
        XCTAssertEqual(result.sourceEnd, 10, accuracy: 1e-12)
    }

    /// NaN のドラッグ量は元の範囲をそのまま返す（ジェスチャの異常値で範囲を壊さない）。
    func test_trimmedBounds_nonFiniteDeltaIsIgnored() {
        let target = clip(start: 1, end: 4)
        for edge in TimelineTrimEdge.allCases {
            let result = TimelineBandLayout.trimmedBounds(clip: target, edge: edge,
                                                          deltaCompositionSeconds: .nan,
                                                          sourceDuration: 10)
            XCTAssertEqual(result.sourceStart, 1, accuracy: 1e-12)
            XCTAssertEqual(result.sourceEnd, 4, accuracy: 1e-12)
        }
    }

    // MARK: - 並べ替えの着地 index

    func test_reorderTargetIndex_followsBandCenter() {
        let clips = [clip(start: 0, end: 2), clip(start: 0, end: 2), clip(start: 0, end: 2)]
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: clips))

        XCTAssertEqual(TimelineBandLayout.reorderTargetIndex(layouts: layouts,
                                                             clipID: clips[0].id,
                                                             translationSeconds: 0), 0)
        XCTAssertEqual(TimelineBandLayout.reorderTargetIndex(layouts: layouts,
                                                             clipID: clips[0].id,
                                                             translationSeconds: 2), 1,
                       "帯 1 本ぶん右へ動かすと index 1")
        XCTAssertEqual(TimelineBandLayout.reorderTargetIndex(layouts: layouts,
                                                             clipID: clips[0].id,
                                                             translationSeconds: 100), 2,
                       "右端をはみ出したら末尾")
        XCTAssertEqual(TimelineBandLayout.reorderTargetIndex(layouts: layouts,
                                                             clipID: clips[2].id,
                                                             translationSeconds: -100), 0,
                       "左端をはみ出したら先頭")
    }

    func test_reorderTargetIndex_unknownClipOrNaNIsNil() {
        let clips = [clip(start: 0, end: 2), clip(start: 0, end: 2)]
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: clips))
        XCTAssertNil(TimelineBandLayout.reorderTargetIndex(layouts: layouts, clipID: UUID(),
                                                           translationSeconds: 1))
        XCTAssertNil(TimelineBandLayout.reorderTargetIndex(layouts: layouts, clipID: clips[0].id,
                                                           translationSeconds: .nan))
        XCTAssertNil(TimelineBandLayout.reorderTargetIndex(layouts: [], clipID: clips[0].id,
                                                           translationSeconds: 1))
    }

}
