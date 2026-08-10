import Foundation
import Combine
import MosaicCore
#if canImport(StoreKit)
import StoreKit
#endif

/// 権限状態（`EntitlementStatus`）の読み書き先。
///
/// UserDefaults 実装（本番）とインメモリ実装（テスト）を差し替えられるようにするための境界。
protocol EntitlementStatusStore: AnyObject {
    func load() -> EntitlementStatus
    func save(_ status: EntitlementStatus)
}

/// `UserDefaults` に保存する実装。
///
/// 保存値は `EntitlementStatus.rawValue`（String）。未保存・未知の値（将来 case が
/// 増えて旧バージョンが読めない場合を含む）は必ず `.unknown` に倒す
/// （`EntitlementResolver` の 3値設計と同じ理由 — 未確定を free と混同しない）。
final class UserDefaultsEntitlementStatusStore: EntitlementStatusStore {
    /// `UserDefaults` のキー。プレフィックス `billing.` で他機能のキーと衝突しないようにする。
    static let statusKey = "billing.entitlementStatus"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EntitlementStatus {
        guard let raw = defaults.string(forKey: Self.statusKey),
              let status = EntitlementStatus(rawValue: raw) else {
            return .unknown
        }
        return status
    }

    func save(_ status: EntitlementStatus) {
        defaults.set(status.rawValue, forKey: Self.statusKey)
    }
}

/// StoreKit 2 と接続した `EntitlementProvider` の本番実装。
///
/// **StoreKit を直接叩く部分は `observe` クロージャへ注入する**（イニシャライザ引数）。
/// これにより `MaskMeTests` は StoreKit を一切使わず、fake の `observe` と
/// インメモリの `EntitlementStatusStore` だけでオフライン回帰・保存挙動を固定できる。
///
/// **スレッド安全性**: `isPro` はプレビューの描画ループ
/// （`MosaicPreviewController+Rendering.renderCurrentFrame()`）から毎フレーム、
/// バックグラウンドスレッドで同期に読まれる。そのため `@MainActor` は付けず、
/// `NSLock` で保護した内部状態を同期に読み出す。状態の**更新**（`@Published` への反映）は
/// 必ずメインスレッドで行う。
final class StoreKitEntitlementProvider: EntitlementProvider {
    private let store: EntitlementStatusStore
    private let observe: @Sendable () async -> EntitlementObservation

    private let lock = NSLock()
    private var lockedStatus: EntitlementStatus

    /// メインスレッド上でのみ更新する（`@MainActor` を型に付けると `isPro` の
    /// 同期読み出しができなくなるため、更新経路だけを `Task { @MainActor in ... }` で縛る）。
    @Published private var publishedIsPro: Bool

    /// `Transaction.updates` を購読するタスク。`start()` の二重購読を防ぐため、
    /// nil でなければ「購読済み」とみなす。
    private var updatesTask: Task<Void, Never>?
    private let startLock = NSLock()

    /// - Parameters:
    ///   - store: 権限の保存先。
    ///   - observe: StoreKit の権利を観測する処理。本番は `Transaction.currentEntitlements` を
    ///     読む実装（`convenience init()` 参照）、テストは fake を注入する。
    init(store: EntitlementStatusStore, observe: @escaping @Sendable () async -> EntitlementObservation) {
        self.store = store
        self.observe = observe
        let cached = store.load()
        self.lockedStatus = cached
        self.publishedIsPro = EntitlementResolver.grantsPro(cached)
    }

    /// 本番用の簡便イニシャライザ（UserDefaults + 実 StoreKit）。
    convenience init() {
        self.init(store: UserDefaultsEntitlementStatusStore(),
                   observe: StoreKitEntitlementProvider.observeStoreKitEntitlements)
    }

    // MARK: - EntitlementProvider

    var isPro: Bool {
        lock.lock()
        defer { lock.unlock() }
        return EntitlementResolver.grantsPro(lockedStatus)
    }

    var isProPublisher: AnyPublisher<Bool, Never> {
        $publishedIsPro.eraseToAnyPublisher()
    }

    /// いま採用している確定状態（`.unknown` を含む3値）。
    var status: EntitlementStatus {
        lock.lock()
        defer { lock.unlock() }
        return lockedStatus
    }

    // MARK: - ライフサイクル

    /// 起動時に一度呼ぶ。初回観測と `Transaction.updates` の購読を始める。
    ///
    /// 二重に呼んでも購読が二重にならないよう、`updatesTask` の有無で判定する
    /// （`startLock` で判定と生成の間の競合を防ぐ）。
    func start() {
        startLock.lock()
        let alreadyStarted = updatesTask != nil
        if !alreadyStarted {
            updatesTask = Task { [weak self] in
                await self?.subscribeToTransactionUpdates()
            }
        }
        startLock.unlock()

        guard !alreadyStarted else { return }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    /// 権利を取り直す（購入直後・復元直後・フォアグラウンド復帰時に呼ぶ）。
    func refresh() async {
        let observation = await observe()
        await apply(observation: observation)
    }

    /// `Transaction.updates` を起動から終了まで購読し続ける。
    /// 届いた transaction は finish してから権利を取り直す。
    private func subscribeToTransactionUpdates() async {
        #if canImport(StoreKit)
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
            }
            await refresh()
        }
        #endif
    }

    /// 観測結果を `EntitlementResolver` に通して確定状態を求め、保存とメインスレッドでの
    /// `@Published` 反映を行う。
    private func apply(observation: EntitlementObservation) async {
        lock.lock()
        let cached = lockedStatus
        lock.unlock()

        let resolved = EntitlementResolver.resolve(observation: observation, cached: cached)

        lock.lock()
        lockedStatus = resolved
        lock.unlock()

        store.save(resolved)

        let grantsPro = EntitlementResolver.grantsPro(resolved)
        await MainActor.run {
            self.publishedIsPro = grantsPro
        }
    }

    // MARK: - 本番の観測実装

    #if canImport(StoreKit)
    /// `Transaction.currentEntitlements` を最後まで読み切り、`SubscriptionPlan` に一致する
    /// **検証済み（`.verified`）** の権利が1つでもあれば Pro とみなす。
    ///
    /// `.unverified` は署名検証に落ちた transaction（改ざん・不正なレシート等の疑い）なので、
    /// Pro 権利として数えない。
    ///
    /// **`.unavailable` を返すのは「検証済みの権利が1つも無く、かつ検証に落ちたものが
    /// あった」ときだけ。** ここが 3値設計の実際の効きどころなので、判定を緩めないこと:
    ///
    /// - `Transaction.currentEntitlements` は**投げない** `AsyncSequence` であり、
    ///   「通信できなかった」と「権利が無い」を型で区別できない。空で終わったことを
    ///   `.unavailable` に倒すと、解約・期限切れの人が永久に Pro のままになる
    ///   （キャッシュが `.pro` のまま更新されない）。だから**空は `.confirmed(isPro: false)`**。
    /// - これが安全なのは、StoreKit 2 が署名済み transaction を**端末にキャッシュ**して
    ///   おり、`currentEntitlements` がそのキャッシュから答えるため。電波が無いだけで
    ///   空になる設計ではない。
    /// - 一方 `.unverified` しか無い状態は「StoreKit は答えたが内容を信用できない」であり、
    ///   これを free と確定すると**検証が一時的に壊れただけで Pro が剥がれる**。
    ///   ここは保存値の維持（`.unavailable`）へ倒す。
    @Sendable
    static func observeStoreKitEntitlements() async -> EntitlementObservation {
        var foundPro = false
        var sawUnverified = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                sawUnverified = true
                continue
            }
            if SubscriptionPlan(productID: transaction.productID) != nil {
                foundPro = true
            }
        }
        if !foundPro, sawUnverified { return .unavailable }
        return .confirmed(isPro: foundPro)
    }
    #endif
}
