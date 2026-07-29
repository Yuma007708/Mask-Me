import Foundation
import XCTest
@testable import MosaicCore

final class TempFileSweeperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let maxAge: TimeInterval = 24 * 60 * 60

    private func shouldDelete(_ name: String, ageSeconds: TimeInterval) -> Bool {
        TempFileSweeper.shouldDelete(name: name,
                                     modifiedAt: now.addingTimeInterval(-ageSeconds),
                                     now: now)
    }

    /// 管理下の接頭辞かつ十分古いものは削除対象。
    func test_deletesOldManagedFiles() {
        let old = maxAge + 1
        XCTAssertTrue(shouldDelete("picked-1234.mov", ageSeconds: old))
        XCTAssertTrue(shouldDelete("photoclip-abc.mp4", ageSeconds: old))
        XCTAssertTrue(shouldDelete("mosaic-out.mp4", ageSeconds: old))
    }

    /// ⚠️ 下書きの素材本体・サムネイル・索引 JSON は、どれだけ古くても削除しないこと。
    /// ここが false でなくなると復元不能な下書き破壊になる。
    func test_neverDeletesDraftAssets() {
        let veryOld = maxAge * 365
        let protectedNames = [
            "source-1234.mov",
            "source-1234.mp4",
            "thumb-1234.jpg",
            "thumb-1234.png",
            "drafts.json",
            "index.json",
            "draft-index.json",
            "face_landmarker.task",
            "Documents",
            ""
        ]
        for name in protectedNames {
            XCTAssertFalse(shouldDelete(name, ageSeconds: veryOld), name)
        }
    }

    /// 接頭辞は前方一致であること（途中に現れるだけでは対象外）。
    func test_prefixMatchIsAnchoredAtStart() {
        let veryOld = maxAge * 10
        XCTAssertFalse(shouldDelete("my-picked-1.mov", ageSeconds: veryOld))
        XCTAssertFalse(shouldDelete("source-mosaic-1.mp4", ageSeconds: veryOld))
        XCTAssertFalse(shouldDelete("Picked-1.mov", ageSeconds: veryOld)) // 大文字小文字は区別する
    }

    /// 新しいファイル・境界ちょうどは残すこと（書き出し中のファイルを巻き込まない）。
    func test_keepsRecentFilesAndExactBoundary() {
        XCTAssertFalse(shouldDelete("picked-1.mov", ageSeconds: 0))
        XCTAssertFalse(shouldDelete("picked-1.mov", ageSeconds: maxAge - 1))
        XCTAssertFalse(shouldDelete("picked-1.mov", ageSeconds: maxAge)) // 境界ちょうどは残す
        XCTAssertTrue(shouldDelete("picked-1.mov", ageSeconds: maxAge + 0.001))
    }

    /// 時計が巻き戻って更新日時が未来になった場合も削除しないこと。
    func test_keepsFilesWithFutureTimestamp() {
        XCTAssertFalse(shouldDelete("picked-1.mov", ageSeconds: -1))
        XCTAssertFalse(shouldDelete("picked-1.mov", ageSeconds: -maxAge * 10))
        XCTAssertFalse(TempFileSweeper.shouldDelete(name: "picked-1.mov",
                                                    modifiedAt: Date.distantFuture,
                                                    now: now))
    }

    /// maxAge が非有限なら判断がつかないので残す。0 なら「1 秒でも古ければ消す」。
    func test_maxAgeEdgeCases() {
        let older = now.addingTimeInterval(-1)
        XCTAssertFalse(TempFileSweeper.shouldDelete(name: "picked-1.mov", modifiedAt: older,
                                                    now: now, maxAge: .nan))
        XCTAssertFalse(TempFileSweeper.shouldDelete(name: "picked-1.mov", modifiedAt: older,
                                                    now: now, maxAge: .infinity))
        XCTAssertTrue(TempFileSweeper.shouldDelete(name: "picked-1.mov", modifiedAt: older,
                                                   now: now, maxAge: 0))
        XCTAssertFalse(TempFileSweeper.shouldDelete(name: "picked-1.mov", modifiedAt: now,
                                                    now: now, maxAge: 0))
    }

    /// 空文字の接頭辞は全ファイルに一致してしまうため無視すること（全消し防止）。
    func test_emptyPrefixMatchesNothing() {
        XCTAssertFalse(TempFileSweeper.shouldDelete(name: "source-1.mov",
                                                    modifiedAt: Date.distantPast,
                                                    now: now,
                                                    prefixes: [""]))
        // 空文字が混ざっていても、他の有効な接頭辞の判定は生きる。
        XCTAssertTrue(TempFileSweeper.shouldDelete(name: "picked-1.mov",
                                                   modifiedAt: Date.distantPast,
                                                   now: now,
                                                   prefixes: ["", "picked-"]))
    }

    /// 管理対象の接頭辞そのものを固定する（勝手に増減させない）。
    func test_managedPrefixesAreStable() {
        XCTAssertEqual(TempFileSweeper.managedPrefixes, ["picked-", "photoclip-", "mosaic-"])
        XCTAssertEqual(TempFileSweeper.defaultMaxAge, 24 * 60 * 60, accuracy: 1e-9)
    }
}
