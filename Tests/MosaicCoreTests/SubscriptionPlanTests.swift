import XCTest
@testable import MosaicCore

/// 課金 P3: プラン定義と割安率表示の純関数。
final class SubscriptionPlanTests: XCTestCase {
    // MARK: - productID 往復

    func test_init_productID_monthly_roundTrips() {
        XCTAssertEqual(SubscriptionPlan(productID: "com.maskme.pro.monthly"), .monthly)
    }

    func test_init_productID_yearly_roundTrips() {
        XCTAssertEqual(SubscriptionPlan(productID: "com.maskme.pro.yearly"), .yearly)
    }

    func test_init_productID_unknown_returnsNil() {
        XCTAssertNil(SubscriptionPlan(productID: "com.maskme.pro.lifetime"))
    }

    func test_allCases_containsBothPlans() {
        XCTAssertEqual(Set(SubscriptionPlan.allCases), [.monthly, .yearly])
    }

    // MARK: - savingsPercent

    func test_savingsPercent_typicalPrices_returns47Percent() {
        // 月480円・年3,000円 → 実質月額250円 → (480-250)/480 = 47.9% → 47%
        XCTAssertEqual(SubscriptionPlan.savingsPercent(monthlyPrice: 480, yearlyPrice: 3000), 47)
    }

    func test_savingsPercent_zeroMonthlyPrice_returnsNil() {
        XCTAssertNil(SubscriptionPlan.savingsPercent(monthlyPrice: 0, yearlyPrice: 3000))
    }

    func test_savingsPercent_negativeMonthlyPrice_returnsNil() {
        XCTAssertNil(SubscriptionPlan.savingsPercent(monthlyPrice: -480, yearlyPrice: 3000))
    }

    func test_savingsPercent_negativeYearlyPrice_returnsNil() {
        XCTAssertNil(SubscriptionPlan.savingsPercent(monthlyPrice: 480, yearlyPrice: -100))
    }

    func test_savingsPercent_sameEffectivePrice_returnsNil() {
        // 実質月額が月額と同額（年額 = 月額 * 12）なら「お得」ではないので nil。
        XCTAssertNil(SubscriptionPlan.savingsPercent(monthlyPrice: 480, yearlyPrice: 5760))
    }

    func test_savingsPercent_yearlyMoreExpensive_returnsNil() {
        XCTAssertNil(SubscriptionPlan.savingsPercent(monthlyPrice: 480, yearlyPrice: 10000))
    }

    func test_savingsPercent_zeroYearlyPrice_returnsFullSavings() {
        // 年額ゼロは非現実的な入力だが、ゼロ除算にはならず 100% を返す。
        XCTAssertEqual(SubscriptionPlan.savingsPercent(monthlyPrice: 480, yearlyPrice: 0), 100)
    }
}
