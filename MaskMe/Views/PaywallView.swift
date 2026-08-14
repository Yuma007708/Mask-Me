import MosaicCore
import SwiftUI
#if canImport(StoreKit)
import StoreKit
#endif

/// Pro の購入画面。
///
/// ## App Store の審査で必須のもの
///
/// サブスクリプションの購入画面には、**買う前に**次を出す必要がある（Apple の
/// 「App Review Guidelines 3.1.2」および「Schedule 2」）。どれか 1 つでも欠けると
/// リジェクト対象になるので、見た目の都合で消さないこと:
///
/// - プランの名前・**価格**・**期間**（`Product.displayPrice` / `displayName` から出す。
///   ハードコードしない——通貨も価格も国によって変わる）
/// - 無料体験があるならその**長さと、終了後にいくら課金されるか**
/// - **自動更新される**という説明と、解約方法
/// - **利用規約（EULA）** と **プライバシーポリシー** へのリンク
/// - **購入の復元**（`AppStore.sync()`）。これが無いのは単独でリジェクト理由になる
///
/// ## 価格を自分で持たない
///
/// `Products.storekit` にも 480 / 3,000 という数字はあるが、あれは**ローカル検証用**で
/// 実際の価格ではない。表示は必ず StoreKit が返す `displayPrice` を使う。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SubscriptionStore()

    /// 画面を開いた理由（書き出し制限に当たった等）。無ければ通常の案内文を出す。
    var reason: String?

    @State private var selectedPlan: SubscriptionPlan = .yearly
    @State private var isPro = Entitlements.shared.isPro
    @State private var isWorking = false
    @State private var introEligibility: [SubscriptionPlan: Bool] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    benefits
                    if isPro {
                        activeNotice
                    } else {
                        planList
                        purchaseButton
                        renewalNotice
                    }
                    if let message = store.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.danger)
                            .accessibilityIdentifier("paywall.error")
                    }
                    footerLinks
                }
                .padding(20)
            }
            .appSheetBackground()
            .navigationTitle("Mask Me Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("paywall.close")
                }
            }
        }
        .accessibilityIdentifier("paywall")
        .task {
            await store.loadProducts()
            await refreshIntroEligibility()
        }
        .onReceive(Entitlements.shared.isProPublisher) { isPro = $0 }
    }

    // MARK: - 上部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 開いた理由があるなら、それを最初に出す。「なぜこの画面が出たのか」が
            // 分からないまま値段だけ見せられるのが、購入画面でいちばん嫌われる形。
            if let reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkDim)
                    .accessibilityIdentifier("paywall.reason")
            }
            Text("透かしなし・長さも画質も制限なしで書き出せます。")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.benefitItems, id: \.text) { item in
                Label(item.text, systemImage: item.icon)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.ink)
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
    }

    private static let benefitItems: [(icon: String, text: String)] = [
        ("drop.triangle", "書き出した動画・写真に透かしが入らない"),
        ("timer", "60秒を超える動画も書き出せる"),
        ("4k.tv", "元の画質のまま書き出せる（無料は 1080p へ縮小）")
    ]

    private var activeNotice: some View {
        Label("Pro をご利用中です", systemImage: "checkmark.seal.fill")
            .font(.headline)
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            .accessibilityIdentifier("paywall.active")
    }

    // MARK: - プラン

    private var planList: some View {
        VStack(spacing: 10) {
            ForEach(SubscriptionPlan.allCases, id: \.self) { plan in
                planRow(plan)
            }
        }
    }

    private func planRow(_ plan: SubscriptionPlan) -> some View {
        let isSelected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(planTitle(plan))
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    if let note = planNote(plan) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(AppTheme.inkDim)
                    }
                }
                Spacer(minLength: 8)
                Text(priceText(plan))
                    .font(.headline)
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.ink)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(isSelected ? AppTheme.accent : AppTheme.line, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.plan.\(plan.identifierSuffix)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func planTitle(_ plan: SubscriptionPlan) -> String {
        switch plan {
        case .monthly: return "月額プラン"
        case .yearly: return "年額プラン"
        }
    }

    /// プランの補足（無料体験・割安率）。**値が取れないときは何も出さない**——
    /// 「7日間無料」を商品情報より先に出してしまうと、実際には対象外の人にも
    /// 見えてしまい、誤解を招く。
    private func planNote(_ plan: SubscriptionPlan) -> String? {
        var parts: [String] = []
        if introEligibility[plan] == true, let period = introOfferPeriodText(plan) {
            parts.append("\(period)無料で試せます")
        }
        if plan == .yearly, let percent = store.savingsPercent {
            parts.append("月額より \(percent)% お得")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    // MARK: - 購入

    private var purchaseButton: some View {
        Button {
            Task { await buy() }
        } label: {
            Group {
                if isWorking {
                    ProgressView().tint(AppTheme.onAccent)
                } else {
                    Text(purchaseButtonTitle)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.onAccent)
        .disabled(isWorking || !hasProduct(selectedPlan))
        .accessibilityIdentifier("paywall.purchase")
    }

    private var purchaseButtonTitle: String {
        introEligibility[selectedPlan] == true ? "無料で試す" : "このプランを購入"
    }

    /// 自動更新の説明。**買う前に見える位置に置くこと**（購入ボタンの直後）。
    private var renewalNotice: some View {
        Text("購入は Apple ID に課金されます。期間終了の 24 時間前までに解約しない限り自動更新されます。"
            + "解約は「設定」アプリ →  Apple ID → サブスクリプション から行えます。")
            .font(.caption)
            .foregroundStyle(AppTheme.inkDim)
            .accessibilityIdentifier("paywall.renewalNotice")
    }

    private var footerLinks: some View {
        VStack(spacing: 12) {
            Button("購入を復元") {
                Task { await restore() }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("paywall.restore")

            HStack(spacing: 16) {
                Link("利用規約", destination: LegalLinks.termsOfUse)
                    .accessibilityIdentifier("paywall.terms")
                Link("プライバシーポリシー", destination: LegalLinks.privacyPolicy)
                    .accessibilityIdentifier("paywall.privacy")
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .tint(AppTheme.accent)
    }

    // MARK: - 操作

    private func buy() async {
        isWorking = true
        defer { isWorking = false }
        // 購入が確定したら閉じる。保留・キャンセル・失敗では閉じない
        // （閉じてしまうと、失敗の理由を出す場所が無くなる）。
        if await store.purchase(selectedPlan) { dismiss() }
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        await store.restore()
        // 復元は「戻すものが無かった」ときも成功で返る。`isPro` は
        // `isProPublisher` 経由で反映されるので、ここでは判定しない。
    }

    private func refreshIntroEligibility() async {
        var result: [SubscriptionPlan: Bool] = [:]
        for plan in SubscriptionPlan.allCases {
            result[plan] = await store.isEligibleForIntroOffer(plan)
        }
        introEligibility = result
    }

    // MARK: - StoreKit の有無で分かれる表示

    #if canImport(StoreKit)
    private func hasProduct(_ plan: SubscriptionPlan) -> Bool { store.products[plan] != nil }

    /// 価格。**商品が読めていないうちは金額を出さない**（0 円や仮の値を出すと嘘になる）。
    private func priceText(_ plan: SubscriptionPlan) -> String {
        guard let product = store.products[plan] else { return "—" }
        return product.displayPrice
    }

    private func introOfferPeriodText(_ plan: SubscriptionPlan) -> String? {
        guard let offer = store.products[plan]?.subscription?.introductoryOffer else { return nil }
        let period = offer.period
        let count = period.value * offer.periodCount
        switch period.unit {
        case .day: return "\(count)日間"
        case .week: return "\(count)週間"
        case .month: return "\(count)か月"
        case .year: return "\(count)年間"
        @unknown default: return nil
        }
    }
    #else
    private func hasProduct(_ plan: SubscriptionPlan) -> Bool { false }
    private func priceText(_ plan: SubscriptionPlan) -> String { "—" }
    private func introOfferPeriodText(_ plan: SubscriptionPlan) -> String? { nil }
    #endif
}

private extension SubscriptionPlan {
    /// アクセシビリティ識別子に使う短い名前（product ID をそのまま使うと
    /// 識別子にドットが並んで読みにくい）。
    var identifierSuffix: String {
        switch self {
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        }
    }
}
