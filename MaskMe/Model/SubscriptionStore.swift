import Foundation
import MosaicCore
#if canImport(StoreKit)
import StoreKit
#endif

/// 購入 UI（次段）が使う StoreKit フロントエンド。
///
/// 商品の読み込み・購入・復元・体験版の可否判定をまとめる。UI 自体はここでは作らない。
/// 権限の確定状態は持たず、購入・復元が確定した後に `Entitlements.shared` へ
/// `refresh()` を依頼するだけ（判定ロジックの二重実装を避ける）。
@MainActor
final class SubscriptionStore: ObservableObject {
    #if canImport(StoreKit)
    @Published private(set) var products: [SubscriptionPlan: Product] = [:]
    #endif
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// 権限の再取得先。本番は `Entitlements.shared`（`StoreKitEntitlementProvider`）。
    private let entitlementProvider: EntitlementProvider

    init(entitlementProvider: EntitlementProvider = Entitlements.shared) {
        self.entitlementProvider = entitlementProvider
    }

    #if canImport(StoreKit)
    /// `SubscriptionPlan.allCases` の product ID で `Product.products(for:)` を呼び、
    /// プランごとの `Product` を組み立てる。
    func loadProducts() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await Product.products(for: SubscriptionPlan.allCases.map(\.rawValue))
            var byPlan: [SubscriptionPlan: Product] = [:]
            for product in fetched {
                guard let plan = SubscriptionPlan(productID: product.id) else { continue }
                byPlan[plan] = product
            }
            products = byPlan
        } catch {
            errorMessage = "商品情報の取得に失敗しました。通信環境を確認してもう一度お試しください。"
        }
    }

    /// プランを購入する。戻り値は「購入が確定したか」（保留・キャンセルは false）。
    ///
    /// `.success(.verified)` のときだけ `finish()` して権限を `refresh()` する。
    /// `.success(.unverified)` は署名検証に落ちた transaction なので確定として扱わない
    /// （`StoreKitEntitlementProvider.observeStoreKitEntitlements` と同じ理由）。
    @discardableResult
    func purchase(_ plan: SubscriptionPlan) async -> Bool {
        guard let product = products[plan] else {
            errorMessage = "商品情報が読み込まれていません。もう一度お試しください。"
            return false
        }

        errorMessage = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verificationResult):
                switch verificationResult {
                case .verified(let transaction):
                    await transaction.finish()
                    await entitlementProvider.refreshIfPossible()
                    return true
                case .unverified:
                    errorMessage = "購入の検証に失敗しました。時間をおいて再度お試しください。"
                    return false
                }
            case .pending:
                // 保留（ファミリー承認待ち等）。確定は `Transaction.updates` 経由で届く。
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            errorMessage = "購入処理に失敗しました。時間をおいて再度お試しください。"
            return false
        }
    }

    /// 復元。`AppStore.sync()` の後、権限を取り直す。
    func restore() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await entitlementProvider.refreshIfPossible()
        } catch {
            errorMessage = "購入の復元に失敗しました。通信環境を確認してもう一度お試しください。"
        }
    }

    /// そのプランの導入オファー（無料体験）にまだ加入できるか。
    func isEligibleForIntroOffer(_ plan: SubscriptionPlan) async -> Bool {
        guard let product = products[plan], let subscription = product.subscription else { return false }
        return await subscription.isEligibleForIntroOffer
    }

    /// 年額プランの割安率。`SubscriptionPlan.savingsPercent` に `Product.price`（Decimal）を
    /// 渡すだけで、割安率の計算はここで再実装しない。
    var savingsPercent: Int? {
        guard let monthly = products[.monthly], let yearly = products[.yearly] else { return nil }
        return SubscriptionPlan.savingsPercent(monthlyPrice: monthly.price, yearlyPrice: yearly.price)
    }
    #else
    func loadProducts() async {}
    @discardableResult
    func purchase(_ plan: SubscriptionPlan) async -> Bool { false }
    func restore() async {}
    func isEligibleForIntroOffer(_ plan: SubscriptionPlan) async -> Bool { false }
    var savingsPercent: Int? { nil }
    #endif
}

private extension EntitlementProvider {
    /// `EntitlementProvider` は購入 UI から見て「読み取り専用」のため `refresh()` を
    /// プロトコルへ足さず、実体が `StoreKitEntitlementProvider` のときだけ呼ぶ。
    /// テスト用の `LocalEntitlementProvider` 等では何もしない。
    func refreshIfPossible() async {
        if let storeKitProvider = self as? StoreKitEntitlementProvider {
            await storeKitProvider.refresh()
        }
    }
}
