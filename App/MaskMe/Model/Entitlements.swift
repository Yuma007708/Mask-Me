import Foundation
import Combine

/// 課金エンタイトルメントの読み取り口。
///
/// 今はテスト段階で全機能を解放するため `LocalEntitlementProvider` が常に `isPro = true` を返す。
/// リリース時に StoreKit と接続した実装に差し替えるだけで、UI 側のロック判定は変えずに済む設計。
///
/// 設定 UI は `EntitlementProvider.shared.isPro` を見て、補助検出器トグルの `locked` を決める。
public protocol EntitlementProvider: AnyObject {
    /// Pro 機能解放済みか（補助検出器の選択 UI を有効化するか）。
    var isPro: Bool { get }
    /// `isPro` 変化を購読するための publisher。
    var isProPublisher: AnyPublisher<Bool, Never> { get }
}

/// テスト・開発中の実装。常に `isPro = true`。
/// 本番リリース前に StoreKit 連携版へ差し替える。
public final class LocalEntitlementProvider: EntitlementProvider, ObservableObject {
    public static let shared: EntitlementProvider = LocalEntitlementProvider()

    @Published public private(set) var isPro: Bool = true

    public var isProPublisher: AnyPublisher<Bool, Never> {
        $isPro.eraseToAnyPublisher()
    }

    private init() {}
}
