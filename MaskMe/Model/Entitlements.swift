import Foundation
import Combine

/// 課金エンタイトルメントの読み取り口。
///
/// 本番は `StoreKitEntitlementProvider`（P3b で接続）。アプリが使う唯一の注入点は
/// `Entitlements.shared`（このファイル下部）で、既存コードはそちらを参照する。
///
/// 設定 UI は `Entitlements.shared.isPro` を見て、補助検出器トグルの `locked` を決める。
public protocol EntitlementProvider: AnyObject {
    /// Pro 機能解放済みか（補助検出器の選択 UI を有効化するか）。
    var isPro: Bool { get }
    /// `isPro` 変化を購読するための publisher。
    var isProPublisher: AnyPublisher<Bool, Never> { get }
}

/// テスト・開発用の実装。常に `isPro = true` を返す。
///
/// 本番経路（`Entitlements.shared`）では使わない。`MaskMeTests` や、
/// `#if DEBUG` の強制切り替え（`Entitlements.shared` の doc 参照）が利用する。
public final class LocalEntitlementProvider: EntitlementProvider, ObservableObject {
    public static let shared: EntitlementProvider = LocalEntitlementProvider()

    @Published public private(set) var isPro: Bool = true

    public var isProPublisher: AnyPublisher<Bool, Never> {
        $isPro.eraseToAnyPublisher()
    }

    private init() {}
}

/// アプリが `EntitlementProvider` を読む唯一の注入点。
///
/// 本番は `StoreKitEntitlementProvider`。`#if DEBUG` かつ環境変数
/// `MASKME_FORCE_PRO` / `MASKME_FORCE_FREE` が設定されているときだけ、
/// シミュレータでの目視確認用に `LocalEntitlementProvider` 相当（固定値を返す
/// `ObservableObject` 実装）へ差し替える。
///
/// **使い方**（Xcode スキームの環境変数、または `xcodebuild test` の `-e`）:
/// `MASKME_FORCE_PRO=1` → 常に Pro。`MASKME_FORCE_FREE=1` → 常に無料。
/// 両方設定された場合は `MASKME_FORCE_PRO` を優先する。どちらも未設定なら
/// 通常どおり StoreKit を使う。
public enum Entitlements {
    public static let shared: EntitlementProvider = makeShared()

    private static func makeShared() -> EntitlementProvider {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["MASKME_FORCE_PRO"] != nil {
            return ForcedEntitlementProvider(isPro: true)
        }
        if env["MASKME_FORCE_FREE"] != nil {
            return ForcedEntitlementProvider(isPro: false)
        }
        #endif
        return StoreKitEntitlementProvider()
    }
}

#if DEBUG
/// `#if DEBUG` の目視確認専用。固定値を返すだけで StoreKit も UserDefaults も触らない。
private final class ForcedEntitlementProvider: EntitlementProvider, ObservableObject {
    @Published private(set) var isPro: Bool

    init(isPro: Bool) {
        self.isPro = isPro
    }

    var isProPublisher: AnyPublisher<Bool, Never> {
        $isPro.eraseToAnyPublisher()
    }
}
#endif
