import XCTest
@testable import MosaicCore

/// `AudioDuckingCurve`（声区間 → BGM ゲインのノード列）。
final class AudioDuckingCurveTests: XCTestCase {
    /// 基本形: 1 区間から attack/release を含む 4 ノードができる（rate=1 なので素材時刻 = 合成時刻）。
    func test_nodes_singleRange_producesFourNodesInOrder() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let mapping = TimelineMapping(clips: [clip])
        let range = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 3, sourceEnd: 5)

        let nodes = AudioDuckingCurve.nodes(ranges: [range], gain: 0.3, mapping: mapping,
                                            songStart: 0, songEnd: 10)

        XCTAssertEqual(nodes.count, 4, "1 区間は attack/gain-start/gain-end/release の 4 ノード")
        XCTAssertEqual(nodes[0].time, 3 - AudioDuckingCurve.attack, accuracy: 1e-9)
        XCTAssertEqual(nodes[0].gain, 1, "区間の前は下げていない")
        XCTAssertEqual(nodes[1].time, 3, accuracy: 1e-9)
        XCTAssertEqual(nodes[1].gain, 0.3)
        XCTAssertEqual(nodes[2].time, 5, accuracy: 1e-9)
        XCTAssertEqual(nodes[2].gain, 0.3)
        XCTAssertEqual(nodes[3].time, 5 + AudioDuckingCurve.release, accuracy: 1e-9)
        XCTAssertEqual(nodes[3].gain, 1, "区間の後は元へ戻る")
    }

    /// ノードの時刻は厳密に単調増加、値域は [gain, 1] に収まる。
    func test_nodes_areStrictlyIncreasingAndWithinGainRange() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 20)
        let mapping = TimelineMapping(clips: [clip])
        let ranges = [
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 1, sourceEnd: 2),
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 5, sourceEnd: 6),
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 10, sourceEnd: 15)
        ]

        let nodes = AudioDuckingCurve.nodes(ranges: ranges, gain: 0.4, mapping: mapping,
                                            songStart: 0, songEnd: 20)

        XCTAssertFalse(nodes.isEmpty)
        for index in 1..<nodes.count {
            XCTAssertLessThan(nodes[index - 1].time, nodes[index].time,
                              "ノード時刻が単調増加でない: index=\(index)")
        }
        for node in nodes {
            XCTAssertGreaterThanOrEqual(node.gain, 0.4 - 1e-6, "ゲインが下限を割っている")
            XCTAssertLessThanOrEqual(node.gain, 1, "ゲインが素の音量(1)より上がっている")
        }
    }

    /// 曲の範囲（`songStart`...`songEnd`）の外へノードが出ない。
    func test_nodes_neverExceedSongBounds() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let mapping = TimelineMapping(clips: [clip])
        // 区間が曲の開始・終了ぎりぎりまで食い込むようにして、attack/release のクランプを踏む
        // （区間自体は曲の範囲と重なりを持たせる。完全に範囲外だと写像された span が
        // 丸ごと捨てられ、クランプの検証にならないため）。
        let ranges = [
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 0, sourceEnd: 1.5),
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 8.5, sourceEnd: 10)
        ]

        let nodes = AudioDuckingCurve.nodes(ranges: ranges, gain: 0.2, mapping: mapping,
                                            songStart: 1, songEnd: 9)

        XCTAssertFalse(nodes.isEmpty, "曲の範囲と重なる区間はノードを作るはず")
        for node in nodes {
            XCTAssertGreaterThanOrEqual(node.time, 1 - 1e-9, "曲の開始より前のノードがある")
            XCTAssertLessThanOrEqual(node.time, 9 + 1e-9, "曲の終了より後のノードがある")
        }
    }

    /// 近接する 2 区間（attack/release の余白が重なる距離）は 1 本の平坦区間へ統合され、
    /// ノードが重ならない。
    func test_nodes_nearbyRanges_mergeIntoOnePlateau() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 20)
        let mapping = TimelineMapping(clips: [clip])
        // 2 区間の間隔 0.1s は attack(0.12) + release(0.35) の余白より狭いので、
        // 下げ区間の attack/release が重なって 1 枚の平坦区間に統合されるべき。
        let ranges = [
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 3, sourceEnd: 4),
            ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 4.1, sourceEnd: 5)
        ]

        let nodes = AudioDuckingCurve.nodes(ranges: ranges, gain: 0.25, mapping: mapping,
                                            songStart: 0, songEnd: 20)

        XCTAssertEqual(nodes.count, 4, "近接する 2 区間は統合されて 4 ノードに収まるべき")
        for index in 1..<nodes.count {
            XCTAssertLessThan(nodes[index - 1].time, nodes[index].time, "統合後もノードは重ならない")
        }
        XCTAssertEqual(nodes[1].time, 3, accuracy: 1e-9, "統合区間の開始は先頭区間の開始")
        XCTAssertEqual(nodes[2].time, 5, accuracy: 1e-9, "統合区間の終了は末尾区間の終了")
    }

    /// **写像の取り違えの番人**: rate = 2.0 のクリップで、素材時刻の区間が正しい合成時刻へ写ること。
    /// `TimelineMapping.compositionTime` を経由せず自前の式（`sourceTime / rate`）で書くと
    /// このテストだけが検出できるずれになる。
    func test_nodes_rateTwoClip_mapsSourceTimeToCompositionTimeCorrectly() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 20, rate: 2.0)
        let mapping = TimelineMapping(clips: [clip])
        // 素材時刻 [4, 8) は rate=2.0 なら合成時刻 [2, 4) に写るはず。
        let range = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 4, sourceEnd: 8)

        let nodes = AudioDuckingCurve.nodes(ranges: [range], gain: 0.5, mapping: mapping,
                                            songStart: 0, songEnd: 10)

        XCTAssertEqual(nodes.count, 4)
        XCTAssertEqual(nodes[1].time, 2, accuracy: 1e-6, "rate=2.0 の下げ開始が合成時刻 2 秒に来ていない")
        XCTAssertEqual(nodes[2].time, 4, accuracy: 1e-6, "rate=2.0 の下げ終了が合成時刻 4 秒に来ていない")
    }

    /// 区間が写像できない（`clipID` が存在しない）ときは空。
    func test_nodes_unknownClipID_returnsEmpty() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let mapping = TimelineMapping(clips: [clip])
        let range = ClipDuckRange(clipID: UUID(), sourceID: UUID(), sourceStart: 1, sourceEnd: 2)

        let nodes = AudioDuckingCurve.nodes(ranges: [range], gain: 0.5, mapping: mapping,
                                            songStart: 0, songEnd: 10)
        XCTAssertTrue(nodes.isEmpty)
    }
}
