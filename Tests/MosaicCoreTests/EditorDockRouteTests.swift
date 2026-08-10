import XCTest
@testable import MosaicCore

/// ドックの遷移契約。**この UI の使いづらさの正体が「現在地が読めない」ことだった**ので、
/// 「何段で戻れるか」「どの操作で段が動かないか」をここで固定する。
final class EditorDockRouteTests: XCTestCase {
    // MARK: - 深さの上限

    /// どの段からでも `‹` を高々 2 回で `root` に着く（階層は 2 段まで、が設計の前提）。
    ///
    /// **ループの上限を先に決めてから回す。** `while current != .root` で回すと、
    /// 親が自分自身を指す壊れ方（`mosaic.parent == .mosaic`）で**落ちずにハングする**。
    /// 契約を壊したときに落ちないテストは、無いのと同じ。
    func test_back_reachesRootWithinTwoSteps() {
        let limit = 2
        for route in EditorDockRoute.allCases {
            var current = route
            var steps = 0
            while current != .root, steps < limit {
                current = EditorDockNavigation.back(from: current)
                steps += 1
            }
            XCTAssertEqual(current, .root, "\(route) から \(limit) 段では root に戻れなかった")
        }
    }

    /// `root` で `‹` を押しても、それ以上は上がれない（行き先が自分自身）。
    func test_back_fromRoot_staysAtRoot() {
        XCTAssertEqual(EditorDockNavigation.back(from: .root), .root)
    }

    /// 「完了」はどの深さからでも 1 回で `root` に戻す（`‹` の連打を要求しない）。
    func test_done_alwaysReturnsToRoot() {
        for route in EditorDockRoute.allCases {
            XCTAssertEqual(EditorDockNavigation.done(from: route), .root, "\(route)")
        }
    }

    // MARK: - 行き止まりを作らない

    /// `root` 以外には必ず戻る手段がある。
    func test_everyRouteExceptRootHasBackButton() {
        for route in EditorDockRoute.allCases {
            XCTAssertEqual(route.showsBackButton, route != .root, "\(route)")
            XCTAssertEqual(route.showsDoneButton, route != .root, "\(route)")
        }
    }

    // MARK: - 遷移表

    func test_enter_followsHierarchy() {
        XCTAssertEqual(EditorDockNavigation.enter(.mosaic, from: .root), .mosaic)
        XCTAssertEqual(EditorDockNavigation.enter(.face, from: .mosaic), .face)
        XCTAssertEqual(EditorDockNavigation.enter(.background, from: .mosaic), .background)
        XCTAssertEqual(EditorDockNavigation.enter(.rectangle, from: .mosaic), .rectangle)
    }

    /// 階層を飛ばす遷移は起こさない（`root` から直接 `face` へは降りない）。
    /// 飛ばせてしまうと、そこから `‹` で戻った先が押した場所と違う段になる。
    func test_enter_doesNotSkipLevels() {
        XCTAssertEqual(EditorDockNavigation.enter(.face, from: .root), .root)
        XCTAssertEqual(EditorDockNavigation.enter(.background, from: .root), .root)
        XCTAssertEqual(EditorDockNavigation.enter(.rectangle, from: .root), .root)
    }

    /// 最下段からさらに降りようとしても現在地を保つ（段が壊れない）。
    func test_enter_fromLeafRoutes_isNoOp() {
        for leaf in [EditorDockRoute.face, .background, .rectangle] {
            for destination in EditorDockRoute.allCases {
                XCTAssertEqual(EditorDockNavigation.enter(destination, from: leaf), leaf,
                               "\(leaf) から \(destination) へ降りてしまった")
            }
        }
    }

    /// 同じ段への再入は段を変えない（連打で階層がずれない）。
    func test_enter_sameRoute_isStable() {
        XCTAssertEqual(EditorDockNavigation.enter(.mosaic, from: .mosaic), .mosaic)
    }

    // MARK: - 粗さスライダーの所在

    /// 粗さは効果を選んだ段にだけ出る。`root` / `mosaic` に出すと、
    /// 「何の粗さか」が決まらないまま操作できてしまう。
    func test_blockSizeSlider_onlyOnEffectRoutes() {
        XCTAssertFalse(EditorDockRoute.root.showsBlockSizeSlider)
        XCTAssertFalse(EditorDockRoute.mosaic.showsBlockSizeSlider)
        XCTAssertTrue(EditorDockRoute.face.showsBlockSizeSlider)
        XCTAssertTrue(EditorDockRoute.background.showsBlockSizeSlider)
        XCTAssertTrue(EditorDockRoute.rectangle.showsBlockSizeSlider)
    }

    // MARK: - 永続化

    /// 段を下書きへ持ち越せるようにしてある（再開時に同じ段で開くため）。
    func test_rawValue_roundTrips() {
        for route in EditorDockRoute.allCases {
            XCTAssertEqual(EditorDockRoute(rawValue: route.rawValue), route)
        }
    }
}
