import XCTest
@testable import MosaicCore

/// E1 Step 3: `TimelineApplySpan` を「レイヤー種を持つ形」へ一般化した分の契約。
///
/// `TimelineViewGeometryTests.swift` は file_length の上限に張り付いているため、
/// この Step で足したテストはここへ分けている（既存 31 本は無改造のまま）。
final class TimelineApplySpanKindTests: XCTestCase {
    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }

    /// kind を足しても、既存フィールド（rangeID/clipID/start/end/isEdgeAdjustable）の
    /// 計算結果は変わらないこと（新旧の結果が等価）。数値は
    /// `TimelineViewGeometryTests.test_applySpans_isInverseOfAddingCompositionInterval`
    /// と同じ入力を使う。
    func test_applySpans_addingKindPreservesExistingFieldValues() {
        let source = UUID()
        let clips = [clip(source: source, start: 0, end: 5), clip(source: source, start: 5, end: 10)]
        let mapping = TimelineMapping(clips: clips)
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 7,
                                            mapping: mapping, existing: [])
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: [])

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 2, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(spans[1].start, 5, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 7, accuracy: 1e-9)
        XCTAssertEqual(spans[0].anchorClipID, clips[0].id)
        XCTAssertEqual(spans[1].anchorClipID, clips[1].id)
        XCTAssertTrue(spans.allSatisfy { $0.kind == .mosaic }, "現状のレイヤー種は常に mosaic")
    }

    /// `isMovable` は `isEdgeAdjustable` から導出される（2 つが常に一致する性質テスト）。
    /// 写真クリップ由来のセグメントは伸縮不可かつ移動不可であること。
    func test_applySpans_photoSpans_areNeitherEdgeAdjustableNorMovable() {
        let photoSource = UUID()
        let photo = clip(source: photoSource, start: 0, end: 3)
        let video = clip(source: UUID(), start: 0, end: 3)
        let mapping = TimelineMapping(clips: [photo, video])
        let ranges = MosaicApplyGate.fullCoverRanges(for: [photo, video], photoSourceIDs: [])
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping,
                                                  photoSourceIDs: [photoSource])
        XCTAssertEqual(spans.count, 2)
        for span in spans {
            XCTAssertEqual(span.isMovable, span.isEdgeAdjustable,
                           "isMovable と isEdgeAdjustable が食い違っている")
        }
        XCTAssertFalse(spans[0].isMovable, "写真クリップは移動不可のはず")
        XCTAssertFalse(spans[0].isEdgeAdjustable, "写真クリップは伸縮不可のはず")
        XCTAssertTrue(spans[1].isMovable)
        XCTAssertTrue(spans[1].isEdgeAdjustable)
    }
}

// MARK: - BGM の段（E2-3a）

/// BGM を段のセグメントへ写す `TimelineBandLayout.audioSpans` と、
/// **アンカーの違いが可動域に効く**ことの契約。
final class AudioSpanLayoutTests: XCTestCase {
    private let audioSource = UUID()

    private func item(start: Double, duration: Double) -> AudioItem {
        AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: duration,
                  compositionStart: start)
    }

    /// BGM のセグメントは **`anchorClipID` が必ず nil**（クリップに属さない）。
    ///
    /// ここに `AudioItem.id` を入れると、clipID で照合している経路
    /// （移動域・トリム追随・確定の分岐）が偶然一致して取り違えを作る。
    func test_audioSpans_haveNoClipAnchor() {
        let spans = TimelineBandLayout.audioSpans(items: [item(start: 1, duration: 2)],
                                                   totalDuration: 10)
        XCTAssertEqual(spans.count, 1)
        XCTAssertNil(spans[0].anchorClipID, "BGM のセグメントがクリップに紐づいている")
        XCTAssertEqual(spans[0].kind, .audio)
        XCTAssertEqual(spans[0].start, 1, accuracy: 1e-12)
        XCTAssertEqual(spans[0].end, 3, accuracy: 1e-12)
        XCTAssertTrue(spans[0].isEdgeAdjustable, "BGM の端が伸縮できない")
        XCTAssertTrue(spans[0].isMovable)
    }

    /// **合成尺で切る。** 生の `audioItems` をそのまま帯にすると、クリップを消して
    /// 縮んだタイムラインの外へ帯が伸びる。
    func test_audioSpans_clipToTotalDuration() {
        let spans = TimelineBandLayout.audioSpans(
            items: [item(start: 8, duration: 5), item(start: 30, duration: 2)],
            totalDuration: 10)
        XCTAssertEqual(spans.count, 1, "尺の外の BGM が帯に出ている")
        XCTAssertEqual(spans[0].end, 10, accuracy: 1e-12, "帯が合成尺で切れていない")
    }

    /// **BGM の可動域はタイムライン全体**（クリップ境界で止めない）。
    ///
    /// ここでクリップ帯を要求すると、BGM が「掴めるのに 1mm も動かない」になる
    /// （`TimelineItemDrag.snappedDraft` の `.move` 分岐）。
    func test_audioSpanMove_isNotConfinedToAnyClip() {
        let source = UUID()
        let clips = [TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4),
                     TimelineClip(sourceID: source, sourceStart: 4, sourceEnd: 8)]
        let mapping = TimelineMapping(clips: clips)
        let geometry = TimelineGeometry(pixelsPerSecond: 50)
        let span = TimelineBandLayout.audioSpans(items: [item(start: 0.5, duration: 1)],
                                                  totalDuration: 8)[0]
        let context = TimelineItemDragContext(
            geometry: geometry, layouts: TimelineBandLayout.clipLayouts(mapping: mapping),
            applySpans: [span], playheadTime: 0, totalDuration: 8)

        // クリップ 1 本目（合成 0...4）の外まで動かす。
        let moved = TimelineItemDrag.snappedDraft(
            span: span, kind: .move,
            translationPixels: geometry.x(forTime: 5), context: context)

        XCTAssertGreaterThan(moved.start, 4,
                             "BGM がクリップ境界で止められている（可動域がタイムライン全体になっていない）")
        XCTAssertEqual(moved.end - moved.start, 1, accuracy: 1e-9, "移動で長さが変わった")
        XCTAssertLessThanOrEqual(moved.end, 8 + 1e-9, "合成尺の外へ出た")
    }
}
