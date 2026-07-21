import XCTest
import MosaicCore
@testable import MaskMe

/// ライブ再生の「選択層」シナリオ検証。
///
/// DValidLivePathTests は検出器〜lookupFaces までを実動画で測るが、実機のモザイク描画は
/// さらに `detectedFaces` の選択状態と `selectedLandmarks` の重心マッチングを通る。
/// この層は実機報告「フレームアウト→イン／後ろ向き→正面のあと一切モザイクが掛からない」
/// の温床だったため（redetect の選択消去・isSelected:false シード・静的位置マッチング）、
/// フェイク顔でパターン網羅する。検出器そのものはステートレスで DValid 系が担保する。
@MainActor
final class LiveScenarioTests: XCTestCase {
    private let step = 1.0 / 15.0

    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    private func fakeFace(cx: Double, cy: Double, size: Double = 0.2) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// ライブ検出1フレーム分を実機と同じ経路（storeLiveDetection）で注入する。
    private func feed(_ model: MosaicEditorModel, faces: [FaceLandmarkSet], at t: Double) {
        model.storeLiveDetection(faces, at: model.liveBucket(t), source: UIImage())
    }

    // MARK: - 冒頭に顔が写らない動画（後ろ向きスタート等）

    /// 初期スキャン・プローブが全滅した動画でも、再生中に単一顔が見つかった時点で
    /// 自動選択され、以降モザイクが掛かること（旧: isSelected:false シードで最後まで
    /// 一切モザイクなし）。
    func test_facelessOpening_autoSelectsSingleFaceOnFirstLiveHit() {
        let model = makeModel()
        // 冒頭 1s は顔なし（後ろ向き）
        for i in 0..<15 { feed(model, faces: [], at: Double(i) * step) }
        XCTAssertTrue(model.selectedLandmarks(at: 0.5).isEmpty)
        // 1s で正面を向いた
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: 1.0)
        XCTAssertEqual(model.detectedFaces.count, 1)
        XCTAssertTrue(model.detectedFaces[0].isSelected,
                      "単一顔が自動選択されず、以降一切モザイクが掛からない")
        XCTAssertFalse(model.selectedLandmarks(at: 1.0).isEmpty)
    }

    // MARK: - フレームアウト → 反対側から再イン

    /// 顔が左端でフレームアウトし、離れた位置から再インしても再捕捉して
    /// モザイクが復帰すること（旧: 顔追加時の静的位置との重心マッチングが
    /// 距離 0.5 を超えて永久に不成立）。
    func test_frameOutThenReenterFarAway_reacquiresAndMasks() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.15, cy: 0.3)], at: 0.0)
        XCTAssertFalse(model.selectedLandmarks(at: 0.0).isEmpty)
        // 1.5s フレームアウト（顔なしスキャン結果が続く）
        for i in 1...22 { feed(model, faces: [], at: Double(i) * step) }
        // 反対側（正規化距離 ≈ 0.79）から再イン
        let reentry = 23.0 * step
        feed(model, faces: [fakeFace(cx: 0.85, cy: 0.7)], at: reentry)
        XCTAssertFalse(model.selectedLandmarks(at: reentry).isEmpty,
                       "再イン後にモザイクが復帰しない")
        // ターゲット位置が最新の検出位置へ追従している（次フレーム以降のマッチ前提）
        let c = model.normalizedCentroid(of: model.detectedFaces[0].landmarks)
        XCTAssertEqual(Double(c.x), 0.85, accuracy: 0.01)
    }

    /// フレームアウト中（瞬きホールド 0.25s を超えた後）は、体・背景に
    /// モザイクを貼り続けないこと。
    func test_whileFaceIsGone_mosaicDoesNotStick() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.3)], at: 0.0)
        for i in 1...22 { feed(model, faces: [], at: Double(i) * step) }
        XCTAssertTrue(model.selectedLandmarks(at: 0.8).isEmpty,
                      "顔なし区間に古い顔位置のモザイクが残っている")
    }

    // MARK: - 後ろ向き → 正面（同位置で検出が途切れて戻る）

    func test_turnAwayThenBack_masksResume() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: 0.0)
        // 2s 後ろを向く
        for i in 1...30 { feed(model, faces: [], at: Double(i) * step) }
        // 正面に戻る
        let back = 31.0 * step
        feed(model, faces: [fakeFace(cx: 0.52, cy: 0.41)], at: back)
        XCTAssertFalse(model.selectedLandmarks(at: back).isEmpty,
                       "正面に戻ってもモザイクが復帰しない")
    }

    // MARK: - 再検出ボタンの選択引き継ぎ（redetect の中核ロジック）

    /// 近い位置で再検出された顔は選択が引き継がれ、他は非選択のままになること。
    func test_carryOverSelection_keepsNearbySelection() {
        let model = makeModel()
        let selectedOld = FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.3, cy: 0.4),
                                     thumbnail: UIImage(), isSelected: true)
        let new = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.32, cy: 0.42),
                       thumbnail: UIImage(), isSelected: false),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.9, cy: 0.9),
                       thumbnail: UIImage(), isSelected: false)
        ]
        let result = model.carryingOverSelection(new, previousSelected: [selectedOld])
        XCTAssertTrue(result[0].isSelected)
        XCTAssertFalse(result[1].isSelected)
    }

    /// 旧選択と誰もマッチしなくても、全選択にフォールバックして「再検出を押したら
    /// モザイクが全消えして二度と掛からない」を起こさないこと（実機報告の直接原因）。
    func test_carryOverSelection_failsClosedWhenNoMatch() {
        let model = makeModel()
        let selectedOld = FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.1, cy: 0.1),
                                     thumbnail: UIImage(), isSelected: true)
        let new = [FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.9, cy: 0.9),
                              thumbnail: UIImage(), isSelected: false)]
        let result = model.carryingOverSelection(new, previousSelected: [selectedOld])
        XCTAssertTrue(result.allSatisfy(\.isSelected),
                      "選択が空になり以降モザイクが一切掛からなくなる")
    }

    /// 旧選択が空（全消去状態から押した）でも全選択になること。
    func test_carryOverSelection_selectsAllWhenNothingWasSelected() {
        let model = makeModel()
        let new = [FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.5, cy: 0.5),
                              thumbnail: UIImage(), isSelected: false)]
        let result = model.carryingOverSelection(new, previousSelected: [])
        XCTAssertTrue(result[0].isSelected)
    }

    // MARK: - 複数顔・部分選択

    /// 2人写っていて片方だけ選択したとき、選択した顔が動いてもターゲット位置が
    /// 追従し、モザイクは選択顔だけに掛かり続けること。
    func test_partialSelection_tracksMovingSelectedFace() {
        let model = makeModel()
        // 2 顔検出 → 複数顔は自動選択されない → 1人目だけ選択
        feed(model, faces: [fakeFace(cx: 0.2, cy: 0.2), fakeFace(cx: 0.8, cy: 0.8)], at: 0.0)
        XCTAssertEqual(model.detectedFaces.count, 2)
        model.toggleFace(model.detectedFaces[0].id)

        // 1人目が縦方向へ段階的に移動（1 ステップの移動は 0.5 未満）
        var y = 0.2
        for i in 1...4 {
            y += 0.15
            feed(model, faces: [fakeFace(cx: 0.2, cy: y), fakeFace(cx: 0.8, cy: 0.8)],
                 at: Double(i) * step)
        }
        let landmarks = model.selectedLandmarks(at: 4.0 * step)
        XCTAssertEqual(landmarks.count, 1, "選択した顔以外にモザイクが掛かっている/消えている")
        let c = model.normalizedCentroid(of: landmarks[0])
        XCTAssertEqual(Double(c.y), 0.8, accuracy: 0.01, "移動した選択顔を追従できていない")
    }

    /// 複数顔・部分選択では、単一顔の無条件再捕捉規則が誤発動しないこと
    /// （非選択の顔しか残っていないフレームで選択顔のモザイクが飛び移らない）。
    func test_partialSelection_doesNotJumpToUnselectedFace() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.2, cy: 0.2), fakeFace(cx: 0.8, cy: 0.8)], at: 0.0)
        model.toggleFace(model.detectedFaces[0].id)
        // 選択顔（0.2,0.2）がフレームアウトし、非選択顔だけが残る
        for i in 1...5 {
            feed(model, faces: [fakeFace(cx: 0.8, cy: 0.8)], at: Double(i) * step)
        }
        let landmarks = model.selectedLandmarks(at: 5.0 * step)
        XCTAssertTrue(landmarks.isEmpty, "非選択の顔へモザイクが飛び移っている")
    }

    // MARK: - フロー橋渡し（横顔・急な頭部回転で検出が全滅した区間の追跡補完）

    /// フロー橋渡し1フレーム分を実機と同じ経路で注入する。
    private func feedFlow(_ model: MosaicEditorModel, faces: [FaceLandmarkSet], at t: Double) {
        model.storeLiveDetection(
            LiveDetectionResult(faces: faces, bridgedByFlow: true),
            at: model.liveBucket(t), source: UIImage())
    }

    /// フロー由来の顔は detectionCache（エクスポートが参照する実検出の記録）に入らず、
    /// プレビューの lookupFaces だけがその位置を返すこと。混入するとエクスポートが
    /// 「検出済み」と誤認して自前検出をスキップし、書き出し品質が汚染される。
    func test_flowBridgedFaces_doNotEnterDetectionCache() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: 0.0)
        // 横顔化: 実検出が全滅し、フローが位置を供給
        feedFlow(model, faces: [fakeFace(cx: 0.55, cy: 0.4)], at: step)
        XCTAssertEqual(model.cacheStore.faces(sourceID: model.currentSourceID, time: step), [],
                       "フロー由来が実検出キャッシュに混入している（エクスポート汚染）")
        let looked = model.lookupFaces(at: step)
        XCTAssertFalse(looked.isEmpty, "プレビューがフロー位置を引けていない")
        let c = model.normalizedCentroid(of: looked[0])
        XCTAssertEqual(Double(c.x), 0.55, accuracy: 0.01,
                       "ホールドされた古い位置ではなくフローの追跡位置を返すべき")
        // 選択層まで含めてモザイクが出ること
        XCTAssertFalse(model.selectedLandmarks(at: step).isEmpty)
    }

    /// フロー橋渡しフレームは検出率バッジ（detectionRate）に算入されないこと。
    /// 追跡による補完は「検出できた」証拠ではないため、%が水増しされると
    /// ユーザーが検出品質を過信する。
    func test_flowBridgedFrames_excludedFromDetectionRate() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: 0.0)
        let rateAfterRealHit = model.detectedFaces[0].detectionRate
        for i in 1...5 {
            feedFlow(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: Double(i) * step)
        }
        XCTAssertEqual(model.detectedFaces[0].detectionRate, rateAfterRealHit,
                       "フロー橋渡しフレームが検出率に算入されている")
    }

    /// フロー供給が途絶えた後の時刻に、古いフロー位置が返り続けないこと
    /// （lookupFaces のフロー窓は±1バケット強のみ。貼り付き防止）。
    func test_staleFlowPosition_doesNotStickBeyondWindow() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.5, cy: 0.4)], at: 0.0)
        feedFlow(model, faces: [fakeFace(cx: 0.55, cy: 0.4)], at: step)
        // 以降は実検出もフローも無い（スキャン済み顔なし）
        for i in 2...22 { feed(model, faces: [], at: Double(i) * step) }
        XCTAssertTrue(model.selectedLandmarks(at: 20.0 * step).isEmpty,
                      "フロー供給が途絶えた区間に古いフロー位置が貼り付いている")
    }

    /// フロー追跡中も detectedFaces の位置は追従し、フロー明けの実検出と
    /// 重心マッチングが成立すること（追従が止まると、フロー中に大きく移動した顔が
    /// 復帰フレームで距離 0.5 を超えマッチ不能になる）。
    func test_flowBridging_updatesFacePositionForRematch() {
        let model = makeModel()
        feed(model, faces: [fakeFace(cx: 0.2, cy: 0.2), fakeFace(cx: 0.8, cy: 0.8)], at: 0.0)
        model.toggleFace(model.detectedFaces[0].id)
        // 選択顔がフローで段階的に移動（計 0.6: 静的マッチングなら不成立の距離）
        var x = 0.2
        for i in 1...4 {
            x += 0.15
            feedFlow(model, faces: [fakeFace(cx: x, cy: 0.2)], at: Double(i) * step)
        }
        // フロー明けに実検出が復帰
        let t = 5.0 * step
        feed(model, faces: [fakeFace(cx: 0.8, cy: 0.2), fakeFace(cx: 0.8, cy: 0.8)], at: t)
        let landmarks = model.selectedLandmarks(at: t)
        XCTAssertEqual(landmarks.count, 1, "フロー明けの実検出で選択顔を再マッチできていない")
        let c = model.normalizedCentroid(of: landmarks[0])
        XCTAssertEqual(Double(c.y), 0.2, accuracy: 0.01, "非選択顔に飛び移っている")
    }
}
