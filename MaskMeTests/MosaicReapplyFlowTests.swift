import MosaicCore
import XCTest
@testable import MaskMe

/// 「モザイクをかける／外す／もう一度かける」という**操作の流れ**の契約。
///
/// 部品はそれぞれ正しかったのに壊れていた実例がある:
/// - `MosaicApplyGate`「区間 0 本 = 全区間 OFF」— 意図した仕様。テスト済み
/// - `enterDock(.face)`「既に ON なら何もしない」— 意図した挙動。テスト済み
/// - `removeMosaicApplyRange`「区間を消す」— 正しい
///
/// 全部足すと「**かける操作がどこにも区間を作らない**」という穴が残り、
/// 加工レイヤーを消した後は完了を押してもモザイクが掛からなかった（ユーザー報告）。
/// 単体テストが全部 green でも見えない類なので、流れそのものをここで固定する。
@MainActor
final class MosaicReapplyFlowTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    /// クリップ 1 本 + 全域の適用区間を持つモデル（動画を読み込んだ直後に相当）。
    private func modelWithClip() -> (MosaicEditorModel, TimelineClip) {
        let model = makeModel()
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        model.timeline = TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: []))
        return (model, clip)
    }

    /// その時刻でモザイクが有効か（描画側と同じ判定を通す）。
    private func isMosaicOn(_ model: MosaicEditorModel, at time: Double) -> Bool {
        MosaicApplyGate.isActive(ranges: model.timeline.applyRanges,
                                 mapping: model.mapping,
                                 compositionTime: time,
                                 photoSourceIDs: model.timeline.photoSourceIDs)
    }

    // MARK: - 消して、もう一度かける

    /// **これが報告されたバグそのもの。**
    /// 加工レイヤーを消す → もう一度「顔」の段へ入る → 掛かっていること。
    func test_afterRemovingTheLayer_enteringFaceRouteMakesMosaicApplyAgain() throws {
        let (model, _) = modelWithClip()
        XCTAssertTrue(isMosaicOn(model, at: 1), "前提: 最初は掛かっている")

        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.removeMosaicApplyRange(id: rangeID)
        XCTAssertFalse(isMosaicOn(model, at: 1), "前提: 消したら掛からない")

        model.enterDock(.mosaic)
        model.enterDock(.face)

        XCTAssertTrue(isMosaicOn(model, at: 1),
                      "消してから顔の段に入り直したのにモザイクが掛からない")
    }

    /// 完了まで押しても掛かったままであること（段を降りると消える、が無いこと）。
    func test_mosaicSurvivesPressingDone() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.removeMosaicApplyRange(id: rangeID)

        model.enterDock(.mosaic)
        model.enterDock(.face)
        model.dockDone()

        XCTAssertEqual(model.dockRoute, .root, "完了で最上段へ戻っていない")
        XCTAssertTrue(isMosaicOn(model, at: 1), "完了を押したらモザイクが消えた")
    }

    /// **効果を切ってから入れ直す流れ**でも掛かること。
    /// `setEffectOn` が「既に ON なら何もしない」で早期 return する経路を塞いでいるか。
    func test_togglingEffectOffThenOnReappliesMosaic() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        // **既定は OFF なので、まず入れてから切る。** ここを「いきなり toggle で切る」
        // と書くと、既定が変わった瞬間に意図が反転する（実際に反転した）。
        model.toggleDockEffect(.face)   // ON
        XCTAssertTrue(model.faceMosaicOn, "前提: 一度掛けた状態にする")

        model.toggleDockEffect(.face)   // OFF
        XCTAssertFalse(model.faceMosaicOn, "前提: 顔モザイクが切れている")
        model.removeMosaicApplyRange(id: rangeID)
        model.toggleDockEffect(.face)   // ON

        XCTAssertTrue(model.faceMosaicOn)
        XCTAssertTrue(isMosaicOn(model, at: 1), "効果を入れ直したのに区間が無いまま")
    }

    /// 背景モザイクでも同じこと（顔だけ直して背景を忘れる、を防ぐ）。
    func test_backgroundRouteAlsoRestoresRanges() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.removeMosaicApplyRange(id: rangeID)

        model.enterDock(.mosaic)
        model.enterDock(.background)

        XCTAssertTrue(isMosaicOn(model, at: 1), "背景の段では区間が復活しない")
    }

    /// 矩形の段でも同じこと。
    func test_rectangleRouteAlsoRestoresRanges() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.removeMosaicApplyRange(id: rangeID)

        model.enterDock(.mosaic)
        model.enterDock(.rectangle)

        XCTAssertTrue(isMosaicOn(model, at: 1), "矩形の段では区間が復活しない")
    }

    // MARK: - 触りすぎないこと

    /// **一部だけ消した区間は復活させない。** 特定のクリップだけ外したのは
    /// 意図的な操作なので、別の場所で効果を入れ直したからといって戻してはいけない。
    func test_partiallyRemovedRangesAreNotResurrected() throws {
        let model = makeModel()
        let sourceID = UUID()
        let clipA = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 5)
        let clipB = TimelineClip(sourceID: sourceID, sourceStart: 5, sourceEnd: 10)
        model.timeline = TimelineState(
            clips: [clipA, clipB],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: []))
        XCTAssertEqual(model.timeline.applyRanges.count, 2, "前提: 2 本ある")

        let firstID = try XCTUnwrap(
            model.timeline.applyRanges.first(where: { $0.clipID == clipA.id })?.id)
        model.removeMosaicApplyRange(id: firstID)

        model.enterDock(.mosaic)
        model.enterDock(.face)

        XCTAssertEqual(model.timeline.applyRanges.count, 1,
                       "一部だけ消した区間まで復活している（意図的な削除が巻き戻る）")
        XCTAssertNil(model.timeline.applyRanges.first { $0.clipID == clipA.id },
                     "消したクリップの区間が戻っている")
    }

    /// 既に全部ある状態で段を出入りしても区間が増えないこと。
    func test_enteringRouteWithExistingRangesDoesNotDuplicate() {
        let (model, _) = modelWithClip()
        let before = model.timeline.applyRanges.count

        model.enterDock(.mosaic)
        model.enterDock(.face)
        model.dockDone()
        model.enterDock(.mosaic)
        model.enterDock(.face)

        XCTAssertEqual(model.timeline.applyRanges.count, before, "区間が増殖している")
    }

    /// クリップが 1 本も無いときは何も作らない（空タイムラインに区間だけ生えない）。
    func test_withoutClipsNothingIsCreated() {
        let model = makeModel()
        model.enterDock(.mosaic)
        model.enterDock(.face)
        XCTAssertTrue(model.timeline.applyRanges.isEmpty)
    }

    // MARK: - 開いた直後は掛けない

    /// **動画は開いただけでモザイクが乗らない。**
    /// 素材を確認したいだけの人が、毎回まず外す羽目になるのを避ける。
    func test_videoModeStartsWithMosaicOff() {
        XCTAssertFalse(makeModel().faceMosaicOn,
                       "動画を開いた時点で顔モザイクが入っている")
    }

    /// **写真は従来どおり即座に掛ける。** 1 枚に対して結果を見せる画面なので、
    /// 押さないと何も起きないのは不親切。
    func test_photoModeStillStartsWithMosaicOn() {
        let model = MosaicEditorModel(mode: .photo, recents: RecentItemsStore())
        XCTAssertTrue(model.faceMosaicOn, "写真モードの既定まで OFF になっている")
    }

    /// 顔の段に入れば掛かる（OFF 既定でも「かける」導線が繋がっている）。
    func test_enteringFaceRouteTurnsMosaicOn() {
        let (model, _) = modelWithClip()
        XCTAssertFalse(model.faceMosaicOn, "前提: 既定は OFF")

        model.enterDock(.mosaic)
        model.enterDock(.face)

        XCTAssertTrue(model.faceMosaicOn, "顔の段に入ってもモザイクが入らない")
        XCTAssertTrue(isMosaicOn(model, at: 1), "フラグは立ったが区間が無い")
    }

    /// **顔探しは開いた時点では走らせない。** 掛けると決めるまで待ち時間を出さない。
    func test_faceSeedingIsDeferredUntilTheFaceRoute() {
        let model = makeModel()
        XCTAssertFalse(model.didSeedFaces, "開いた時点で顔探しが走っている")
    }
}
