import CoreGraphics
import XCTest
@testable import MosaicCore

/// 人物同定の純ロジック。実測値（P0）を数字として焼き込み、
/// 閾値や指標番号が動いたら落ちるようにする。
final class FaceIdentityTests: XCTestCase {

    // MARK: - 署名

    /// 指定したコサイン類似度をちょうど持つ 2 本目の単位ベクトルを作る。
    ///
    /// - Parameter axis: ずらす方向。**既定のまま複数本作ると全てが同じ 2 次元平面に載り、
    ///   「base から見て遠い 2 本」同士が互いに近くなってしまう**（別人役が同一人物役に
    ///   吸い寄せられる）。独立した人物を作るときは軸を変えること。
    private func signature(similarTo base: FaceSignature, cosine: Float,
                           axis: Int = 1) -> FaceSignature {
        // base に直交する成分を 1 本用意し、cos*base + sin*perp を作る。
        var perp = [Float](repeating: 0, count: FaceSignature.dimension)
        perp[axis] = 1
        let dot = zip(base.values, perp).map(*).reduce(0, +)
        for i in perp.indices { perp[i] -= dot * base.values[i] }
        let norm = perp.map { $0 * $0 }.reduce(0, +).squareRoot()
        for i in perp.indices { perp[i] /= norm }
        let sine = (1 - cosine * cosine).squareRoot()
        let values = (0..<FaceSignature.dimension).map { cosine * base.values[$0] + sine * perp[$0] }
        return XCTUnwrap2(FaceSignature(rawValues: values))
    }

    private func XCTUnwrap2<T>(_ value: T?) -> T {
        guard let value else { fatalError("テストの前提が壊れている") }
        return value
    }

    private func baseSignature() -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[0] = 3   // 正規化されることを確かめるため、あえて単位長にしない
        return XCTUnwrap2(FaceSignature(rawValues: values))
    }

    func test_signatureRejectsWrongDimensionAndZeroVector() {
        XCTAssertNil(FaceSignature(rawValues: [Float](repeating: 1, count: 127)),
                     "次元が違うベクトルを受け付けている（モデル差し替えで無言に壊れる）")
        XCTAssertNil(FaceSignature(rawValues: [Float](repeating: 0, count: 128)),
                     "零ベクトルを受け付けている（正規化できない）")
    }

    func test_signatureIsNormalizedAndSimilarityMatchesRequestedCosine() {
        let base = baseSignature()
        let norm = base.values.map { $0 * $0 }.reduce(0, +).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-5, "L2 正規化されていない")
        XCTAssertEqual(base.similarity(to: base), 1, accuracy: 1e-5)
        for cosine in [Float(0.9), 0.5, 0.363, 0.2, 0] {
            let other = signature(similarTo: base, cosine: cosine)
            XCTAssertEqual(base.similarity(to: other), cosine, accuracy: 1e-4,
                           "cos=\(cosine) を作ったのに類似度が一致しない")
        }
    }

    func test_signatureMeanIsNormalized() {
        let base = baseSignature()
        let other = signature(similarTo: base, cosine: 0.8)
        let mean = XCTUnwrap2(FaceSignature.mean(of: [base, other]))
        let norm = mean.values.map { $0 * $0 }.reduce(0, +).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-5)
        // 平均は両者の中間にあるので、どちらとも元の 2 本同士より似ている
        XCTAssertGreaterThan(mean.similarity(to: base), base.similarity(to: other))
    }

    // MARK: - 整列 5 点

    /// 正準 UV をそのまま正規化フレーム座標に写した合成メッシュ。
    private func makeCanonicalMesh(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
        -> FaceLandmarkSet {
        let uv = FaceMeshTopology.frontalUV
        var points: [FaceLandmark] = []
        for index in 0..<FaceMeshTopology.vertexCount {
            let u = CGFloat(uv[index * 2]), v = CGFloat(uv[index * 2 + 1])
            points.append(FaceLandmark(x: Float(rect.minX + u * rect.width),
                                       y: Float(rect.minY + v * rect.height)))
        }
        while points.count < FaceLandmarkSet.fullMeshCount {
            points.append(FaceLandmark(x: Float(rect.midX), y: Float(rect.midY)))
        }
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    func test_alignmentPointsAreOrderedAsSFaceExpects() {
        let points = XCTUnwrap2(FaceAlignmentPoints.extract(from: makeCanonicalMesh()))
        XCTAssertEqual(points.count, 5)
        // 1 番目は画面左の目、2 番目は画面右の目。逆に並べると整列が別物になり、
        // エラーを出さずに同一人物の類似度だけが落ちる。
        XCTAssertLessThan(points[0].x, points[1].x, "目の左右が逆")
        XCTAssertLessThan(points[3].x, points[4].x, "口角の左右が逆")
        // 鼻先は両目の中点の真下、口角より上。
        XCTAssertEqual(points[2].x, (points[0].x + points[1].x) / 2, accuracy: 0.01)
        XCTAssertGreaterThan(points[2].y, points[0].y, "鼻先が目より上にある（y 軸の向きが逆）")
        XCTAssertLessThan(points[2].y, points[3].y, "鼻先が口角より下にある")
    }

    func test_alignmentPointsRejectPartialMesh() {
        let partial = FaceLandmarkSet(
            points: (0..<100).map { _ in FaceLandmark(x: 0.5, y: 0.5) }, confidence: 1)
        XCTAssertNil(FaceAlignmentPoints.extract(from: partial),
                     "部分メッシュから 5 点を作れてしまっている")
    }

    // MARK: - 品質ゲート

    func test_canonicalFrontalFaceIsTrustworthy() {
        let mesh = makeCanonicalMesh(in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        let quality = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(quality.noseSkew, 0, accuracy: 0.01, "正準の正面顔で正面度が 0 にならない")
        XCTAssertTrue(quality.isTrustworthy)
    }

    func test_tooSmallFaceIsNotTrustworthy() {
        // 幅 0.03 × 1920px ≒ 58px < 80px
        let mesh = makeCanonicalMesh(in: CGRect(x: 0.4, y: 0.4, width: 0.03, height: 0.05))
        let quality = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 1920, height: 1080)))
        XCTAssertLessThan(quality.facePixelWidth, FaceSignatureQuality.minimumFacePixelWidth)
        XCTAssertFalse(quality.isTrustworthy, "SFace の入力 112px を大きく下回る顔を信用している")
    }

    /// 同じ正規化幅でも、解像度が上がれば画素幅は増えて信用できるようになる。
    /// （正規化幅で足切りしていると、この 2 つが同じ判定になってしまう）
    func test_trustworthinessFollowsPixelsNotNormalizedWidth() {
        let mesh = makeCanonicalMesh(in: CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.1))
        let small = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 1280, height: 720)))
        let large = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 3840, height: 2160)))
        XCTAssertFalse(small.isTrustworthy, "1280px 幅の 0.06 = 77px は 80px を下回る")
        XCTAssertTrue(large.isTrustworthy, "3840px 幅の 0.06 = 230px を信用していない")
    }

    func test_turnedFaceIsNotTrustworthy() {
        // 鼻先だけを目の間隔の 40% 横へずらす（横向きの単純化）。
        var mesh = makeCanonicalMesh(in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        var points = mesh.points
        let eyeSpan = abs(points[263].x - points[33].x)
        points[FaceAlignmentPoints.noseTipIndex].x += eyeSpan * 0.4
        mesh = FaceLandmarkSet(points: points, confidence: 1)
        let quality = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 1920, height: 1080)))
        XCTAssertGreaterThan(quality.noseSkew, FaceSignatureQuality.maximumNoseSkew)
        XCTAssertFalse(quality.isTrustworthy, "横を向いた顔の署名を信用している")
    }

    func test_lowConfidenceFaceIsNotTrustworthy() {
        let uv = FaceMeshTopology.frontalUV
        var points: [FaceLandmark] = []
        for index in 0..<FaceMeshTopology.vertexCount {
            points.append(FaceLandmark(x: 0.3 + Float(uv[index * 2]) * 0.4,
                                       y: 0.3 + Float(uv[index * 2 + 1]) * 0.4))
        }
        while points.count < FaceLandmarkSet.fullMeshCount {
            points.append(FaceLandmark(x: 0.5, y: 0.5))
        }
        let mesh = FaceLandmarkSet(points: points, confidence: 0.2)
        let quality = XCTUnwrap2(
            FaceSignatureQuality.measure(mesh, imageSize: CGSize(width: 1920, height: 1080)))
        XCTAssertFalse(quality.isTrustworthy)
    }

    // MARK: - 人物台帳

    func test_registryGroupsSamePersonAndSeparatesDifferentPeople() {
        let base = baseSignature()
        var registry = PersonRegistry()
        // P0 実測の同一人物の最小 0.8384 / 別人の最大 0.2344 をそのまま使う。
        let sameAgain = signature(similarTo: base, cosine: 0.8384, axis: 1)
        // 別人は独立した軸に置く（同じ軸に並べると sameAgain と近接してしまう）
        let stranger = signature(similarTo: base, cosine: 0.2344, axis: 2)
        XCTAssertLessThan(sameAgain.similarity(to: stranger), FaceIdentityThreshold.match,
                          "テストの前提が壊れている: 別人役が同一人物役と似すぎている")

        let first = registry.register(base)
        let second = registry.register(sameAgain)
        let third = registry.register(stranger)

        XCTAssertEqual(first, second, "実測の同一人物ペア(0.8384)を別人にしている")
        XCTAssertNotEqual(first, third, "実測の別人ペア(0.2344)を同一人物にしている")
        XCTAssertEqual(registry.persons.count, 2, "人数が合わない")
    }

    func test_registryLeavesAmbiguousSignatureUnassigned() {
        let base = baseSignature()
        var registry = PersonRegistry()
        registry.register(base)
        // distinct(0.25) と match(0.363) の間＝判断保留の帯
        let ambiguous = signature(similarTo: base, cosine: 0.3)
        XCTAssertNil(registry.register(ambiguous), "保留の帯の署名に人物 ID を与えている")
        XCTAssertEqual(registry.persons.count, 1,
                       "保留の署名を新しい人物として登録している（人数が水増しされる）")
        XCTAssertEqual(registry.persons[0].exemplars.count, 1,
                       "保留の署名を手本にしている（人物の輪郭がぼやける）")
    }

    func test_profileKeepsDiverseExemplarsWhenFull() {
        let base = baseSignature()
        var profile = PersonProfile(exemplars: [base])
        // ほぼ同じ手本で埋めてから、明確に違う向きの手本を足す。
        for _ in 0..<PersonProfile.maximumExemplars {
            profile.add(signature(similarTo: base, cosine: 0.99))
        }
        let distinctPose = signature(similarTo: base, cosine: 0.5)
        profile.add(distinctPose)
        XCTAssertEqual(profile.exemplars.count, PersonProfile.maximumExemplars)
        XCTAssertEqual(profile.similarity(to: distinctPose), 1, accuracy: 1e-4,
                       "上限に達したとき、冗長な手本ではなく新しい向きの手本を捨てている")
    }

    // MARK: - 追跡中のターゲットへの手本追加

    /// 追跡が続いているターゲットは、向きが変わって類似度が落ちても**同じ人物のまま**
    /// 手本を足せること（`register` に任せると別人として新規登録され、一覧で 2 人に割れる）。
    func test_addExemplarKeepsTrackedTargetOnTheSamePerson() {
        let base = baseSignature()
        var registry = PersonRegistry()
        let id = XCTUnwrap2(registry.register(base))

        // 実動画の同一人物（動きあり）で観測した 0.7730 相当の落ち込み。
        let turned = signature(similarTo: base, cosine: 0.7730)
        XCTAssertTrue(registry.addExemplar(turned, toPersonWith: id),
                      "同一人物の別の向きを手本にできていない")
        XCTAssertEqual(registry.persons.count, 1, "同じ人が 2 人に割れている")
        XCTAssertEqual(registry.person(matching: turned)?.id, id)
    }

    /// 位置追跡が隣の人へ乗り移ったとき、その顔を手本として取り込まないこと。
    /// 取り込むと人物の輪郭が壊れ、以後の判定がまとめて狂う。
    func test_addExemplarRejectsSignatureFromAnotherPerson() {
        let base = baseSignature()
        var registry = PersonRegistry()
        let id = XCTUnwrap2(registry.register(base))

        let stranger = signature(similarTo: base, cosine: 0.2344, axis: 2)
        XCTAssertFalse(registry.addExemplar(stranger, toPersonWith: id),
                       "別人の顔を手本に取り込んでいる（乗り移りで人物が壊れる）")
        XCTAssertEqual(registry.person(matching: base)?.exemplars.count, 1)
        XCTAssertNil(registry.person(matching: stranger),
                     "別人がこの人物として照合できてしまっている")
    }

    func test_addExemplarToUnknownPersonIsIgnored() {
        var registry = PersonRegistry()
        XCTAssertFalse(registry.addExemplar(baseSignature(), toPersonWith: UUID()))
        XCTAssertTrue(registry.persons.isEmpty, "知らない人物 ID で人物が増えている")
    }

    // MARK: - 保存と復元（下書き用）

    /// 下書きに人物を保存して復元する経路。**位置ではなく署名を保存する**のが要点で、
    /// これが往復できないと、下書きを開き直したときに「誰を選んでいたか」が失われる。
    func test_registrySurvivesCodableRoundTrip() throws {
        let base = baseSignature()
        var registry = PersonRegistry()
        registry.register(base)
        registry.register(signature(similarTo: base, cosine: 0.9))
        registry.register(signature(similarTo: base, cosine: 0.1, axis: 3))
        XCTAssertEqual(registry.persons.count, 2)

        let data = try JSONEncoder().encode(registry)
        let restored = try JSONDecoder().decode(PersonRegistry.self, from: data)

        XCTAssertEqual(restored, registry, "台帳が往復で変わっている")
        // 復元後も「同じ人」と判定できること（ID が一致するだけでは足りない）。
        let restoredPerson = restored.person(matching: base)
        XCTAssertEqual(restoredPerson?.id, registry.person(matching: base)?.id,
                       "復元後に同じ人物へ照合できていない")
    }

    /// 署名は L2 正規化済みで保存され、復元後も正規化が保たれること。
    /// （復元時に正規化を掛け直す実装だと、僅かな丸めで類似度が動く）
    func test_signatureRoundTripPreservesSimilarity() throws {
        let base = baseSignature()
        let other = signature(similarTo: base, cosine: 0.8384)
        let data = try JSONEncoder().encode([base, other])
        let restored = try JSONDecoder().decode([FaceSignature].self, from: data)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].similarity(to: restored[1]),
                       base.similarity(to: other), accuracy: 1e-6,
                       "往復で類似度が変わっている（閾値の意味が壊れる）")
    }

    // MARK: - 判断

    private func selectedPerson() -> (PersonProfile, FaceSignature) {
        let base = baseSignature()
        return (PersonProfile(exemplars: [base]), base)
    }

    private func trustworthyQuality() -> FaceSignatureQuality {
        FaceSignatureQuality(facePixelWidth: 200, noseSkew: 0.05, confidence: 0.9)
    }

    func test_selectedPersonIsHidden() {
        let (person, base) = selectedPerson()
        let decision = FaceIdentityPolicy.decide(
            signature: signature(similarTo: base, cosine: 0.8384),
            quality: trustworthyQuality(),
            selectedPersons: [person], spatiallyMatchesSelected: false)
        XCTAssertEqual(decision, .hide(.matchedSelectedPerson))
    }

    func test_confidentlyDifferentPersonIsShown() {
        let (person, base) = selectedPerson()
        let decision = FaceIdentityPolicy.decide(
            signature: signature(similarTo: base, cosine: 0.2344),
            quality: trustworthyQuality(),
            selectedPersons: [person], spatiallyMatchesSelected: false)
        XCTAssertEqual(decision, .show, "実測の別人ペア(0.2344)を素のまま残していない")
    }

    func test_ambiguousSignatureIsHidden() {
        let (person, base) = selectedPerson()
        let decision = FaceIdentityPolicy.decide(
            signature: signature(similarTo: base, cosine: 0.3),
            quality: trustworthyQuality(),
            selectedPersons: [person], spatiallyMatchesSelected: false)
        XCTAssertEqual(decision, .hide(.ambiguousSignature), "判断保留の帯で露出させている")
    }

    /// 遮蔽で実測 0.2030 まで落ちた「同一人物」。署名を信じると素で映してしまう場面。
    /// 品質ゲートが落とすので位置追跡へ回り、当たれば隠れる。
    func test_untrustworthySignatureFallsBackToSpatialTracking() {
        let (person, base) = selectedPerson()
        let occluded = signature(similarTo: base, cosine: 0.2030)
        let poorQuality = FaceSignatureQuality(facePixelWidth: 40, noseSkew: 0.05, confidence: 0.9)
        XCTAssertFalse(poorQuality.isTrustworthy)

        let matched = FaceIdentityPolicy.decide(
            signature: occluded, quality: poorQuality,
            selectedPersons: [person], spatiallyMatchesSelected: true)
        XCTAssertEqual(matched, .hide(.spatialFallback),
                       "遮蔽された選択中の人を、位置追跡が当たっているのに露出させている")

        let unmatched = FaceIdentityPolicy.decide(
            signature: occluded, quality: poorQuality,
            selectedPersons: [person], spatiallyMatchesSelected: false)
        XCTAssertEqual(unmatched, .hide(.undetermined), "決め手が無いのに露出させている")
    }

    func test_missingSignatureIsHidden() {
        let (person, _) = selectedPerson()
        let decision = FaceIdentityPolicy.decide(
            signature: nil, quality: nil,
            selectedPersons: [person], spatiallyMatchesSelected: false)
        XCTAssertEqual(decision, .hide(.undetermined), "署名が作れない顔を露出させている")
    }

    func test_emptySelectionIsHiddenNotShown() {
        let decision = FaceIdentityPolicy.decide(
            signature: baseSignature(), quality: trustworthyQuality(),
            selectedPersons: [], spatiallyMatchesSelected: false)
        XCTAssertEqual(decision, .hide(.undetermined),
                       "選択が空のときに露出側へ倒れている（安全側に倒すこと）")
    }
}
