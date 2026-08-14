import Foundation

/// 購入画面から開く法務リンク。**App Store の審査で必須**（`PaywallView` の doc 参照）。
///
/// ここを 1 か所にまとめているのは、購入画面と設定画面で違う URL を出す事故を防ぐため。
enum LegalLinks {
    /// 利用規約（EULA）。
    ///
    /// 独自の EULA を用意しない場合、Apple の標準 EULA を指すのが正規のやり方
    /// （App Store Connect の「使用許諾契約」で標準 EULA を選んだ状態に対応する）。
    /// 独自 EULA を用意したときは、こちらもその URL へ差し替えること。
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// プライバシーポリシー。
    ///
    /// **提出前に実在する URL へ差し替えること。** App Store Connect にも同じ URL を
    /// 登録する必要があり、そちらと食い違っていると審査で止まる。
    ///
    /// このアプリは通信をしない（`PrivacyManifestTests.test_通信するコードを持たない` が
    /// 番人）ので、内容は「収集・送信は一切しない」で書ける。
    static let privacyPolicy = URL(string: placeholderPrivacyPolicy)!

    /// 差し替え前の仮 URL。`PaywallLegalLinkTests` がこの値と一致するかを見て、
    /// **仮のまま提出しようとしていることを検知する**（テストは落とさず、
    /// 下の `isPrivacyPolicyPlaceholder` を通じて開発者に見せる）。
    static let placeholderPrivacyPolicy = "https://example.com/maskme/privacy"

    /// プライバシーポリシーの URL が仮のままか。
    static var isPrivacyPolicyPlaceholder: Bool {
        privacyPolicy.absoluteString == placeholderPrivacyPolicy
    }
}

#warning("提出前に LegalLinks.privacyPolicy を実在する URL へ差し替えること（現在は仮の URL）")
