import CoreGraphics
import XCTest
@testable import MosaicCore

/// 下書きを再開したときの「隠す顔」の結び直し。
///
/// ここで守るのは 2 つ:
/// - 人物が同定できているなら**位置が変わっていても**選択が付いてくること（S5 の目的）
/// - 説明できない目印が残ったら**全選択**へ倒すこと（露出させない側の担保）
final class DraftSelectionResolverTests: XCTestCase {

    private let threshold: CGFloat = 0.5

    private func face(_ x: CGFloat, _ y: CGFloat, person: UUID? = nil)
        -> DraftSelectionResolver.Face {
        DraftSelectionResolver.Face(personID: person, centroid: CGPoint(x: x, y: y))
    }

    private func anchor(_ x: CGFloat, _ y: CGFloat, person: UUID? = nil)
        -> DraftSelectionResolver.Anchor {
        DraftSelectionResolver.Anchor(personID: person, centroid: CGPoint(x: x, y: y))
    }

    // MARK: - 人物照合

    /// **S5 の中心**: 保存時と別の場所に居ても、同じ人なら選択が付いてくる。
    /// 位置照合だけの頃はここで全選択（＝隠していない人まで隠す）へ倒れていた。
    func test_personMatchIgnoresPosition() {
        let alice = UUID(), bob = UUID()
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5, person: alice)],
            faces: [face(0.9, 0.9, person: alice), face(0.2, 0.5, person: bob)],
            centroidThreshold: threshold)
        XCTAssertTrue(result.isFullyExplained)
        XCTAssertEqual(result.selected, [0],
                       "人物で照合できているのに、保存時の位置に居る別人を選んでいる")
    }

    /// 人物が一致した目印は、位置照合へ落ちない（落ちると隣の別人を巻き込む）。
    func test_personMatchDoesNotAlsoTakeTheNeighbourAtTheSavedPosition() {
        let alice = UUID(), bob = UUID()
        // alice は保存位置のすぐ隣（位置照合なら両方拾える距離）に居る。
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.5, 0.5, person: alice)],
            faces: [face(0.55, 0.5, person: alice), face(0.45, 0.5, person: bob)],
            centroidThreshold: threshold)
        XCTAssertEqual(result.selected, [0], "位置が近い別人まで選択されている")
    }

    /// 同じ人物 ID の顔が複数あれば全部選ぶ（フレームアウト→再入で 2 件に割れた場合）。
    func test_allFacesOfTheSamePersonAreSelected() {
        let alice = UUID()
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5, person: alice)],
            faces: [face(0.1, 0.1, person: alice), face(0.9, 0.9, person: alice),
                    face(0.5, 0.5, person: UUID())],
            centroidThreshold: threshold)
        XCTAssertEqual(result.selected, [0, 1])
    }

    // MARK: - 位置照合へのフォールバック

    /// 人物 ID の無い目印（署名が取れなかった顔・旧下書き）は従来どおり位置で照合する。
    func test_anchorWithoutPersonFallsBackToPosition() {
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5)],
            faces: [face(0.25, 0.5), face(0.9, 0.5)],
            centroidThreshold: threshold)
        XCTAssertTrue(result.isFullyExplained)
        XCTAssertEqual(result.selected, [0])
    }

    /// 人物 ID はあるが、その人物の顔が今は同定できていない場合も位置へ落ちる
    /// （署名が取れるのは数フレームに 1 回なので、再開直後は普通に起きる）。
    func test_unresolvedPersonFallsBackToPosition() {
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5, person: UUID())],
            faces: [face(0.25, 0.5, person: nil), face(0.9, 0.5, person: UUID())],
            centroidThreshold: threshold)
        XCTAssertEqual(result.selected, [0])
    }

    // MARK: - 安全側

    /// 説明できない目印が 1 つでも残れば全選択（隠していた顔の行方が不明＝露出しうる）。
    func test_unexplainedAnchorSelectsEveryFace() {
        let alice = UUID()
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5, person: alice), anchor(0.9, 0.9, person: UUID())],
            faces: [face(0.2, 0.5, person: alice), face(0.5, 0.1, person: UUID())],
            centroidThreshold: threshold)
        XCTAssertFalse(result.isFullyExplained)
        XCTAssertEqual(result.selected, [0, 1], "説明できない目印が残ったのに全選択へ倒れていない")
    }

    /// 目印 0 件（保存時にどの顔も選んでいなかった）は「全部説明できた・選択 0」。
    /// ここで全選択へ倒すと、ユーザーが明示的に外した選択が再開のたびに復活する。
    func test_noAnchorsSelectsNothing() {
        let result = DraftSelectionResolver.resolve(
            anchors: [],
            faces: [face(0.2, 0.5, person: UUID())],
            centroidThreshold: threshold)
        XCTAssertTrue(result.isFullyExplained)
        XCTAssertTrue(result.selected.isEmpty)
    }

    /// 顔が 1 つも無ければ選びようがない（呼び出し側が保留する状況）。
    func test_noFacesYieldsNothingAndReportsUnexplained() {
        let result = DraftSelectionResolver.resolve(
            anchors: [anchor(0.2, 0.5, person: UUID())], faces: [],
            centroidThreshold: threshold)
        XCTAssertTrue(result.selected.isEmpty)
        XCTAssertFalse(result.isFullyExplained)
    }

    // MARK: - 台帳への取り込み

    /// 復元した人物は **ID を保ったまま**台帳へ入る（振り直すと目印が迷子になる）。
    func test_mergeKeepsPersonIDsAndDoesNotDuplicate() {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[0] = 1
        guard let signature = FaceSignature(rawValues: values) else {
            return XCTFail("テストの前提が壊れている")
        }
        let restored = PersonProfile(id: UUID(), exemplars: [signature])
        var registry = PersonRegistry()
        registry.merge([restored])
        XCTAssertEqual(registry.person(id: restored.id)?.id, restored.id)

        registry.merge([restored])
        XCTAssertEqual(registry.persons.count, 1, "同じ人物を二重に取り込んでいる")

        // 取り込んだ人物は、以後の署名照合でその ID を返す（＝目印と結び付く）。
        XCTAssertEqual(registry.register(signature), restored.id,
                       "復元した人物に似た署名が、別人として新規登録されている")
    }
}
