import XCTest
@testable import MosaicCore

final class TimelineMappingTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private struct MappingTestData {
        let mapping: TimelineMapping
        let clipA: TimelineClip
        let clipB: TimelineClip
    }

    /// クリップA(素材Aの0-3秒) + クリップB(素材Bの10-14秒) の並び。
    private func makeMapping() -> MappingTestData {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        return MappingTestData(mapping: TimelineMapping(clips: [a, b]), clipA: a, clipB: b)
    }

    func test_totalDurationIsSumOfClips() {
        let data = makeMapping()
        XCTAssertEqual(data.mapping.totalDuration, 7, accuracy: 1e-9)
    }

    /// 先頭クリップ内の時刻は、そのまま素材時刻になる。
    func test_firstClipMapsDirectly() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 1.5)
        XCTAssertEqual(loc?.clipID, data.clipA.id)
        XCTAssertEqual(loc?.sourceID, sourceA)
        XCTAssertEqual(loc?.time ?? 0, 1.5, accuracy: 1e-9)
    }

    /// 2つ目のクリップでは、素材内のオフセット(10秒)が加算される。
    /// ここがずれると、後続クリップの検出結果が全て別時刻を引く。
    func test_secondClipAppliesSourceOffset() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 4.0)  // クリップBの先頭から1秒
        XCTAssertEqual(loc?.clipID, data.clipB.id)
        XCTAssertEqual(loc?.sourceID, sourceB)
        XCTAssertEqual(loc?.time ?? 0, 11.0, accuracy: 1e-9)
    }

    /// クリップ境界は次のクリップの先頭に属する（半開区間 [start, end)）。
    /// 境界の扱いが曖昧だと、1フレームだけ前のクリップの顔が出る不具合になる。
    func test_boundaryBelongsToNextClip() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 3.0)
        XCTAssertEqual(loc?.clipID, data.clipB.id)
        XCTAssertEqual(loc?.time ?? 0, 10.0, accuracy: 1e-9)
    }

    /// 範囲外は nil。末尾ちょうども範囲外とする。
    func test_outOfRangeReturnsNil() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.sourceLocation(at: -0.1))
        XCTAssertNil(data.mapping.sourceLocation(at: 7.0))
        XCTAssertNil(data.mapping.sourceLocation(at: 99))
    }

    /// 素材時刻から合成時刻への逆変換。
    func test_reverseMapping() {
        let data = makeMapping()
        let t = data.mapping.compositionTime(clipID: data.clipB.id, sourceTime: 11.0)
        XCTAssertEqual(t ?? 0, 4.0, accuracy: 1e-9)
    }

    /// クリップの使用範囲外の素材時刻は逆変換できない。
    func test_reverseMappingRejectsTimeOutsideClip() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.compositionTime(clipID: data.clipB.id, sourceTime: 20.0))
    }

    /// 空のタイムラインで破綻しないこと。
    func test_emptyTimeline() {
        let mapping = TimelineMapping(clips: [])
        XCTAssertEqual(mapping.totalDuration, 0, accuracy: 1e-9)
        XCTAssertNil(mapping.sourceLocation(at: 0))
    }

    /// 同じ素材を分割した2クリップは、同じ sourceID を返す。
    /// これが成立しないと分割時に検出キャッシュを共有できない。
    func test_splitClipsShareSourceID() {
        let first = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [first, second])

        XCTAssertEqual(mapping.sourceLocation(at: 1.0)?.sourceID, sourceA)
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.sourceID, sourceA)
        // 合成時刻3.0 はクリップ2の先頭から1秒 = 素材時刻3.0
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.time ?? 0, 3.0, accuracy: 1e-9)
    }

    /// `sourceLocation(at:)` は境界(end)を次のクリップに属させる半開区間だが、
    /// `compositionTime` がその境界(sourceEnd ちょうど)を受け入れてしまうと、
    /// 素材時刻→合成時刻→素材時刻の往復が境界で非対称になる。
    /// クリップAの sourceEnd(=3.0)は「クリップAの範囲外」として nil を返すべき。
    func test_compositionTimeRejectsExactSourceEnd() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.compositionTime(clipID: data.clipA.id, sourceTime: 3.0))
    }

    /// sourceLocation(at:) が返す複数の合成時刻について、
    /// compositionTime(clipID:sourceTime:) に通すと元の合成時刻に戻ることを検証する。
    /// 境界(3.0)を含めても対称性が崩れないことがポイント。
    func test_roundTripIsSymmetric() {
        let data = makeMapping()
        let compositionTimes: [Double] = [0.0, 1.5, 2.999, 3.0, 4.0, 6.999]
        for compositionTime in compositionTimes {
            guard let loc = data.mapping.sourceLocation(at: compositionTime) else {
                XCTFail("expected a location for \(compositionTime)")
                continue
            }
            let roundTripped = data.mapping.compositionTime(clipID: loc.clipID, sourceTime: loc.time)
            XCTAssertEqual(roundTripped ?? -1, compositionTime, accuracy: 1e-9,
                           "round trip failed for compositionTime \(compositionTime)")
        }
    }
}
