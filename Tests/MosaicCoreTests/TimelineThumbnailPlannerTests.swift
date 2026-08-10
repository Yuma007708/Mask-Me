import XCTest
@testable import MosaicCore

/// S11: サムネイル生成要求の計画（`TimelineScrollMath.swift` の `TimelineThumbnailPlanner`）。
///
/// 固定したい契約は 2 つ。
/// 1. **素材時刻が `TimelineThumbnailLayout.slots` と 1 ビットも違わない**こと
///    （要求キーと描画キーがずれると、生成済みでも帯が灰色のままになる）。
/// 2. **件数の上限をここで掛けない**こと（キャッシュ済みを除外する前に切ると
///    先頭クリップが予算を食い切り、後続クリップが永久に要求されない）。
final class TimelineThumbnailPlannerTests: XCTestCase {
    private let geometry = TimelineGeometry(pixelsPerSecond: 40)
    private let slotWidth: Double = 44

    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }

    /// rate ≠ 1 とクロスフェードを含む構成（帯の開始が spanStart とずれる）。
    private func fixture() -> (clips: [TimelineClip], layouts: [TimelineClipLayout]) {
        let first = clip(start: 0, end: 6, rate: 1)       // 合成尺 6
        let second = clip(start: 2, end: 12, rate: 2)     // 合成尺 5
        let third = clip(start: 0, end: 4, rate: 0.5)     // 合成尺 8
        let clips = [first, second, third]
        let mapping = TimelineMapping(clips: clips,
                                      transitions: [first.id: TransitionSpec(kind: .crossfade, duration: 1)])
        return (clips, TimelineBandLayout.clipLayouts(mapping: mapping))
    }

    // MARK: - 描画側との一致

    /// 計画された素材時刻が `TimelineThumbnailLayout.slots` と完全一致すること
    /// （rate ≠ 1・トランジションで帯がずれている構成で確認する）。
    func test_plan_sourceTimesMatchThumbnailLayoutSlots() {
        let (clips, layouts) = fixture()
        // 帯の開始が spanStart とずれている（＝ bandOffset が効く）構成であることの確認。
        XCTAssertNotEqual(layouts[1].bandStart, layouts[1].spanStart)
        XCTAssertEqual(layouts[1].spanDuration, 5, accuracy: 1e-12)

        let requests = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                     visibleRange: 0...100, marginFactor: 0,
                                                     preferredSlotWidth: slotWidth,
                                                     sourceDurations: [:])
        for layout in layouts {
            guard let clip = clips.first(where: { $0.id == layout.clipID }) else { return XCTFail("clip 欠落") }
            let slots = TimelineThumbnailLayout.slots(
                clip: clip, spanStart: layout.spanStart,
                band: CompositionInterval(start: layout.bandStart, end: layout.bandEnd),
                geometry: geometry, preferredSlotWidth: slotWidth)
            let planned = requests.filter { $0.clipID == layout.clipID }
                .map(\.sourceTime).sorted()
            XCTAssertEqual(planned.count, slots.count, "枠数が描画側と一致しない")
            for (actual, expected) in zip(planned, slots.sourceTimes.sorted()) {
                XCTAssertEqual(actual, expected, accuracy: 0, "素材時刻が描画側とずれた")
            }
        }
    }

    /// `sourceDuration` を渡すと、外向きトリムのプレビューで先のコマを引ける
    /// （渡さない場合との差が出ることを固定する）。
    func test_plan_usesSourceDurationCeiling() {
        let source = UUID()
        let target = clip(source: source, start: 0, end: 4)
        let mapping = TimelineMapping(clips: [target])
        var layouts = TimelineBandLayout.clipLayouts(mapping: mapping)
        // 外向きトリム中の帯（現行の合成区間より右へ伸びている）を模す。
        layouts = [TimelineClipLayout(clipID: target.id, sourceID: source, index: 0,
                                      spanStart: 0, spanEnd: 4, bandStart: 0, bandEnd: 8)]

        let withoutDuration = TimelineThumbnailPlanner.plan(layouts: layouts, clips: [target], geometry: geometry,
                                                            visibleRange: 0...100, marginFactor: 0,
                                                            preferredSlotWidth: slotWidth, sourceDurations: [:])
        let withDuration = TimelineThumbnailPlanner.plan(layouts: layouts, clips: [target], geometry: geometry,
                                                         visibleRange: 0...100, marginFactor: 0,
                                                         preferredSlotWidth: slotWidth,
                                                         sourceDurations: [source: 20])
        XCTAssertEqual(withoutDuration.map(\.sourceTime).max()!, 4.0.nextDown, accuracy: 1e-12)
        XCTAssertGreaterThan(withDuration.map(\.sourceTime).max()!, 4)
    }

    // MARK: - 可視範囲での絞り込みと優先度

    /// 可視レンジ ± margin の外の枠は要求しない。
    func test_plan_limitsToVisibleRangePlusMargin() {
        let (clips, layouts) = fixture()
        let total = layouts.last!.bandEnd
        XCTAssertEqual(total, 18, accuracy: 1e-12)

        let all = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                visibleRange: 0...total, marginFactor: 0,
                                                preferredSlotWidth: slotWidth, sourceDurations: [:])
        // 先頭 2 秒だけが見えている状態（margin なし）では、3 本目のクリップは出ない。
        let head = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                 visibleRange: 0...2, marginFactor: 0,
                                                 preferredSlotWidth: slotWidth, sourceDurations: [:])
        XCTAssertLessThan(head.count, all.count)
        XCTAssertTrue(head.allSatisfy { $0.clipID == layouts[0].clipID })

        // margin を広げると隣のクリップも入ってくる。
        let widened = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                    visibleRange: 0...2, marginFactor: 4,
                                                    preferredSlotWidth: slotWidth, sourceDurations: [:])
        XCTAssertGreaterThan(widened.count, head.count)
        XCTAssertTrue(widened.contains { $0.clipID == layouts[1].clipID })
    }

    /// 優先度は可視中心からの距離で、昇順に並ぶ。
    func test_plan_ordersByDistanceFromVisibleCenter() {
        let (clips, layouts) = fixture()
        // 可視中心 9 秒。前後に 1 クリップぶん以上の margin を取る。
        let requests = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                     visibleRange: 8...10, marginFactor: 2,
                                                     preferredSlotWidth: slotWidth, sourceDurations: [:])
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(requests.map(\.priority), requests.map(\.priority).sorted())
        // 可視中心を含むクリップの枠が先頭に来る。
        let centerClip = layouts.first { 9 >= $0.bandStart && 9 < $0.bandEnd }!
        XCTAssertEqual(requests[0].clipID, centerClip.clipID)
        // 3 クリップぶんの候補が混ざった状態で並んでいること（1 クリップだけの並べ替えではない）。
        XCTAssertGreaterThan(Set(requests.map(\.clipID)).count, 1)
    }

    /// **件数の上限を掛けない**（先頭クリップが予算を食い切るバグの再発防止）。
    /// 1 クリップぶんの枠数は `slots()` 単体の計算と一致し（＝ここで追加の上限を掛けていない）、
    /// かつ後続クリップの枠もその全数がちゃんと出ること。
    ///
    /// 新方式（固定グリッド）では `maximumSlotsPerClip`（60）ちょうどには揃わない
    /// （量子化したセルが上限以下に収まった時点で打ち切るため）。ここでは `slots()` が
    /// 単体で返す件数を正とし、それと `plan()` の結果が一致することを確かめる。
    func test_plan_doesNotCapCountSoLaterClipsSurvive() {
        let source = UUID()
        let long1 = clip(source: source, start: 0, end: 20)
        let long2 = clip(source: source, start: 20, end: 40)
        let long3 = clip(source: source, start: 40, end: 60)
        let clips = [long1, long2, long3]
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: clips))
        let dense = TimelineGeometry(pixelsPerSecond: 160)

        let requests = TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: dense,
                                                     visibleRange: 0...60, marginFactor: 0,
                                                     preferredSlotWidth: slotWidth, sourceDurations: [:])
        var expectedTotal = 0
        for layout in layouts {
            guard let layoutClip = clips.first(where: { $0.id == layout.clipID }) else {
                return XCTFail("clip 欠落")
            }
            let expectedSlots = TimelineThumbnailLayout.slots(
                clip: layoutClip, spanStart: layout.spanStart,
                band: CompositionInterval(start: layout.bandStart, end: layout.bandEnd),
                geometry: dense, preferredSlotWidth: slotWidth)
            XCTAssertLessThanOrEqual(expectedSlots.count, TimelineThumbnailLayout.maximumSlotsPerClip)
            XCTAssertEqual(requests.filter { $0.clipID == layout.clipID }.count, expectedSlots.count,
                           "クリップ \(layout.index) の枠が落ちている、または追加で削られている")
            expectedTotal += expectedSlots.count
        }
        XCTAssertEqual(requests.count, expectedTotal)
    }

    /// 枠は素材時刻の固定グリッドに貼るので、先頭の枠は帯の左端より最大 1 セル左へ
    /// はみ出す（`leadingOffset`）。**可視範囲の判定にこのはみ出しを足さないと、
    /// 枠の中心が実際より右に見積もられ、可視範囲の右端にある枠が要求から落ちる**
    /// （＝スクロールした先が灰色のまま残る）。
    func test_plan_includesSlotsShiftedByLeadingOffset() {
        let source = UUID()
        // 素材開始をグリッド（0.5 秒）の境界からずらして leadingOffset を立てる。
        let target = clip(source: source, start: 0.3, end: 6.3)
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: [target]))
        let layout = layouts[0]
        let slots = TimelineThumbnailLayout.slots(
            clip: target, spanStart: layout.spanStart,
            band: CompositionInterval(start: layout.bandStart, end: layout.bandEnd),
            geometry: geometry, preferredSlotWidth: slotWidth)
        XCTAssertLessThan(slots.leadingOffset, 0, "グリッドが帯の左端よりはみ出す構成になっていない")

        let slotDuration = geometry.duration(forWidth: slots.slotWidth)
        // `duration(forWidth:)` は負を 0 に潰すので、符号は外に出して引く。
        let gridStart = layout.bandStart - geometry.duration(forWidth: -slots.leadingOffset)
        // 可視範囲の右端を、最後の枠の中心ちょうどに置く。
        let lastCenter = gridStart + (Double(slots.count) - 0.5) * slotDuration
        let requests = TimelineThumbnailPlanner.plan(layouts: layouts, clips: [target], geometry: geometry,
                                                     visibleRange: 0...lastCenter, marginFactor: 0,
                                                     preferredSlotWidth: slotWidth, sourceDurations: [:])
        XCTAssertEqual(requests.count, slots.count, "可視範囲の右端にある枠が要求から落ちている")
    }

    // MARK: - 退化入力

    func test_plan_degenerateInputs() {
        let (clips, layouts) = fixture()
        XCTAssertTrue(TimelineThumbnailPlanner.plan(layouts: [], clips: clips, geometry: geometry,
                                                    visibleRange: 0...10, sourceDurations: [:]).isEmpty)
        XCTAssertTrue(TimelineThumbnailPlanner.plan(layouts: layouts, clips: [], geometry: geometry,
                                                    visibleRange: 0...10, sourceDurations: [:]).isEmpty)
        // layouts にあるが clips に無い（削除直後の一時的な不整合）は黙って飛ばす。
        XCTAssertTrue(TimelineThumbnailPlanner.plan(layouts: layouts, clips: [clip(start: 0, end: 1)],
                                                    geometry: geometry, visibleRange: 0...10,
                                                    sourceDurations: [:]).isEmpty)
        // 可視レンジがタイムラインの外（負・遠方）なら 0 件。
        XCTAssertTrue(TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                    visibleRange: 1000...1010, marginFactor: 0,
                                                    preferredSlotWidth: slotWidth,
                                                    sourceDurations: [:]).isEmpty)
        // marginFactor が壊れていても 0 として通る（NaN で全滅しない）。
        XCTAssertFalse(TimelineThumbnailPlanner.plan(layouts: layouts, clips: clips, geometry: geometry,
                                                     visibleRange: 0...18, marginFactor: .nan,
                                                     preferredSlotWidth: slotWidth,
                                                     sourceDurations: [:]).isEmpty)
    }
}
