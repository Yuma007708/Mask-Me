import MosaicCore
import XCTest
@testable import MaskMe

/// 手動矩形（物体モザイク）が**顔モザイクから独立している**ことの契約。
///
/// 以前は矩形の描画が `faceMosaicOn` に従属していた（「矩形は顔検出の補助」という
/// 位置づけ）。そのため:
/// - 顔を切ると、自分で置いた矩形まで無言で消えた
/// - 矩形の段に入るだけで顔モザイクまで点いた（`setEffectOn(.face)` を呼んでいた）
///
/// 「顔は検出に任せて、検出できない物だけ矩形で隠す」という使い方ができなかったので、
/// 矩形は `objectMosaicOn` で独立に持つことにした。ここはその境界を固定する。
@MainActor
final class ObjectMosaicIndependenceTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    /// クリップ 1 本 + 全域の適用区間（動画を読み込んだ直後に相当）。
    private func modelWithClip() -> (MosaicEditorModel, TimelineClip) {
        let model = makeModel()
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        model.timeline = TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: []))
        return (model, clip)
    }

    private func isMosaicOn(_ model: MosaicEditorModel, at time: Double) -> Bool {
        MosaicApplyGate.isActive(ranges: model.timeline.applyRanges,
                                 mapping: model.mapping,
                                 compositionTime: time,
                                 photoSourceIDs: model.timeline.photoSourceIDs)
    }

    // MARK: - 顔と矩形が互いに巻き添えにならない

    /// **これが報告された要望そのもの。** 顔を切っても矩形は効いたまま。
    func test_turningFaceOff_keepsObjectMosaicOn() {
        let (model, _) = modelWithClip()
        model.enterDock(.mosaic)
        model.enterDock(.face)
        XCTAssertTrue(model.faceMosaicOn, "前提: 顔が点いている")
        XCTAssertTrue(model.objectMosaicOn, "前提: 矩形が点いている")

        model.toggleDockEffect(.face)

        XCTAssertFalse(model.faceMosaicOn)
        XCTAssertTrue(model.objectMosaicOn, "顔を切ったら矩形まで切れた（従属が残っている）")
    }

    /// 逆向き。矩形を切っても顔は効いたまま。
    func test_turningObjectMosaicOff_keepsFaceOn() {
        let (model, _) = modelWithClip()
        model.enterDock(.mosaic)
        model.enterDock(.face)

        model.toggleObjectMosaic()

        XCTAssertFalse(model.objectMosaicOn)
        XCTAssertTrue(model.faceMosaicOn, "矩形を切ったら顔まで切れた")
    }

    // MARK: - 矩形の段の副作用

    /// **矩形の段に入っても顔モザイクは点かない。**
    /// 矩形を 1 個置くだけのつもりで、写っている全員にモザイクが乗るのを防ぐ。
    func test_enteringRectangleRoute_doesNotTurnFaceMosaicOn() {
        let (model, _) = modelWithClip()
        XCTAssertFalse(model.faceMosaicOn, "前提: 動画の既定は顔 OFF")

        model.enterDock(.mosaic)
        model.enterDock(.rectangle)

        XCTAssertFalse(model.faceMosaicOn, "矩形の段に入っただけで顔モザイクが点いた")
        XCTAssertTrue(model.objectMosaicOn, "矩形の段に入ったのに矩形が点かない")
        XCTAssertTrue(model.isRectangleToolActive, "矩形を置くモードが上がっていない")
    }

    /// 段に入ると適用区間も確保される（区間 0 本は「全区間 OFF」なので、
    /// フラグだけ立てても何も描かれない）。
    func test_enteringRectangleRoute_restoresApplyRanges() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.removeMosaicApplyRange(id: rangeID)
        XCTAssertFalse(isMosaicOn(model, at: 1), "前提: 区間を消した")

        model.enterDock(.mosaic)
        model.enterDock(.rectangle)

        XCTAssertTrue(isMosaicOn(model, at: 1), "矩形の段に入っても区間が復活しない")
    }

    /// 切ってあった矩形は、段に入り直すと点く（「かける」導線が繋がっている）。
    func test_reenteringRectangleRoute_turnsObjectMosaicBackOn() {
        let (model, _) = modelWithClip()
        model.enterDock(.mosaic)
        model.enterDock(.rectangle)
        model.toggleObjectMosaic()
        XCTAssertFalse(model.objectMosaicOn, "前提: 切ってある")

        model.dockDone()
        model.enterDock(.mosaic)
        model.enterDock(.rectangle)

        XCTAssertTrue(model.objectMosaicOn, "段に入り直しても矩形が点かない")
    }

    /// 切ってから点け直すと適用区間も戻る。
    func test_togglingObjectMosaicBackOn_restoresApplyRanges() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.toggleObjectMosaic()   // OFF
        model.removeMosaicApplyRange(id: rangeID)
        model.toggleObjectMosaic()   // ON

        XCTAssertTrue(model.objectMosaicOn)
        XCTAssertTrue(isMosaicOn(model, at: 1), "点け直したのに区間が無いまま")
    }

    // MARK: - 矩形を描く操作

    /// **描いた矩形が無言で出ない状態を作らない。**
    /// 切ってある間に矩形を描いたら、それは「ここを隠す」という意思表示なので点け直す。
    func test_drawingARectangle_turnsObjectMosaicOnAndSecuresRanges() throws {
        let (model, _) = modelWithClip()
        let rangeID = try XCTUnwrap(model.timeline.applyRanges.first?.id)
        model.toggleObjectMosaic()   // OFF
        model.removeMosaicApplyRange(id: rangeID)

        model.appendObjectMask(compositionRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))

        XCTAssertEqual(model.objectMasks.count, 1, "前提: 矩形が置かれている")
        XCTAssertTrue(model.objectMosaicOn, "矩形を描いたのに切れたまま（画面に出ない）")
        XCTAssertTrue(isMosaicOn(model, at: 1), "矩形を描いたのに適用区間が無い")
    }

    /// 矩形を描いても顔モザイクは点かない（独立の逆方向）。
    func test_drawingARectangle_doesNotTurnFaceMosaicOn() {
        let (model, _) = modelWithClip()
        model.appendObjectMask(compositionRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        XCTAssertFalse(model.faceMosaicOn, "矩形を描いただけで顔モザイクが点いた")
    }

    // MARK: - Undo / 素材の切り替え

    /// undo で矩形の ON/OFF も戻る（顔だけ戻って矩形が取り残されない）。
    func test_undoRestoresObjectMosaicFlag() {
        let (model, _) = modelWithClip()
        XCTAssertTrue(model.objectMosaicOn, "前提: 既定は ON")

        // 実アプリでは load → resetHistory が undo の基準（lastCommitted）を作るが、
        // このテストは load を通さずモデルを直接組んでいるため基準が無い。
        // 基準が無いと commitEdit は undoStack に積まず、undo が空スタックで
        // 即 return してしまうので、トグルの前に自前で基準を作る。
        model.commitEdit()

        model.toggleObjectMosaic()
        XCTAssertFalse(model.objectMosaicOn)

        model.undo()

        XCTAssertTrue(model.objectMosaicOn, "undo で矩形の ON/OFF が戻らない")
    }

    // MARK: - 下書き

    /// 切った状態が下書きに残ること。
    func test_draftRoundTripsObjectMosaicFlag() throws {
        let draft = EditingDraft(
            kind: .video, sourceFileName: "s.mov",
            faceMosaicOn: true, objectMosaicOn: false,
            backgroundMosaicOn: false, faceBlockSize: 28, backgroundBlockSize: 28,
            objectMasks: [], thumbnailFileName: nil)
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(EditingDraft.self, from: data)

        XCTAssertFalse(decoded.objectMosaicOn, "切ってあった矩形が下書きの往復で点き直した")
    }

    /// **この項目より前の下書きは true**（キー無し）。矩形が保存されている下書きを
    /// 開いたときに、無言でモザイクが消える方へ倒さない（プライバシー上、
    /// 消える方向の既定は取れない）。
    func test_draftWithoutObjectMosaicKey_decodesAsOn() throws {
        let json = """
        {"id":"AAAA1111-2222-3333-4444-555566667777",
         "kind":"video",
         "sourceFileName":"old.mov",
         "faceMosaicOn":true,
         "backgroundMosaicOn":false,
         "faceBlockSize":28,
         "backgroundBlockSize":28}
        """
        let draft = try JSONDecoder().decode(EditingDraft.self, from: Data(json.utf8))
        XCTAssertTrue(draft.objectMosaicOn,
                      "矩形のキーが無い下書きが OFF に化けている（開いた瞬間モザイクが消える）")
    }

    /// 復元で切った状態が入ること。
    func test_applyRestoredParameters_carriesObjectMosaicFlag() {
        let model = makeModel()
        model.applyRestoredParameters(
            faceMosaicOn: true, objectMosaicOn: false, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28, objectMasks: [])
        XCTAssertFalse(model.objectMosaicOn, "下書きの矩形 OFF が復元されない")
    }
}
