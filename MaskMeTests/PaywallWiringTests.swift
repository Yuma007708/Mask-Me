import Foundation
import MosaicCore
import XCTest
@testable import MaskMe

/// 課金の**結線**の番人。判定ロジックそのものは `EntitlementResolverTests` /
/// `SubscriptionPlanTests`（コア層）が見ているので、ここは
/// 「その判定が正しい場所へ届いているか」だけを見る。
///
/// この案件では、`SubscriptionStore`（購入・復元）を書き終えたまま
/// **どこからも呼ばれていない**状態が長く残っていた。ビルドもテストも緑で気づけない。
/// 結線は結線として確かめる必要がある。
final class PaywallWiringTests: XCTestCase {
    // MARK: - 制限の出口

    /// **尺超過は購入画面へ誘導する出口（`paywallPrompt`）に載る。**
    ///
    /// `errorMessage` に載せると「Proにすれば書き出せます」と書いてあるのに
    /// 「OK」しか押せない行き止まりになる。
    @MainActor
    func test_尺超過はペイウォールの出口に載る() {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.exportRestriction = .exceedsDuration(limit: 60)

        XCTAssertTrue(model.presentPaywallIfRestricted(), "書き出しを止めていない")
        XCTAssertNotNil(model.paywallPrompt, "購入画面への導線が出ない")
        XCTAssertNil(model.errorMessage, "行き止まりのエラーとして出ている")
        XCTAssertTrue(model.paywallPrompt?.contains("60") == true,
                      "上限の秒数が案内文に入っていない: \(model.paywallPrompt ?? "nil")")
    }

    /// **止めない制限では何も出さない。**
    ///
    /// `.exceedsResolution` は縮小して書き出す、`.watermarkOnly` は透かしを載せるだけで、
    /// どちらも書き出しは通る。ここで購入画面を出すと、成功する操作を邪魔することになる。
    @MainActor
    func test_止めない制限では購入画面を出さない() {
        for restriction in [ExportRestriction.none,
                            .watermarkOnly,
                            .exceedsResolution(limit: 1080)] {
            let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
            model.exportRestriction = restriction

            XCTAssertFalse(model.presentPaywallIfRestricted(), "\(restriction) で書き出しを止めた")
            XCTAssertNil(model.paywallPrompt, "\(restriction) で購入画面を出した")
        }
    }

    // MARK: - 商品 ID

    /// **`SubscriptionPlan` の product ID が `Products.storekit` と一致する。**
    ///
    /// ここがずれると `Product.products(for:)` が空で返り、**購入画面は開くのに
    /// 値段が出ず何も買えない**という、例外もログも出ない壊れ方をする。
    /// （App Store Connect 側との一致は機械では確かめられないので、そこは人が見る。
    ///   ローカルの検証用ファイルとの一致だけでも、打ち間違いは捕まえられる。）
    func test_商品IDがStoreKit設定ファイルと一致する() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Products.storekit")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Products.storekit が見つからない環境ではスキップ")
        }
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        let idsInFile = Set(groups
            .flatMap { ($0["subscriptions"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["productID"] as? String })

        XCTAssertEqual(idsInFile, Set(SubscriptionPlan.allCases.map(\.rawValue)))
    }

    /// 未知の product ID は復元しない（他アプリの ID を取り違えて Pro を開けない）。
    func test_未知の商品IDはプランにならない() {
        XCTAssertNil(SubscriptionPlan(productID: "com.example.other.monthly"))
        XCTAssertEqual(SubscriptionPlan(productID: "com.maskme.pro.yearly"), .yearly)
    }

    // MARK: - 法務リンク

    /// **利用規約は Apple の標準 EULA を指す。**
    ///
    /// 独自の EULA を用意したら差し替えること。差し替えたらこのテストも一緒に直す
    /// （ここが落ちるのは「気づかないうちに壊れた」ときだけにしたい）。
    func test_利用規約はAppleの標準EULA() {
        XCTAssertEqual(LegalLinks.termsOfUse.absoluteString,
                       "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    /// リンクが http(s) で開ける形であること。**空文字や相対パスだと Link が黙って
    /// 何も起きないボタンになる**（押しても無反応、という最も気づきにくい壊れ方）。
    func test_法務リンクは開ける形をしている() {
        for url in [LegalLinks.termsOfUse, LegalLinks.privacyPolicy] {
            XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""),
                          "\(url) が開ける形をしていない")
            XCTAssertNotNil(url.host, "\(url) にホストが無い")
        }
    }
}
