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
        XCTAssertNil(selection.layerID(of: .mosaic))
    }

    func test_selectClip_clearsRange() {
        var selection = TimelineSelection()
        let range = UUID(), clip = UUID()
        selection.selectMosaicForTest(range)
        selection.selectClip(clip)
        XCTAssertEqual(selection.clipID, clip)
        XCTAssertNil(selection.layerID(of: .mosaic), "クリップを選んだのにレイヤーの選択が残っている")
    }

    func test_selectRange_clearsClip() {
        var selection = TimelineSelection()
        let range = UUID(), clip = UUID()
        selection.selectClip(clip)
        selection.selectMosaicForTest(range)
        XCTAssertEqual(selection.layerID(of: .mosaic), range)
        XCTAssertNil(selection.clipID, "レイヤーを選んだのにクリップの選択が残っている")
    }

    /// `nil` は選択解除であって、もう片方を巻き添えにしない。
    /// 巻き添えにすると、レイヤーを選んだ状態で「クリップ選択解除」が飛んできただけで
    /// レイヤーまで外れる（帯の余白タップが両方を消す）。
    func test_selectClipNil_doesNotClearRange() {
        var selection = TimelineSelection()
        let range = UUID()
        selection.selectMosaicForTest(range)
        selection.selectClip(nil)
        XCTAssertEqual(selection.layerID(of: .mosaic), range)
    }

    func test_selectRangeNil_doesNotClearClip() {
        var selection = TimelineSelection()
        let clip = UUID()
        selection.selectClip(clip)
        selection.selectMosaicForTest(nil)
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
        selection.selectMosaicForTest(dead)
        selection.prune(against: state(clipIDs: [clip], rangeIDs: [alive]))
        XCTAssertNil(selection.layerID(of: .mosaic), "消えたレイヤーを指したまま残っている")
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

    /// `selectLayer` 経由でもクリップの選択が外れる（相互排他は型の契約）。
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

    /// **種の取り違えを型で防いでいることの回帰。**
    ///
    /// かつて `rangeID`（種を問わず id を返す）と `selectRange`（常に `.mosaic` として
    /// 書く）という shim があり、BGM の段が同じ Binding を使っていた。結果として
    /// **BGM の帯をタップして選ぶと内部では `.mosaic` になり、削除も音量調整も
    /// 効かなくなっていた**（削除は存在しない適用区間の id を消しにいって no-op、
    /// 音量は `.audio` を要求する判定が false になる）。
    ///
    /// いまは `layerID(of:)` が種を必ず伴うので、違う種で引けば nil になる。
    func test_layerID_returnsNilForOtherKinds() {
        var selection = TimelineSelection()
        let audioID = UUID()
        selection.selectLayer(TimelineLayerSelection(kind: .audio, id: audioID))

        XCTAssertEqual(selection.layerID(of: .audio), audioID)
        XCTAssertNil(selection.layerID(of: .mosaic),
                     "BGM を選んでいるのにモザイクの id として引けてしまう")
        XCTAssertNil(selection.layerID(of: .text),
                     "BGM を選んでいるのにテキストの id として引けてしまう")
    }

    /// 全ての種について、自分の種でだけ引けること（`allCases` で網羅）。
    func test_layerID_isExclusiveAcrossAllKinds() {
        for kind in TimelineLayerKind.allCases {
            var selection = TimelineSelection()
            let id = UUID()
            selection.selectLayer(TimelineLayerSelection(kind: kind, id: id))
            for other in TimelineLayerKind.allCases {
                if other == kind {
                    XCTAssertEqual(selection.layerID(of: other), id,
                                   "\(kind) を選んだのに自分の種で引けない")
                } else {
                    XCTAssertNil(selection.layerID(of: other),
                                 "\(kind) を選んだのに \(other) の id として引けてしまう")
                }
            }
        }
    }
}

private extension TimelineSelection {
    /// テスト用のモザイク選択ショートカット。
    ///
    /// **本体には「種を落とす入口」を置かない**（かつて `selectRange` という shim が
    /// あり、BGM の帯を選んでも内部では `.mosaic` になる欠陥を生んだ）。
    /// テストの読みやすさのためだけの糖衣なので、`private` でここに閉じる。
    mutating func selectMosaicForTest(_ id: UUID?) {
        selectLayer(id.map { TimelineLayerSelection(kind: .mosaic, id: $0) })
    }
}
