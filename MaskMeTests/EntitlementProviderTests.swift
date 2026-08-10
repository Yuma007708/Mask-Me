import XCTest
import Combine
import MosaicCore
@testable import MaskMe

/// `StoreKitEntitlementProvider` の状態機械テスト。StoreKit を一切使わず、
/// 注入した fake `observe` とインメモリの `EntitlementStatusStore` だけで固定する。
final class EntitlementProviderTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// **オフライン回帰（最重要）**: 保存値が `.pro` の状態で `observe` が `.unavailable` を
    /// 返しても `isPro == true` のまま（電波が無いだけで Pro ユーザーの書き出しに
    /// 透かしを入れてはいけない）。
    func test_offlineRegression_cachedProSurvivesUnavailableObservation() async {
        let store = InMemoryEntitlementStatusStore(initial: .pro)
        let provider = StoreKitEntitlementProvider(store: store) { .unavailable }

        await provider.refresh()

        XCTAssertTrue(provider.isPro)
        XCTAssertEqual(provider.status, .pro)
    }

    func test_confirmedPro_setsIsProTrue_andPersists() async {
        let store = InMemoryEntitlementStatusStore(initial: .unknown)
        let provider = StoreKitEntitlementProvider(store: store) { .confirmed(isPro: true) }

        await provider.refresh()

        XCTAssertTrue(provider.isPro)
        XCTAssertEqual(store.load(), .pro)
    }

    func test_confirmedFree_setsIsProFalse_andPersists() async {
        let store = InMemoryEntitlementStatusStore(initial: .pro)
        let provider = StoreKitEntitlementProvider(store: store) { .confirmed(isPro: false) }

        await provider.refresh()

        XCTAssertFalse(provider.isPro)
        XCTAssertEqual(store.load(), .free)
    }

    /// 未購入（store が `.unknown`）＋ `.unavailable` は free 側（Pro を許可しない）。
    func test_neverPurchased_plusUnavailable_isNotPro() async {
        let store = InMemoryEntitlementStatusStore(initial: .unknown)
        let provider = StoreKitEntitlementProvider(store: store) { .unavailable }

        await provider.refresh()

        XCTAssertFalse(provider.isPro)
        XCTAssertEqual(provider.status, .unknown)
    }

    func test_isProPublisher_firesOnChange() async {
        let store = InMemoryEntitlementStatusStore(initial: .free)
        let provider = StoreKitEntitlementProvider(store: store) { .confirmed(isPro: true) }

        let expectation = expectation(description: "isPro becomes true")
        provider.isProPublisher
            .dropFirst() // 初期値（false）をスキップし、変化だけを見る
            .sink { isPro in
                if isPro {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await provider.refresh()

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    /// `start()` を2回呼んでも `Transaction.updates` 相当の購読が二重にならない。
    /// ここでは購読の代わりに `observe` の呼び出し回数を数える
    /// （`start()` は初回観測でも `observe` を1回呼ぶため、2回呼んでも
    /// 呼び出し回数が「1回分」しか増えないことを確認する）。
    func test_start_calledTwice_doesNotDoubleSubscribe() async {
        let store = InMemoryEntitlementStatusStore(initial: .unknown)
        let callCount = CallCounter()
        let provider = StoreKitEntitlementProvider(store: store) {
            await callCount.increment()
            return .confirmed(isPro: true)
        }

        provider.start()
        provider.start()

        // 非同期に発火する初回 refresh() が終わるまで少し待つ。
        try? await Task.sleep(nanoseconds: 300_000_000)

        let count = await callCount.value
        XCTAssertEqual(count, 1, "start() を2回呼んでも observe は1回しか走らないはず")
    }
}

/// テスト用のインメモリ `EntitlementStatusStore`。
private final class InMemoryEntitlementStatusStore: EntitlementStatusStore {
    private var value: EntitlementStatus

    init(initial: EntitlementStatus) {
        self.value = initial
    }

    func load() -> EntitlementStatus { value }
    func save(_ status: EntitlementStatus) { value = status }
}

/// `observe` の呼び出し回数を actor で数える（テストの並行呼び出しに対して安全）。
private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
