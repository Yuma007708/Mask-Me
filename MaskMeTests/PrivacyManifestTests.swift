import Foundation
import XCTest
@testable import MaskMe

/// Privacy Manifest（`MaskMe/PrivacyInfo.xcprivacy`）の番人。
///
/// **これが無い／内容が古いと App Store Connect がビルドを受け付けない**（2024-05-01 以降）。
/// しかも失敗するのは提出のときで、ビルドもテストも緑のまま通ってしまう。
/// だからここで、アプリのバンドルに入っていることと、宣言の中身が
/// 実際のコードと一致していることを機械で確かめる。
///
/// **宣言が実態からずれる典型は「機能を足したとき」である。** 通信を足す、
/// 空き容量を画面に出す、といった変更は Privacy Manifest を直す必要があるのに、
/// 直さなくても動いてしまう。`test_通信するコードを持たない` がその見張り。
final class PrivacyManifestTests: XCTestCase {
    /// アプリ本体のバンドル（テストは `TEST_HOST` に載るのでこれが `MaskMe.app`）。
    private func appBundle() -> Bundle { Bundle(for: MosaicEditorModel.self) }

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            appBundle().url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy がアプリのバンドルに入っていない。"
                + "ファイルを消したか、project.yml の結線が外れている。")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "PrivacyInfo.xcprivacy が plist として読めない")
    }

    func test_バンドルに入っていて読める() throws {
        XCTAssertFalse(try manifest().isEmpty)
    }

    /// **追跡もデータ収集もしないという宣言を固定する。** ここが true になる変更は
    /// アプリの性格が変わる変更なので、無言で通してはいけない。
    func test_追跡もデータ収集もしないと宣言している() throws {
        let plist = try manifest()
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0,
                       "追跡ドメインが増えている")
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0,
                       "収集するデータ型が増えている。通信を足したなら宣言も見直すこと")
    }

    /// **宣言している「使用理由の必要な API」が過不足なく一致する。**
    ///
    /// - 足りない → 提出で弾かれる
    /// - 余分 → 使っていない API を使うと申告することになる（嘘の宣言）
    func test_使用理由の必要なAPIの宣言が期待どおり() throws {
        let expected: [String: [String]] = [
            // このアプリ自身しか読み書きしない設定値（権限・検出設定・撮影設定・案内の既読）
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            // tmp の古い一時ファイルを消すために更新日時を見る（DraftStore.sweep）
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1"],
            // 書き出し前に空きが足りるか確かめ、足りなければ止める（storageShortageMessage）
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"]
        ]

        let types = try XCTUnwrap(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var actual: [String: [String]] = [:]
        for entry in types {
            let key = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            actual[key] = (entry["NSPrivacyAccessedAPITypeReasons"] as? [String])?.sorted()
        }
        XCTAssertEqual(actual, expected.mapValues { $0.sorted() })
    }

    /// **通信するコードを持たないことを固定する。**
    ///
    /// 「データを収集しない」という宣言の根拠は「そもそも外へ出す経路が無い」ことである。
    /// 通信を足す変更が入ったら、この番人が落ちて Privacy Manifest の見直しを促す。
    /// 落ちたからといって通信が禁止なのではなく、**宣言を直してからここを更新する**のが正しい。
    func test_通信するコードを持たない() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MaskMeTests
            .deletingLastPathComponent()  // リポジトリ直下
        var offenders: [String] = []
        for directory in ["MaskMe", "Sources"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else {
                throw XCTSkip("ソースを辿れない環境（バンドル実行など）ではスキップ")
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    // コメント（この番人の説明文自身を含む）は対象外。
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"),
                          !trimmed.hasPrefix("*") else { continue }
                    if trimmed.contains("URLSession") || trimmed.contains("URLRequest") {
                        offenders.append("\(url.lastPathComponent): \(trimmed)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "通信するコードが入った。PrivacyInfo.xcprivacy の "
                          + "NSPrivacyCollectedDataTypes / NSPrivacyTrackingDomains を"
                          + "見直してからこのテストを更新すること:\n"
                          + offenders.joined(separator: "\n"))
    }
}
