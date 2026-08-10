import XCTest
import MosaicCore
@testable import MaskMe

/// 顔一覧を「人物」単位で見せる層（S2）。
///
/// 検出顔をそのまま並べていた頃は、同じ人がフレームアウト→再入するたびに一覧が増え、
/// 片方だけ選択が外れると「同じ人が区間によって隠れたり隠れなかったりする」状態になった。
/// ここでは **まとめ方** と **人物単位の選択** の契約を固定する。
@MainActor
final class PersonSelectionTests: XCTestCase {

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

    private func makeSignature(axis: Int) -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis] = 1
        return FaceSignature(rawValues: values)!
    }

    // MARK: - まとめ方

    func test_samePersonCollapsesIntoOneChip() {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: person),
                               target(cx: 0.8, cy: 0.8, personID: person)]

        XCTAssertEqual(model.personGroups.count, 1, "同じ人が一覧で 2 人に割れている")
        XCTAssertEqual(model.personGroups.first?.members.count, 2)
    }

    /// 署名が取れていない顔（`personID == nil`）は**まとめない**。
    /// まとめると別人を巻き添えで選択解除し、隠すべき人が素で映る。
    func test_facesWithoutSignatureStaySeparate() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: nil),
                               target(cx: 0.8, cy: 0.8, personID: nil)]

        XCTAssertEqual(model.personGroups.count, 2,
                       "署名の無い顔をひとまとめにしている（別人を同一視する）")
    }

    func test_differentPersonsStaySeparate() {
        let model = makeModel()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: UUID()),
                               target(cx: 0.8, cy: 0.8, personID: UUID())]
        XCTAssertEqual(model.personGroups.count, 2)
    }

    // MARK: - 人物単位の選択

    /// まとまり内の全員が同じ状態に揃うこと。片方だけ残ると、その人は区間によって
    /// 隠れたり隠れなかったりする。
    func test_togglePersonAppliesToEveryMember() throws {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: person),
                               target(cx: 0.8, cy: 0.8, personID: person)]

        let group = try XCTUnwrap(model.personGroups.first)
        model.togglePerson(group.memberIDs)
        XCTAssertTrue(model.detectedFaces.allSatisfy(\.isSelected),
                      "まとまりの一部しか選択されていない")

        model.togglePerson(group.memberIDs)
        XCTAssertTrue(model.detectedFaces.allSatisfy { !$0.isSelected },
                      "まとまりの一部しか解除されていない")
    }

    /// 状態がばらけていたら「解除」に揃える（`isSelected` の見せ方が
    /// 「誰か 1 人でも選択なら選択」なので、次のタップは解除でなければ手応えが合わない）。
    func test_togglePersonWithMixedStateTurnsEveryoneOff() throws {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: person, isSelected: true),
                               target(cx: 0.8, cy: 0.8, personID: person, isSelected: false)]

        let group = try XCTUnwrap(model.personGroups.first)
        XCTAssertTrue(group.isSelected)
        model.togglePerson(group.memberIDs)
        XCTAssertTrue(model.detectedFaces.allSatisfy { !$0.isSelected })
    }

    func test_togglePersonDoesNotTouchOtherPersons() {
        let model = makeModel()
        let person = UUID()
        model.detectedFaces = [target(cx: 0.3, cy: 0.3, personID: person),
                               target(cx: 0.8, cy: 0.8, personID: UUID(), isSelected: true)]

        model.togglePerson([model.detectedFaces[0].id])
        XCTAssertTrue(model.detectedFaces[0].isSelected)
        XCTAssertTrue(model.detectedFaces[1].isSelected, "無関係の人物の選択が巻き添えで動いた")
    }

    // MARK: - 署名の記録

    /// ライブ検出と同じ経路で署名を渡すと、署名キャッシュに顔と対で記録され、
    /// ターゲットに人物 ID が付くこと。
    func test_signaturesFromLiveDetectionArePairedWithFaces() {
        let model = makeModel()
        let faces = [fakeFace(cx: 0.3, cy: 0.3)]
        let signature = makeSignature(axis: 0)
        model.storeLiveDetection(faces, at: model.liveBucket(1.0), source: UIImage(),
                                 signatures: [signature])

        XCTAssertEqual(model.detectedFaces.count, 1)
        XCTAssertNotNil(model.detectedFaces[0].personID, "人物 ID が付いていない")
        XCTAssertEqual(model.personRegistry.persons.count, 1)

        let (sourceID, sourceTime) = model.resolveSourceTime(atComposition: model.liveBucket(1.0))
        let stored = model.signatureCache.signatures(for: faces, sourceID: sourceID,
                                                     time: sourceTime)
        XCTAssertEqual(stored, [signature], "署名が顔と対で記録されていない")
    }

    /// 署名を渡さない従来の呼び出しでは、人物 ID は付かず署名キャッシュも空のまま
    /// （＝既存の挙動が変わらない）。
    func test_detectionWithoutSignaturesLeavesIdentityUntouched() {
        let model = makeModel()
        model.storeLiveDetection([fakeFace(cx: 0.3, cy: 0.3)], at: model.liveBucket(1.0),
                                 source: UIImage())

        XCTAssertNil(model.detectedFaces.first?.personID)
        XCTAssertTrue(model.signatureCache.isEmpty)
        XCTAssertTrue(model.personRegistry.persons.isEmpty)
    }

    // MARK: - 描画の絞り込み（S3）

    /// 2 人ぶんの署名つきフレームを流し、片方だけを選択した状態を作る。
    /// - Returns: 選択したターゲット（人物 A）。
    private func setUpTwoPeople(_ model: MosaicEditorModel, at t: Double) -> FaceTarget {
        model.storeLiveDetection([fakeFace(cx: 0.2, cy: 0.5), fakeFace(cx: 0.8, cy: 0.5)],
                                 at: model.liveBucket(t), source: UIImage(),
                                 signatures: [makeSignature(axis: 0), makeSignature(axis: 1)])
        XCTAssertEqual(model.detectedFaces.count, 2)
        model.detectedFaces[0].isSelected = true
        return model.detectedFaces[0]
    }

    /// **選んだ人がフレームアウトして別の位置から戻っても隠れること。**
    /// 位置だけで見ていた頃は重心が 0.5 以上離れた時点で外れ、素で映っていた。
    func test_selectedPersonStaysHiddenAfterMovingFarAway() {
        let model = makeModel()
        let selected = setUpTwoPeople(model, at: 1.0)
        XCTAssertNotNil(selected.personID, "前提: 人物が同定できている")

        // 画面の反対側（重心距離 0.7）に、同じ人物の署名を持つ顔が 1 つだけ現れる。
        model.storeLiveDetection([fakeFace(cx: 0.9, cy: 0.5)], at: model.liveBucket(2.0),
                                 source: UIImage(), signatures: [makeSignature(axis: 0)])

        let shown = model.displayFaces(at: model.liveBucket(2.0),
                                       matching: model.detectedFaces.filter(\.isSelected))
        XCTAssertEqual(shown.count, 1, "選んだ人が位置の都合で素のまま映っている")
    }

    /// **選んでいない人が隣に来ても巻き添えで隠れないこと。**
    /// 位置だけで見ていた頃は重心 0.5 以内というだけで隠れていた。
    func test_confidentStrangerNextToSelectedPersonIsNotHidden() {
        let model = makeModel()
        _ = setUpTwoPeople(model, at: 1.0)

        // 選んだ人（0.2）のすぐ隣（0.25）に、別人の署名を持つ顔が立つ。
        model.storeLiveDetection([fakeFace(cx: 0.2, cy: 0.5), fakeFace(cx: 0.25, cy: 0.5)],
                                 at: model.liveBucket(2.0), source: UIImage(),
                                 signatures: [makeSignature(axis: 0), makeSignature(axis: 1)])

        let shown = model.displayFaces(at: model.liveBucket(2.0),
                                       matching: model.detectedFaces.filter(\.isSelected))
        XCTAssertEqual(shown.count, 1, "別人と言い切れる顔まで隠している")
        XCTAssertEqual(shown.first.map { CGFloat(model.normalizedCentroid(of: $0).x) } ?? -1,
                       0.2, accuracy: 0.01, "隠したのが選んだ人ではない")
    }

    /// 署名が無いフレームでは従来どおり位置追跡だけで判定すること
    /// （ここを「決め手が無いから隠す」に倒すと画面の全員が隠れる）。
    func test_framesWithoutSignaturesKeepSpatialBehaviour() {
        let model = makeModel()
        _ = setUpTwoPeople(model, at: 1.0)

        model.storeLiveDetection([fakeFace(cx: 0.2, cy: 0.5), fakeFace(cx: 0.8, cy: 0.5)],
                                 at: model.liveBucket(5.0), source: UIImage())

        let shown = model.displayFaces(at: model.liveBucket(5.0),
                                       matching: model.detectedFaces.filter(\.isSelected))
        XCTAssertEqual(shown.count, 1, "署名の無いフレームで全員が隠れている（または誰も隠れていない）")
    }

    /// 追跡が続いているターゲットは、向きが変わっても**同じ人物のまま**でいること
    /// （毎フレーム `register` し直すと、類似度が落ちた瞬間に一覧で 2 人に割れる）。
    func test_trackedTargetKeepsItsPersonAcrossFrames() {
        let model = makeModel()
        let face = fakeFace(cx: 0.3, cy: 0.3)
        model.storeLiveDetection([face], at: model.liveBucket(1.0), source: UIImage(),
                                 signatures: [makeSignature(axis: 0)])
        let firstPerson = model.detectedFaces.first?.personID
        XCTAssertNotNil(firstPerson)

        // 別人に見えるほど違う署名が来ても、追跡中のターゲットの人物 ID は変わらない。
        model.storeLiveDetection([face], at: model.liveBucket(1.5), source: UIImage(),
                                 signatures: [makeSignature(axis: 1)])
        XCTAssertEqual(model.detectedFaces.first?.personID, firstPerson,
                       "追跡中のターゲットの人物 ID が付け替わった（一覧で人が割れる）")
        XCTAssertEqual(model.personRegistry.persons.count, 1,
                       "別人として新規登録された（乗り移りで人物が増える）")
    }
}
