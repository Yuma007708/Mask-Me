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
        XCTAssertEqual(spans[0].clipID, clips[0].id)
        XCTAssertEqual(spans[1].clipID, clips[1].id)
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
