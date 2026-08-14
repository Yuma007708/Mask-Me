import XCTest

/// 購入画面（`PaywallView`）が**実際に辿り着けて、必要なものが載っている**ことの検証。
///
/// ## なぜ UI テストなのか
///
/// 課金は「判定の層が完成しているのに、購入画面がどこからも開けない」という形で
/// 壊れる。実際この案件では、`SubscriptionStore`（商品読み込み・購入・復元）を
/// 書き終えたまま**どこからも呼ばれていない**状態が残っていた。ビルドもテストも緑で、
/// 誰も気づかない。**導線があること自体**を機械で押さえないと同じことが起きる。
///
/// ## ここで見ているもの
///
/// 「購入の復元」「利用規約」「プライバシーポリシー」「自動更新の説明」は
/// **App Store の審査で必須**（欠けると単独でリジェクト理由になる）。
/// 見た目を整理する過程で消えやすいので、名前で 1 つずつ確かめる。
///
/// 価格そのものは確かめない。Simulator には StoreKit の商品が無く、
/// `Product.products` が空で返るため（`priceText` が "—" になる）。
/// 価格の出し方は `PaywallPricingTests` が純ロジックとして見ている。
final class PaywallUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// 識別子が一致する要素が、種類を問わず 1 つでもあるか。
    private func existsAnyElement(_ identifier: String) -> Bool {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
    }

    private func openPaywallFromSettings() {
        let settingsTab = app.buttons["tab.設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30), "設定タブが無い")
        settingsTab.tap()

        let proRow = app.buttons["settings.pro"]
        XCTAssertTrue(proRow.waitForExistence(timeout: 15),
                      "設定に Pro の行が無い。購入画面への常設の導線が消えている")
        proRow.tap()
    }

    /// **設定から購入画面へ辿り着ける。**
    func test_設定からPro画面を開ける() {
        openPaywallFromSettings()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 15),
                      "購入画面が開かない")
    }

    /// **審査で必須の要素が揃っている。**
    ///
    /// ここが落ちたら、消したものを戻すのが正しい。テストの方を緩めると、
    /// 落ちるのは審査の場になる。
    func test_審査で必須の要素が揃っている() {
        openPaywallFromSettings()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 15))

        XCTAssertTrue(app.buttons["paywall.restore"].exists,
                      "「購入を復元」が無い。これだけで App Store のリジェクト理由になる")
        // **要素の種類で探さない。** SwiftUI の `Link` が XCUI 側で `.link` になるか
        // `.button` になるかは OS 版で揺れる（iOS 26 の Simulator では button だった）。
        // 種類を決め打ちすると、リンクは在るのにテストだけが落ちる。
        XCTAssertTrue(existsAnyElement("paywall.terms"), "利用規約へのリンクが無い")
        XCTAssertTrue(existsAnyElement("paywall.privacy"),
                      "プライバシーポリシーへのリンクが無い")
        XCTAssertTrue(app.staticTexts["paywall.renewalNotice"].exists,
                      "自動更新の説明が無い（買う前に見える位置に置くこと）")
    }

    /// **プランが 2 つとも出ていて、選べる。**
    ///
    /// 商品情報が読めない環境でも行そのものは出す設計なので、Simulator でも成立する
    /// （金額だけが "—" になる）。
    func test_プランが2つ出て選べる() {
        openPaywallFromSettings()

        let monthly = app.buttons["paywall.plan.monthly"]
        let yearly = app.buttons["paywall.plan.yearly"]
        XCTAssertTrue(monthly.waitForExistence(timeout: 15), "月額プランの行が無い")
        XCTAssertTrue(yearly.exists, "年額プランの行が無い")

        monthly.tap()
        XCTAssertTrue(monthly.isSelected, "月額を押しても選択されない")
        yearly.tap()
        XCTAssertTrue(yearly.isSelected, "年額を押しても選択されない")
    }

    /// 閉じたら元の設定画面へ戻る（開いたきり戻れない、が起きないこと）。
    func test_閉じると設定へ戻る() {
        openPaywallFromSettings()
        let close = app.buttons["paywall.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        close.tap()
        XCTAssertTrue(app.buttons["settings.pro"].waitForExistence(timeout: 10),
                      "閉じても設定画面へ戻らない")
    }
}
