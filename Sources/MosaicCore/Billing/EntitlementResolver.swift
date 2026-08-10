import Foundation

/// StoreKit の権限確認を試みた結果（アプリ層から渡される観測値）。
///
/// `MosaicCore` は StoreKit を知らないため、アプリ層が
/// `Transaction.currentEntitlements` を読み切れたかどうかをこの型に変換して渡す。
public enum EntitlementObservation: Sendable, Equatable {
    /// StoreKit の `currentEntitlements` を最後まで読み切れた（確定情報）。
    case confirmed(isPro: Bool)
    /// 読み取れなかった（起動直後・通信失敗・StoreKit エラー）。
    case unavailable
}

/// 観測結果と保存値（キャッシュ）から、いま採用すべき `EntitlementStatus` を決める純関数群。
///
/// **設計の全部**: `unavailable` のとき `cached` をそのまま返し、`.free` へ落とさないこと。
/// StoreKit は電波状況やアプリ起動タイミングによって読み取りに失敗することがあり、
/// これを「未確定」ではなく「free」として扱うと、オフラインになっただけで
/// Pro ユーザーの書き出しに透かしが入る。これは無料/Pro を Bool 1つで持つ実装が
/// 必ず踏む事故であり、3値 + この解決関数で構造的に防ぐ。
public enum EntitlementResolver {
    /// 観測結果と保存値から、いま採用すべき状態を決める。
    ///
    /// - `confirmed(true)` → `.pro`（保存して次回オフラインでも Pro を保つ）。
    /// - `confirmed(false)` → `.free`（期限切れ・返金は StoreKit が確定情報として
    ///   返せる内容なので、オフラインであっても free にしてよい。Pro を失った後に
    ///   古い `.pro` キャッシュを引きずる方が課金上の実害が大きい）。
    /// - `.unavailable` → `cached` をそのまま返す。読み取れなかったことは
    ///   「free になった」を意味しないため、直近確定していた状態を維持する。
    public static func resolve(observation: EntitlementObservation,
                               cached: EntitlementStatus) -> EntitlementStatus {
        switch observation {
        case .confirmed(let isPro):
            return isPro ? .pro : .free
        case .unavailable:
            return cached
        }
    }

    /// その状態で Pro 権限を与えるか（`ExportRestrictionPolicy.decide(isPro:)` へ渡す値）。
    ///
    /// `.pro` のみ true。`.unknown` を true にすると、一度も購入していない人が
    /// 起動直後（StoreKit 未確認）だけ Pro として扱われてしまうため、
    /// 未確定は必ず false（＝制限あり）側に倒す。
    public static func grantsPro(_ status: EntitlementStatus) -> Bool {
        status == .pro
    }
}
