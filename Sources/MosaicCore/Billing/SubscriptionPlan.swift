import Foundation

/// Pro サブスクリプションのプラン。`rawValue` が App Store Connect の product ID。
public enum SubscriptionPlan: String, CaseIterable, Sendable, Equatable {
    case monthly = "com.maskme.pro.monthly"
    case yearly = "com.maskme.pro.yearly"

    /// App Store の product ID から復元する。未知の ID は nil。
    public init?(productID: String) {
        self.init(rawValue: productID)
    }

    /// 年額プランの割安率（%、整数・切り捨て）。
    ///
    /// 年額を 12 で割った「実質月額」と月額を比較し、実質月額の方が安いときだけ
    /// 割合を返す。以下は表示すべきでないため `nil`:
    /// - `monthlyPrice` がゼロ以下（比較対象が壊れている＝ゼロ除算の温床）
    /// - `yearlyPrice` が負（不正な入力）
    /// - 実質月額が月額と同額、または月額より高い（「お得」が成立しない）
    ///
    /// 例: 月額 480円・年額 3,000円 → 実質月額 250円 → (480-250)/480 = 47.9% → 47%。
    public static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        guard monthlyPrice > 0, yearlyPrice >= 0 else { return nil }

        let monthlyEquivalent = yearlyPrice / 12
        guard monthlyEquivalent < monthlyPrice else { return nil }

        let savingsRatio = (monthlyPrice - monthlyEquivalent) / monthlyPrice
        let percent = savingsRatio * 100

        // 切り捨て（NSDecimalNumber の rounding で .down を使う）。
        let handler = NSDecimalNumberHandler(roundingMode: .down,
                                              scale: 0,
                                              raiseOnExactness: false,
                                              raiseOnOverflow: false,
                                              raiseOnUnderflow: false,
                                              raiseOnDivideByZero: false)
        let truncated = NSDecimalNumber(decimal: percent).rounding(accordingToBehavior: handler)
        return truncated.intValue
    }
}
