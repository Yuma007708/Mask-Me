import XCTest
@testable import MosaicCore

/// 顔一覧を人物単位へまとめる純ロジック。
/// **まとめ間違えると隠すべき人が素で映る**ため、nil の扱いを特に固定する。
final class PersonGroupingTests: XCTestCase {

    func test_samePersonIDsCollapseIntoOneGroup() {
        let p1 = UUID(), p2 = UUID()
        let groups = PersonGrouping.groupIndices(personIDs: [p1, p2, p1])
        XCTAssertEqual(groups, [[0, 2], [1]])
    }

    /// 人物 ID の無い顔は**まとめない**。署名が取れていない顔どうしを同一視すると、
    /// 別人を巻き添えで選択解除する。
    func test_nilPersonIDsStaySeparate() {
        let groups = PersonGrouping.groupIndices(personIDs: [nil, nil, nil])
        XCTAssertEqual(groups, [[0], [1], [2]],
                       "署名の無い顔をひとまとめにしている（別人を同一視する）")
    }

    func test_mixedNilAndIDPreservesOrder() {
        let p1 = UUID()
        let groups = PersonGrouping.groupIndices(personIDs: [nil, p1, nil, p1])
        XCTAssertEqual(groups, [[0], [1, 3], [2]],
                       "最初に現れた順が崩れている（一覧の並びが毎フレーム入れ替わる）")
    }

    func test_emptyInputProducesNoGroups() {
        XCTAssertTrue(PersonGrouping.groupIndices(personIDs: []).isEmpty)
    }

    /// 全添字がちょうど 1 回ずつ現れること（顔が消える・二重に出るのを防ぐ）。
    func test_everyIndexAppearsExactlyOnce() {
        let p1 = UUID(), p2 = UUID()
        let input: [UUID?] = [p1, nil, p2, p1, nil, p2, p2]
        let flattened = PersonGrouping.groupIndices(personIDs: input).flatMap { $0 }.sorted()
        XCTAssertEqual(flattened, Array(input.indices),
                       "グループ化で顔が消えた、または二重に現れている")
    }
}
