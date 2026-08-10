import MosaicCore
import XCTest
@testable import MaskMe

/// プレビュー上の顔枠（`pickableFaces`）の契約。
///
/// この一覧は**タップの的**そのものなので、「押しても何も起きない枠」「別人の上に
/// 乗った枠」を返した時点でこの機能は信用を失う。描画側（`displayFaces`）とは
/// 要件が違う（モザイクが OFF でも枠は出す）ため経路が別で、そのぶん
/// 食い違いをここで止める。
@MainActor
final class FacePickingTests: XCTestCase {
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

    private func target(cx: Double, cy: Double, personID: UUID? = nil,
                        isSelected: Bool = false) -> FaceTarget {
        FaceTarget(id: UUID(), landmarks: fakeFace(cx: cx, cy: cy),
                   thumbnail: UIImage(), isSelected: isSelected,
                   sourceID: nil, personID: personID)
    }

    /// キャッシュに顔を置き、その時刻を返す。
    @discardableResult
    private func seed(_ model: MosaicEditorModel, _ faces: [FaceLandmarkSet],
                      at time: Double = 0) -> Double {
        model.storePreScanResult(faces, at: time)
        return time
    }

    // MARK: - 何を返すか

    func test_pickableFaces_returnsOneEntryPerDetectedPerson() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.25, cy: 0.5), target(cx: 0.75, cy: 0.5)]
        seed(model, [fakeFace(cx: 0.25, cy: 0.5), fakeFace(cx: 0.75, cy: 0.5)])

        let picks = model.pickableFaces(at: 0)
        XCTAssertEqual(picks.count, 2)
        XCTAssertEqual(Set(picks.map(\.id)), Set(model.personGroups.map(\.id)))
    }

    /// **押しても何も起きない枠を出さない。** 検出はされているが
    /// `detectedFaces` のどれとも対応しない顔には的を置かない。
    ///
    /// **対応しない顔だけを置くこと。** 対応する顔と混ぜると、対応しない顔が
    /// 「すでに枠を出した人物」へ吸われて重複排除で消え、件数が変わらないため
    /// 対応づけを壊しても落ちない（実際にガードを外して通ってしまった）。
    func test_pickableFaces_omitsFacesWithNoMatchingTarget() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.1, cy: 0.1)]
        seed(model, [fakeFace(cx: 0.95, cy: 0.95)]) // 許容 0.5 の外にしか顔が無い

        XCTAssertTrue(model.pickableFaces(at: 0).isEmpty,
                      "対応する相手が居ない顔にまで枠を出している（押しても何も起きない的になる）")
    }

    /// 対応する顔と対応しない顔が混ざっているとき、**枠は対応する顔の位置に出る**。
    ///
    /// 件数だけを見ると、対応しない顔が誤って人物へ結び付いても重複排除で
    /// 消えるので気づけない。位置まで見ることで「別人の上に乗った枠」を捕まえる。
    func test_pickableFaces_withMixedFaces_anchorTheFrameToTheMatchingFace() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.1, cy: 0.1)]
        // **対応しない顔を先に置く。** 誤って結び付くなら、その位置で枠が確定してしまう。
        let stranger = fakeFace(cx: 0.9, cy: 0.9)
        let mine = fakeFace(cx: 0.1, cy: 0.1)
        seed(model, [stranger, mine])

        let picks = model.pickableFaces(at: 0)
        XCTAssertEqual(picks.count, 1)
        guard let bounds = picks.first?.bounds else { return XCTFail("枠が無い") }
        XCTAssertEqual(bounds.midX, mine.boundingBox.midX, accuracy: 0.01,
                       "対応しない顔の位置に枠が乗っている（別人を隠す操作になる）")
        XCTAssertEqual(bounds.midY, mine.boundingBox.midY, accuracy: 0.01)
    }

    /// 同じ人物に 2 つの顔が当たっても的は 1 つ。
    /// 2 つ出すと、同じ操作をする的が 2 箇所できて操作結果が読めない。
    func test_pickableFaces_collapsesDuplicatesOfTheSamePerson() {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.45, cy: 0.5, personID: person),
                               target(cx: 0.55, cy: 0.5, personID: person)]
        seed(model, [fakeFace(cx: 0.45, cy: 0.5), fakeFace(cx: 0.55, cy: 0.5)])

        XCTAssertEqual(model.personGroups.count, 1, "前提: 一覧では 1 人にまとまっている")
        XCTAssertEqual(model.pickableFaces(at: 0).count, 1, "同じ人物に的が 2 つある")
    }

    func test_pickableFaces_isEmptyWhenNothingDetected() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.5, cy: 0.5)]
        XCTAssertTrue(model.pickableFaces(at: 0).isEmpty)
    }

    func test_pickableFaces_isEmptyWithoutAnyTarget() {
        let model = makeModel()
        seed(model, [fakeFace(cx: 0.5, cy: 0.5)])
        XCTAssertTrue(model.pickableFaces(at: 0).isEmpty)
    }

    // MARK: - モザイクの状態から独立していること

    /// **枠はモザイクが OFF でも出る。** これから選ぶための表示であって、
    /// いまモザイクが乗っているかとは別。ここが `displayFaces` と決定的に違う。
    func test_pickableFaces_areShownEvenWhenFaceMosaicIsOff() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.5, cy: 0.5)]
        seed(model, [fakeFace(cx: 0.5, cy: 0.5)])

        model.faceMosaicOn = false
        XCTAssertEqual(model.pickableFaces(at: 0).count, 1,
                       "モザイクが OFF だと顔を選べない（選ぶための枠が消えている）")
        XCTAssertTrue(model.selectedLandmarks(at: 0).isEmpty,
                      "前提: 描画側は OFF で空になる（経路が別であることの確認）")
    }

    // MARK: - 選択状態

    func test_pickableFaces_reflectSelectionState() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.5, cy: 0.5, isSelected: false)]
        seed(model, [fakeFace(cx: 0.5, cy: 0.5)])

        XCTAssertEqual(model.pickableFaces(at: 0).first?.isSelected, false)
        model.togglePerson(model.pickableFaces(at: 0).first?.memberIDs ?? [])
        XCTAssertEqual(model.pickableFaces(at: 0).first?.isSelected, true,
                       "枠をタップしたのに選択状態が変わらない")
    }

    /// `memberIDs` は `togglePerson` にそのまま渡せること（人物の全員が切り替わる）。
    func test_memberIDs_toggleEveryTargetOfThatPerson() {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.45, cy: 0.5, personID: person),
                               target(cx: 0.55, cy: 0.5, personID: person)]
        seed(model, [fakeFace(cx: 0.45, cy: 0.5)])

        guard let pick = model.pickableFaces(at: 0).first else {
            return XCTFail("枠が 1 つも無い")
        }
        model.togglePerson(pick.memberIDs)
        XCTAssertTrue(model.detectedFaces.allSatisfy(\.isSelected),
                      "同じ人物のうち片方しか切り替わっていない（区間によって隠れたり隠れなかったりする）")
    }

    // MARK: - 座標

    /// 枠の位置が顔の位置に一致していること。**ここがずれると、別人の上に
    /// 枠が乗って取り違える**（このアプリでは隠したい相手を外すことに直結する）。
    func test_pickableFace_boundsMatchTheDetectedFace() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.3, cy: 0.6)]
        let face = fakeFace(cx: 0.3, cy: 0.6)
        seed(model, [face])

        guard let bounds = model.pickableFaces(at: 0).first?.bounds else {
            return XCTFail("枠が 1 つも無い")
        }
        XCTAssertEqual(bounds.midX, face.boundingBox.midX, accuracy: 0.01)
        XCTAssertEqual(bounds.midY, face.boundingBox.midY, accuracy: 0.01)
    }
}
