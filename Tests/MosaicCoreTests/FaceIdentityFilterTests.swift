import XCTest
@testable import MosaicCore

/// 描画の絞り込み（プレビューと書き出しが共有する判定）。
/// 規則の表は `FaceIdentityPolicy.hidden` の doc を参照。
final class FaceIdentityFilterTests: XCTestCase {

    private func baseSignature() -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[0] = 1
        return XCTUnwrap2(FaceSignature(rawValues: values))
    }

    /// 指定したコサイン類似度をちょうど持つ 2 本目の単位ベクトル
    /// （`FaceIdentityTests` と同じ作り方。軸を変えないと別人役どうしが近づく）。
    private func signature(similarTo base: FaceSignature, cosine: Float,
                           axis: Int = 1) -> FaceSignature {
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

    private func plainFace(_ x: Float) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [FaceLandmark(x: x, y: 0.5)], confidence: 1)
    }

    /// 人物がまだ 1 人も同定できていなければ、判定は従来どおり位置追跡だけ。
    func test_hiddenFallsBackToSpatialWhenNobodyIdentified() {
        let faces = [plainFace(0.2), plainFace(0.8)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [nil, nil],
            spatiallyMatched: [true, false], selectedPersons: [])
        XCTAssertEqual(hidden, [faces[0]])
    }

    /// 署名が「選んだ人だ」と言えば、位置が離れていても隠す
    /// （フレームアウト→別位置で再入したときに外れないため）。
    func test_hiddenCoversSelectedPersonEvenWhenSpatiallyLost() {
        let base = baseSignature()
        let person = PersonProfile(exemplars: [base])
        let faces = [plainFace(0.9)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [signature(similarTo: base, cosine: 0.8382)],
            spatiallyMatched: [false], selectedPersons: [person])
        XCTAssertEqual(hidden, faces, "選んだ人が位置の都合で素のまま映っている")
    }

    /// 署名が「別人だと言い切れる」ときだけ、位置が近くても素のまま残す
    /// （選んだ人の隣に立っただけの他人が巻き添えで隠れないため）。
    func test_hiddenLeavesConfidentStrangerAloneEvenWhenSpatiallyClose() {
        let base = baseSignature()
        let person = PersonProfile(exemplars: [base])
        let faces = [plainFace(0.5)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [signature(similarTo: base, cosine: 0.2344, axis: 2)],
            spatiallyMatched: [true], selectedPersons: [person])
        XCTAssertTrue(hidden.isEmpty, "別人と言い切れる顔まで隠している")
    }

    /// 判断保留の帯（別人と言い切れない）は隠す側。**これが「迷ったら隠す」の実体。**
    func test_hiddenCoversAmbiguousSignature() {
        let base = baseSignature()
        let person = PersonProfile(exemplars: [base])
        let ambiguous = signature(similarTo: base, cosine: 0.30, axis: 2)
        XCTAssertGreaterThan(ambiguous.similarity(to: base), FaceIdentityThreshold.distinct,
                             "前提: 判断保留の帯に入っている")
        XCTAssertLessThan(ambiguous.similarity(to: base), FaceIdentityThreshold.match)

        let faces = [plainFace(0.9)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [ambiguous],
            spatiallyMatched: [false], selectedPersons: [person])
        XCTAssertEqual(hidden, faces, "決め手が無い顔を素のまま映している")
    }

    /// 署名が無い顔（品質ゲート落ち・間引きの谷間）は位置追跡の答えに従う。
    /// ここを「隠す」に倒すと、大半のフレームで画面の全員が隠れて機能が意味を失う。
    func test_hiddenWithoutSignatureFollowsSpatial() {
        let person = PersonProfile(exemplars: [baseSignature()])
        let faces = [plainFace(0.2), plainFace(0.8)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [nil, nil],
            spatiallyMatched: [true, false], selectedPersons: [person])
        XCTAssertEqual(hidden, [faces[0]])
    }

    /// 署名の件数が顔と合わない呼び出しは、**全て署名なし**として扱う
    /// （ずれた署名で判定するくらいなら位置追跡へ落ちる）。
    func test_hiddenIgnoresMisalignedSignatures() {
        let base = baseSignature()
        let person = PersonProfile(exemplars: [base])
        let faces = [plainFace(0.2), plainFace(0.8)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [signature(similarTo: base, cosine: 0.2344, axis: 2)],
            spatiallyMatched: [true, false], selectedPersons: [person])
        XCTAssertEqual(hidden, [faces[0]],
                       "件数の合わない署名を使って判定している")
    }

    /// 位置の件数が合わない呼び出しは、絞り込みをやめて**全て隠す**
    /// （呼び出し側の組み立てが壊れている状態で、露出する側へは倒さない）。
    func test_hiddenFailsClosedWhenSpatialFlagsAreMisaligned() {
        let faces = [plainFace(0.2), plainFace(0.8)]
        let hidden = FaceIdentityPolicy.hidden(
            faces: faces, signatures: [nil, nil],
            spatiallyMatched: [true], selectedPersons: [])
        XCTAssertEqual(hidden, faces)
    }

}
