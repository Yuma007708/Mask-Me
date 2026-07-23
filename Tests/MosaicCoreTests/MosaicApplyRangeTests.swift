import XCTest
@testable import MosaicCore

final class MosaicApplyRangeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    // MARK: - isActive（ゲート判定）

    /// ranges が空なら常に true（範囲指定なし = 全区間適用の既存挙動互換）であること。
    func test_emptyRangesAlwaysActive() {
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], sourceID: sourceA, sourceTime: 0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], sourceID: UUID(), sourceTime: 123.4))
    }

    /// 判定は半開区間 [sourceStart, sourceEnd) であること。sourceID 不一致は false。
    func test_isActiveUsesHalfOpenInterval() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 1.0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 2.0.nextDown))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 2.0))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 0.999))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceB, sourceTime: 1.5))
    }

    // MARK: - 合成時刻区間の分解

    /// 複数クリップを跨ぐ合成区間は素材ごとのセグメントに分割されること。
    func test_addingIntervalAcrossClipsSplitsPerSource() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 4,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].sourceID, sourceA)
        XCTAssertEqual(ranges[0].sourceStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].sourceID, sourceB)
        XCTAssertEqual(ranges[1].sourceStart, 10.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].sourceEnd, 11.0, accuracy: 1e-9)
    }

    /// rate ≠ 1 のクリップでは合成区間が素材時刻へスケールされること（2x で 2 倍の素材区間）。
    func test_addingIntervalScalesWithRate() {
        let fast = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4, rate: 2.0) // 合成 2 秒
        let mapping = TimelineMapping(clips: [fast])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 0.5, to: 1.0,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
    }

    /// 同一素材を分割した 2 クリップに跨る区間は、素材時刻で 1 本にマージされること。
    func test_addingIntervalMergesAcrossSplitClips() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [front, back])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 1, to: 3,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].sourceID, sourceA)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
    }

    /// 既存区間と重複・隣接する追加は同一 sourceID 内でマージされ、
    /// マージ結果は最も早い開始位置の区間の id を引き継ぐこと。別素材の区間は独立に残ること。
    func test_addingIntervalMergesWithExisting() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
                        MosaicApplyRange(sourceID: sourceB, sourceStart: 0, sourceEnd: 1)]
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 3,
                                            mapping: mapping, existing: existing)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].id, existing[0].id)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1], existing[1])
    }

    /// 新規セグメントが既存区間を**前方に**伸ばす場合でも、マージ結果は既存区間の id を
    /// 引き継ぐこと（開始位置最小の側ではなく入力順優先。UI の選択が飛ばないため）。
    func test_extendingForwardKeepsExistingID() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 0.5, to: 1.2,
                                            mapping: mapping, existing: existing)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].id, existing[0].id)
        XCTAssertEqual(ranges[0].sourceStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
    }

    /// 逆転・空の合成区間では existing がそのまま返ること。
    func test_addingInvalidIntervalKeepsExisting() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 3, to: 3,
                                              mapping: mapping, existing: existing), existing)
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 4, to: 2,
                                              mapping: mapping, existing: existing), existing)
    }

    // MARK: - 素材アンカーの自動追従

    /// 素材時刻アンカーのため、クリップの分割・並べ替え（mapping の変化）後も
    /// 同じ素材時刻に対する isActive 判定が不変であること。
    func test_rangesFollowSourceAcrossTimelineEdits() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let original = TimelineMapping(clips: [a, b])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 1, to: 2,
                                            mapping: original, existing: [])  // 素材A [1, 2)

        // 分割 + 並べ替え後の mapping（B → A後半 → A前半）でも、素材時刻の判定は同じ。
        var frontA = a
        frontA.sourceEnd = 2
        let backA = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)
        let reordered = TimelineMapping(clips: [b, backA, frontA])
        for compositionTime in stride(from: 0.0, to: reordered.totalDuration, by: 0.25) {
            guard let loc = reordered.sourceLocation(at: compositionTime) else {
                XCTFail("expected a location at \(compositionTime)")
                continue
            }
            let expected = loc.sourceID == sourceA && loc.time >= 1 && loc.time < 2
            XCTAssertEqual(MosaicApplyGate.isActive(ranges: ranges, sourceID: loc.sourceID,
                                                    sourceTime: loc.time),
                           expected, "compositionTime \(compositionTime)")
        }
    }

    // MARK: - 削除

    /// removingRange は指定 id の区間だけを取り除き、未知の id では変更しないこと。
    func test_removingRange() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
                      MosaicApplyRange(sourceID: sourceA, sourceStart: 3, sourceEnd: 4)]
        let removed = MosaicApplyGate.removingRange(id: ranges[0].id, from: ranges)
        XCTAssertEqual(removed, [ranges[1]])
        XCTAssertEqual(MosaicApplyGate.removingRange(id: UUID(), from: ranges), ranges)
    }

    // MARK: - Codable

    /// エンコード→デコードの round-trip で全プロパティが一致すること。
    func test_codableRoundTrip() throws {
        let range = MosaicApplyRange(sourceID: sourceA, sourceStart: 1.25, sourceEnd: 8.5)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(MosaicApplyRange.self, from: data)
        XCTAssertEqual(decoded, range)
    }
}
