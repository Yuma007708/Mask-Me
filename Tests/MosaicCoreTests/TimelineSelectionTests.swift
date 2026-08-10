import XCTest
@testable import MosaicCore

/// 選択の契約。クリップと加工レイヤーが同時に選ばれると、ツールバーが
/// 「どちらに対する道具か」を決められないまま押せてしまう。
final class TimelineSelectionTests: XCTestCase {
    private let sourceID = UUID()

    private func state(clipIDs: [UUID], rangeIDs: [UUID] = []) -> TimelineState {
        let clips = clipIDs.map {
            TimelineClip(id: $0, sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        }
        let ranges = rangeIDs.map {
            MosaicApplyRange(id: $0, clipID: clipIDs.first ?? UUID(), sourceID: sourceID,
                             sourceStart: 0, sourceEnd: 1)
        }
        return TimelineState(clips: clips, applyRanges: ranges)
    }

    // MARK: - 相互排他

    func test_initial_isEmpty() {
        let selection = TimelineSelection()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.clipID)
        XCTAssertNil(selection.rangeID)
    }

    func test_selectClip_clearsRange() {
        var selection = TimelineSelection()
        let range = UUID(), clip = UUID()
        selection.selectRange(range)
        selection.selectClip(clip)
        XCTAssertEqual(selection.clipID, clip)
        XCTAssertNil(selection.rangeID, "クリップを選んだのにレイヤーの選択が残っている")
    }

    func test_selectRange_clearsClip() {
        var selection = TimelineSelection()
        let range = UUID(), clip = UUID()
        selection.selectClip(clip)
        selection.selectRange(range)
        XCTAssertEqual(selection.rangeID, range)
        XCTAssertNil(selection.clipID, "レイヤーを選んだのにクリップの選択が残っている")
    }

    /// `nil` は選択解除であって、もう片方を巻き添えにしない。
    /// 巻き添えにすると、レイヤーを選んだ状態で「クリップ選択解除」が飛んできただけで
    /// レイヤーまで外れる（帯の余白タップが両方を消す）。
    func test_selectClipNil_doesNotClearRange() {
        var selection = TimelineSelection()
        let range = UUID()
        selection.selectRange(range)
        selection.selectClip(nil)
        XCTAssertEqual(selection.rangeID, range)
    }

    func test_selectRangeNil_doesNotClearClip() {
        var selection = TimelineSelection()
        let clip = UUID()
        selection.selectClip(clip)
        selection.selectRange(nil)
        XCTAssertEqual(selection.clipID, clip)
    }

    func test_clear_removesBoth() {
        var selection = TimelineSelection()
        selection.selectClip(UUID())
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: - 刈り込み

    func test_prune_dropsMissingClip() {
        var selection = TimelineSelection()
        let alive = UUID(), dead = UUID()
        selection.selectClip(dead)
        selection.prune(against: state(clipIDs: [alive]))
        XCTAssertNil(selection.clipID, "消えたクリップを指したまま残っている")
    }

    func test_prune_dropsMissingRange() {
        var selection = TimelineSelection()
        let clip = UUID(), alive = UUID(), dead = UUID()
        selection.selectRange(dead)
        selection.prune(against: state(clipIDs: [clip], rangeIDs: [alive]))
        XCTAssertNil(selection.rangeID, "消えたレイヤーを指したまま残っている")
    }

    /// 生きているものは刈らない（分割や並べ替えのたびに選択が飛ぶと使えない）。
    func test_prune_keepsLivingSelection() {
        var selection = TimelineSelection()
        let clip = UUID()
        selection.selectClip(clip)
        selection.prune(against: state(clipIDs: [clip, UUID()]))
        XCTAssertEqual(selection.clipID, clip)
    }

    func test_prune_onEmptyTimeline_clearsEverything() {
        var selection = TimelineSelection()
        selection.selectClip(UUID())
        selection.prune(against: TimelineState())
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: - Step 4: 種を持つ選択（`TimelineLayerSelection`）

    /// `selectLayer` 経由でもクリップの選択が外れる（`selectRange` shim と同じ相互排他）。
    func test_selectLayer_clearsClip() {
        var selection = TimelineSelection()
        let clip = UUID()
        selection.selectClip(clip)
        selection.selectLayer(TimelineLayerSelection(kind: .mosaic, id: UUID()))
        XCTAssertNil(selection.clipID, "レイヤーを選んだのにクリップの選択が残っている")
    }

    /// クリップを選ぶと `selectLayer` で選んだレイヤーの選択が外れる。
    func test_selectClip_clearsLayer() {
        var selection = TimelineSelection()
        selection.selectLayer(TimelineLayerSelection(kind: .mosaic, id: UUID()))
        selection.selectClip(UUID())
        XCTAssertNil(selection.layer, "クリップを選んだのにレイヤーの選択が残っている")
    }

    /// `selectLayer` で選んだアイテムが消えると `prune` で落ちる。
    func test_prune_dropsMissingLayerSelectedDirectly() {
        var selection = TimelineSelection()
        let clip = UUID(), alive = UUID(), dead = UUID()
        selection.selectLayer(TimelineLayerSelection(kind: .mosaic, id: dead))
        selection.prune(against: state(clipIDs: [clip], rangeIDs: [alive]))
        XCTAssertNil(selection.layer, "消えたレイヤーを指したまま残っている")
    }

    /// すべての `TimelineLayerKind` について、存在しない id は `prune` で落ちること。
    func test_prune_dropsMissingID_forEveryLayerKind() {
        for kind in TimelineLayerKind.allCases {
            var selection = TimelineSelection()
            let clip = UUID()
            selection.selectLayer(TimelineLayerSelection(kind: kind, id: UUID()))
            selection.prune(against: state(clipIDs: [clip]))
            XCTAssertNil(selection.layer, "kind=\(kind) で消えたレイヤーが刈られていない")
        }
    }
}
