import XCTest
@testable import MosaicCore

/// 課金 P3: 権限判定の解決規則（コア層）。
///
/// StoreKit に直結させず 3値 + 純関数にした理由は `EntitlementResolver` の doc コメント参照。
final class EntitlementResolverTests: XCTestCase {
    // MARK: - resolve: 全組み合わせ（observation 2種 × cached 3種 = 6通り）

    func test_resolve_confirmedTrue_cachedUnknown_returnsPro() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: true), cached: .unknown),
            .pro)
    }

    func test_resolve_confirmedTrue_cachedPro_returnsPro() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: true), cached: .pro),
            .pro)
    }

    func test_resolve_confirmedTrue_cachedFree_returnsPro() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: true), cached: .free),
            .pro)
    }

    func test_resolve_confirmedFalse_cachedUnknown_returnsFree() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: false), cached: .unknown),
            .free)
    }

    func test_resolve_confirmedFalse_cachedPro_returnsFree() {
        // 期限切れ・返金は確定情報なので、Pro キャッシュがあってもオフラインで free に落とす。
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: false), cached: .pro),
            .free)
    }

    func test_resolve_confirmedFalse_cachedFree_returnsFree() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .confirmed(isPro: false), cached: .free),
            .free)
    }

    func test_resolve_unavailable_cachedUnknown_returnsUnknown() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .unavailable, cached: .unknown),
            .unknown)
    }

    /// 番人テスト: オフラインでも Pro を失わないこと。これが今回の設計の全部。
    func test_resolve_unavailable_cachedPro_staysProOfflineRegression() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .unavailable, cached: .pro),
            .pro)
    }

    func test_resolve_unavailable_cachedFree_returnsFree() {
        XCTAssertEqual(
            EntitlementResolver.resolve(observation: .unavailable, cached: .free),
            .free)
    }

    // MARK: - 未購入の起動直後

    func test_resolve_unavailable_cachedUnknown_grantsProIsFalse() {
        let status = EntitlementResolver.resolve(observation: .unavailable, cached: .unknown)
        XCTAssertEqual(status, .unknown)
        XCTAssertFalse(EntitlementResolver.grantsPro(status))
    }

    // MARK: - grantsPro

    func test_grantsPro_onlyProIsTrue() {
        XCTAssertTrue(EntitlementResolver.grantsPro(.pro))
        XCTAssertFalse(EntitlementResolver.grantsPro(.free))
        XCTAssertFalse(EntitlementResolver.grantsPro(.unknown))
    }

    // MARK: - EntitlementStatus Codable round-trip（保存値なので）

    func test_entitlementStatus_codableRoundTrip() throws {
        for status in [EntitlementStatus.unknown, .pro, .free] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(EntitlementStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
}
