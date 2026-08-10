import Foundation
import UIKit
import XCTest
import MosaicCore
@testable import MaskMe

/// 動画の途中から現れた人物を、顔一覧（`detectedFaces`）へ自動で足す機能（S6b）。
///
/// 判定そのもの（何回・何秒見えたら確定するか）の境界条件は
/// `MosaicCoreTests/EmergingPersonArbiterTests` が固定している。ここでは
/// **アプリ層の配線**——署名を測ったフレームが実際に届くこと、確定した人物が
/// 正しい形（選択済み・人物ID付き・並行配列が壊れない・undo で消えない）で
/// `detectedFaces` に反映されることを固定する。
@MainActor
final class PersonAdmissionTests: XCTestCase {

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

    private func target(cx: Double, cy: Double, personID: UUID?,
                        isSelected: Bool = false) -> FaceTarget {
        FaceTarget(id: UUID(), landmarks: fakeFace(cx: cx, cy: cy),
                   thumbnail: UIImage(), isSelected: isSelected,
                   sourceID: nil, personID: personID)
    }

    /// 128次元のうち1軸だけを立てた署名。異なる軸どうしは直交する（＝別人）ため、
    /// 「この人物」を軸番号で作り分けられる。
    private func makeSignature(axis: Int) -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis] = 1
        return FaceSignature(rawValues: values)!
    }

    /// `EmergingPersonArbiter` の既定閾値（別バケット3回・1秒以上の幅）どおりに
    /// 3 回観測を送って確定させる。
    private func admitOverThreeHits(_ model: MosaicEditorModel, axis: Int,
                                    sourceID: UUID, startTime: Double) {
        let signature = makeSignature(axis: axis)
        for t in [startTime, startTime + 0.5, startTime + 1.0] {
            model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                       sourceID: sourceID, sourceTime: t, frame: UIImage())
        }
    }

    // MARK: - Step 2: 署名を測ったフレームの配線

    /// **ライブ検出の間引き**: 0.5s（`signatureIntervalSec`）未満の間隔で2回投げたとき、
    /// `signatureSource`（原寸フレームの取り出し口）の評価は1回だけであること。
    ///
    /// 変異: 原寸の取り出しを間引き判定（`beginSignatureIntervalIfDue`）より前へ移す
    /// → この変異で落ちることを確認してから実装を復元すること。
    func test_submitPreviewFrame_doesNotEvaluateNativeFrameWhenThrottled() async throws {
        try XCTSkipUnless(FaceSignatureProvider.shared.isAvailable, "sface.onnx が見つかりません")
        let images = FixtureLoader.images(in: "faces")
        try XCTSkipIf(images.isEmpty, "Fixtures/faces に顔画像がありません")
        guard let cg = images[0].cgImage else { throw XCTSkip("CGImage 化できません") }

        let model = makeModel()
        let counter = EvaluationCounter()

        model.submitPreviewFrameForDetection(cg, at: 0.0) { counter.increment(); return cg }
        try await waitForDetectionIdle(model)
        // signatureIntervalSec(0.5s) 未満の間隔で2回目を投げる → 間引かれるはず。
        model.submitPreviewFrameForDetection(cg, at: 0.1) { counter.increment(); return cg }
        try await waitForDetectionIdle(model)
        // liveSignatureQueue（検出とは別キュー）が追いつくのを待つ。
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(counter.count, 1,
                       "0.5s 未満の間隔で signatureSource が複数回評価されている（間引きが効いていない）")
    }

    private func waitForDetectionIdle(_ model: MosaicEditorModel, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.liveDetectionInFlight {
            if Date() > deadline { XCTFail("ライブ検出が \(timeout)s で完了しなかった"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Step 3: 追加の配線

    func test_admission_addsNewPersonAsSelectedTarget() {
        let model = makeModel()
        admitOverThreeHits(model, axis: 0, sourceID: UUID(), startTime: 0.0)
        XCTAssertEqual(model.detectedFaces.count, 1)
        XCTAssertEqual(model.detectedFaces.first?.isSelected, true,
                       "自動追加した顔が未選択になっている（選択数==検出数の近道が壊れる）")
    }

    func test_admission_setsPersonIDFromRegistry() {
        let model = makeModel()
        admitOverThreeHits(model, axis: 1, sourceID: UUID(), startTime: 0.0)
        guard let personID = model.detectedFaces.first?.personID else {
            return XCTFail("人物IDが付いていない")
        }
        XCTAssertNotNil(model.personRegistry.person(id: personID),
                        "detectedFaces の personID が台帳に無い")
    }

    func test_admission_isScopedToObservedSource() {
        let model = makeModel()
        let sourceA = UUID(), sourceB = UUID()
        let signature = makeSignature(axis: 2)

        model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                   sourceID: sourceA, sourceTime: 0.0, frame: UIImage())
        model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                   sourceID: sourceA, sourceTime: 0.5, frame: UIImage())
        // 別ソースの観測（同じ署名）を挟んでも sourceA の候補には影響しない。
        model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                   sourceID: sourceB, sourceTime: 100.0, frame: UIImage())
        XCTAssertEqual(model.detectedFaces.count, 0, "他ソースの観測だけで確定している")

        model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [signature],
                                   sourceID: sourceA, sourceTime: 1.0, frame: UIImage())
        XCTAssertEqual(model.detectedFaces.count, 1)
        XCTAssertEqual(model.detectedFaces.first?.sourceID, sourceA)
    }

    func test_admission_stopsAtSessionCap() {
        let model = makeModel()
        for person in 0..<13 {
            let base = Double(person) * 3.0   // 確定の間隔(0.5s)を十分空ける
            admitOverThreeHits(model, axis: person, sourceID: UUID(), startTime: base)
        }
        XCTAssertEqual(model.detectedFaces.count, 12, "セッション上限(12人)を超えて追加している")
    }

    /// 変異: `admitEmergingPersons` に渡す `knownPersons:` を `[]` に変える
    /// → この変異で落ちることを確認してから実装を復元すること。
    func test_admission_doesNotDuplicateExistingPerson() {
        let model = makeModel()
        let source = UUID()
        let signature = makeSignature(axis: 3)
        let personID = model.personRegistry.register(signature)!
        model.detectedFaces = [FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.5, cy: 0.5),
                                          thumbnail: UIImage(), isSelected: true,
                                          sourceID: source, personID: personID)]

        for i in 0..<20 {
            let cx = i % 2 == 0 ? 0.2 : 0.8
            model.admitEmergingPersons(faces: [fakeFace(cx: cx, cy: 0.5)], signatures: [signature],
                                       sourceID: source, sourceTime: Double(i) * 0.5, frame: UIImage())
        }
        XCTAssertEqual(model.detectedFaces.count, 1, "既知人物の署名から新規候補を作って増殖している")
    }

    /// 変異: `signature == nil` を「未知＝新規候補」扱いにする
    /// → この変異で落ちることを確認してから実装を復元すること。
    func test_admission_neverAddsWithoutSignature() {
        let model = makeModel()
        let source = UUID()
        for i in 0..<300 {
            model.admitEmergingPersons(faces: [fakeFace(cx: 0.5, cy: 0.5)], signatures: [nil],
                                       sourceID: source, sourceTime: Double(i) * 0.5, frame: UIImage())
        }
        XCTAssertEqual(model.detectedFaces.count, 0, "署名の無い顔から候補を作って追加している")
    }

    // MARK: - Step 4: 並行配列と履歴の保全

    func test_admission_keepsLiveMatchCountsAligned() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.1, cy: 0.1, personID: nil, isSelected: true)]
        model.liveMatchCounts = [5]
        model.liveSampleCount = 5

        admitOverThreeHits(model, axis: 4, sourceID: UUID(), startTime: 0.0)

        XCTAssertEqual(model.detectedFaces.count, 2)
        XCTAssertEqual(model.liveMatchCounts.count, 2)
        XCTAssertEqual(model.liveMatchCounts.last, model.liveSampleCount)
    }

    func test_admission_newTargetStartsAtFullDetectionRate() {
        let model = makeModel()
        model.liveSampleCount = 10

        admitOverThreeHits(model, axis: 5, sourceID: UUID(), startTime: 0.0)

        XCTAssertEqual(model.detectedFaces.last?.detectionRate, 100,
                       "登場直後の検出率が満点になっていない（0%だと『追えていない』誤ったサインになる）")
    }

    /// ユーザーが**既存の顔を全部外している**状態でも、新しく現れた人は選択済みで入ること。
    ///
    /// 撤去した「再検出」ボタンは、押すたびに顔一覧を作り直して選択を引き継ぎ直しており、
    /// 引き継ぎに失敗すると選択が空のまま残った（＝以降モザイクが一切掛からない）。
    /// 自動追加は既存の選択に一切触らず、**新しい人だけを選択済みで足す**ので、
    /// 「外した人は外れたまま・新しい人は隠れる」が両立する。
    func test_admission_selectsNewPersonEvenWhenEverythingElseIsDeselected() {
        let model = makeModel()
        let existing = target(cx: 0.1, cy: 0.1, personID: UUID(), isSelected: false)
        model.detectedFaces = [existing]

        admitOverThreeHits(model, axis: 9, sourceID: UUID(), startTime: 0.0)

        XCTAssertEqual(model.detectedFaces.count, 2)
        XCTAssertEqual(model.detectedFaces.first?.isSelected, false,
                       "ユーザーが外した顔が自動追加で選択し直されている")
        XCTAssertEqual(model.detectedFaces.last?.isSelected, true,
                       "新しく現れた人が未選択で入っている（その人が素通しになる）")
    }

    func test_admission_doesNotPushUndoEntry() {
        let model = makeModel()
        let undoCountBefore = model.undoStack.count
        let editVersionBefore = model.editVersion

        admitOverThreeHits(model, axis: 6, sourceID: UUID(), startTime: 0.0)

        XCTAssertEqual(model.undoStack.count, undoCountBefore, "追加が undo エントリを積んでいる")
        XCTAssertEqual(model.editVersion, editVersionBefore, "追加が editVersion を進めている")
    }

    func test_admission_reassertsSelectionAfterPendingDraftAnchors() {
        let model = makeModel()
        let otherSource = UUID()
        // detectedFaces が空の状態で復元すると目印は保留される（`pendingFaceSelectionAnchors`）。
        // この目印は別素材（otherSource）向けで、これから追加する人物の素材は含まない。
        model.applyRestoredParameters(
            faceMosaicOn: true, backgroundMosaicOn: false,
            faceBlockSize: 28, backgroundBlockSize: 28, objectMasks: [],
            faceSelections: [DraftFaceSelection(sourceID: otherSource, centroid: CGPoint(x: 0.1, y: 0.1))])

        // `currentSourceID` は「復元時点で既知の素材」に含まれるため、目印の対象素材でも
        // 一致する目印が無い場合は「非選択にする」経路を通る（`restoreFaceSelection` の doc）。
        admitOverThreeHits(model, axis: 7, sourceID: model.currentSourceID, startTime: 0.0)

        XCTAssertEqual(model.detectedFaces.count, 1)
        XCTAssertEqual(model.detectedFaces.first?.isSelected, true,
                       "保留中の下書き目印に押し戻されて追加直後の選択が外れている")
    }

    /// 変異: `detectedFaces.append(newTarget)` を `detectedFaces.insert(newTarget, at: 0)` に変える
    /// → この変異で落ちることを確認してから実装を復元すること。
    func test_admission_keepsExistingDetectionRatesUnshifted() {
        let model = makeModel()
        var existing = target(cx: 0.1, cy: 0.1, personID: nil, isSelected: true)
        existing.detectionRate = 42
        model.detectedFaces = [existing]
        model.liveMatchCounts = [7]
        model.liveSampleCount = 10

        admitOverThreeHits(model, axis: 8, sourceID: UUID(), startTime: 0.0)

        XCTAssertEqual(model.detectedFaces.count, 2)
        XCTAssertEqual(model.detectedFaces.first?.id, existing.id, "既存の顔が並び替わっている")
        XCTAssertEqual(model.detectedFaces.first?.detectionRate, 42, "既存顔の検出率が変わっている")
        XCTAssertEqual(model.liveMatchCounts.count, model.detectedFaces.count)
    }

    /// 変異: `undoStack` への注入ループ（`for i in undoStack.indices { ... }`）を削る
    /// （`lastCommitted` への注入だけ残す）→ この変異で落ちることを確認してから実装を復元すること。
    ///
    /// **なぜ「別の編集を挟んでから確定」する形にしたか**: 追加の瞬間に undoStack が
    /// 空だと、`lastCommitted` への注入だけで（undoStack への注入が無くても）
    /// たまたまテストが通ってしまう。追加**前**に既に1件 undoStack に積まれている
    /// 状態を作ることで、undoStack 側の注入だけが効く undo を踏ませる。
    func test_admission_survivesUndo() {
        let model = makeModel()
        let existing = target(cx: 0.1, cy: 0.1, personID: nil, isSelected: true)
        model.detectedFaces = [existing]
        model.commitEdit()                 // 基準スナップショット A（顔一覧＝existing）
        model.faceBlockSize += 4            // 選択とは無関係な編集で undoStack に A を積む
        model.commitEdit()                 // undoStack=[A], lastCommitted=B

        admitOverThreeHits(model, axis: 9, sourceID: UUID(), startTime: 0.0)
        guard let newID = model.detectedFaces.last?.id else { return XCTFail("追加されていない") }

        model.undo()                       // undoStack の A（追加前に積まれていた）を復元

        XCTAssertTrue(model.detectedFaces.contains { $0.id == newID },
                      "undo で追加された顔が消えている")
        XCTAssertEqual(model.detectedFaces.first { $0.id == newID }?.isSelected, true,
                       "undo で追加された顔の選択が外れている")
    }
}

/// スレッドをまたいで評価回数を数える薄いカウンタ（`signatureSource` は
/// `liveSignatureQueue` から呼ばれるため、メインスレッドのテストコードとは別スレッド）。
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
