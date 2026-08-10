import MosaicCore
import XCTest
@testable import MaskMe

/// 矩形マスクの「追えているか」の状態が、モデルから画面へ正しく運ばれるかを見る。
///
/// 状態判定自体（`.fixed` / `.tracking` / `.computing` / `.untracked`）は
/// `MosaicCore`（`ObjectMaskFollowStateTests`）で固定済み。ここで見るのは**配線**——
/// アプリ層（`visibleObjectMasks` / `objectTrackingTasks`）が状態を落とさずに運んでいるか。
@MainActor
final class ObjectMaskFollowStateWiringTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    private func box(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0.3, width: 0.2, height: 0.2)
    }

    /// クリップ 1 本を持つモデル。**`sources` には何も入れない** — 入れると
    /// `pendingTrackingMasksByClip` が実際の追跡タスクを起動してしまい、
    /// テストが `objectTrackingTasks` の直接操作と競合する。
    private func modelWithClip() -> (MosaicEditorModel, TimelineClip) {
        let model = makeModel()
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        return (model, clip)
    }

    private func matchingTrack(for mask: ObjectMask, clip: TimelineClip) -> ObjectTrack? {
        guard let segment = ObjectTrack.Segment(samples: [
            .init(sourceTime: 0, rect: mask.rect(atSourceTime: 0)),
            .init(sourceTime: 5, rect: mask.rect(atSourceTime: 0))
        ]) else { return nil }
        return ObjectTrack(maskID: mask.id, clipID: clip.id, sourceID: clip.sourceID,
                           keyframes: mask.keyframes, segments: [segment])
    }

    /// **`visibleObjectMasks` が状態を運ぶ。** 一致する軌跡を注入すると `.tracking`、
    /// キーフレームを 1 個動かして軌跡を古くすると `.untracked` になる。
    ///
    /// 壊すと落ちる1行: `visibleObjectMasks` で `state:` に定数（例えば `.tracking` 固定）を
    /// 渡すコード。
    func test_visibleObjectMasksが状態を運ぶ() throws {
        let (model, clip) = modelWithClip()
        let id = try XCTUnwrap(model.appendObjectMask(compositionRect: box(0.1)))
        let mask = try XCTUnwrap(model.objectMasks.first(where: { $0.id == id }))
        let track = try XCTUnwrap(matchingTrack(for: mask, clip: clip))
        model.objectTracks[id] = track

        let tracking = try XCTUnwrap(model.visibleObjectMasks.first(where: { $0.id == id }))
        XCTAssertEqual(tracking.state, .tracking, "一致する軌跡があるのに追跡中にならない")

        // キーフレームを動かす → `track.matches(mask)` が false になり軌跡が古くなる。
        // `sources` を設定していないので `objectTrackingTasks` は起動しないまま
        // （`pendingTrackingMasksByClip` の `sources[...] != nil` ガードで弾かれる）。
        model.setObjectMaskKeyframe(id, compositionRect: box(0.5), angle: 0)
        XCTAssertTrue(model.objectTrackingTasks.isEmpty,
                      "sources 未設定なのに追跡タスクが起動している（テストの前提が崩れている）")

        let untracked = try XCTUnwrap(model.visibleObjectMasks.first(where: { $0.id == id }))
        XCTAssertEqual(untracked.state, .untracked, "古い軌跡なのに追跡中のままになっている")
    }

    /// **同じクリップでも、軌跡が最新のマスクは解析中にしない。**
    /// クリップ単位で `isTrackingRunning` を直結させると、既に追跡済みのマスクまで
    /// 「解析中」と表示されてしまう（＝せっかく追えているのに不安を煽る表示になる）。
    ///
    /// 壊すと落ちる1行: `isTrackingRunning` をクリップ単位でそのまま状態に直結させるコード
    /// （`ObjectMaskResolver.resolve` の `matches` 分岐より前で判定してしまう実装）。
    func test_同じクリップでも軌跡が最新のマスクは解析中にしない() throws {
        let (model, clip) = modelWithClip()
        let trackedID = try XCTUnwrap(model.appendObjectMask(compositionRect: box(0.1)))
        let untrackedID = try XCTUnwrap(model.appendObjectMask(compositionRect: box(0.6)))
        let trackedMask = try XCTUnwrap(model.objectMasks.first(where: { $0.id == trackedID }))
        let track = try XCTUnwrap(matchingTrack(for: trackedMask, clip: clip))
        model.objectTracks[trackedID] = track

        // このクリップの追跡タスクが走行中であることを直接注入する
        // （`objectTrackingTasks` は internal・非 `@Published`。実タスクは要らない）。
        model.objectTrackingTasks[clip.id] = (masks: [], task: Task {})

        let visible = model.visibleObjectMasks
        let trackedVisible = try XCTUnwrap(visible.first(where: { $0.id == trackedID }))
        let untrackedVisible = try XCTUnwrap(visible.first(where: { $0.id == untrackedID }))

        XCTAssertEqual(trackedVisible.state, .tracking,
                       "軌跡が最新なのに、同じクリップの走行中フラグに引きずられて解析中になっている")
        XCTAssertEqual(untrackedVisible.state, .computing,
                       "軌跡が無いマスクは、クリップの追跡タスクが走行中なら解析中になるべき")
    }

    /// 表示規則（`ObjectMaskStateStyle`）を固定する。
    /// 壊すと落ちる1行: `isDashed` の `.tracking` 分岐を落とす（実線が破線になる）。
    func test_表示規則() {
        XCTAssertNil(ObjectMaskStateStyle.label(.fixed))
        XCTAssertFalse(ObjectMaskStateStyle.isDashed(.fixed))

        XCTAssertEqual(ObjectMaskStateStyle.label(.tracking), "追跡中")
        XCTAssertFalse(ObjectMaskStateStyle.isDashed(.tracking))

        XCTAssertEqual(ObjectMaskStateStyle.label(.computing), "解析中")
        XCTAssertTrue(ObjectMaskStateStyle.isDashed(.computing))

        XCTAssertEqual(ObjectMaskStateStyle.label(.untracked), "追跡なし")
        XCTAssertTrue(ObjectMaskStateStyle.isDashed(.untracked))
    }
}
