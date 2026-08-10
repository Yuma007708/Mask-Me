import Foundation

/// 権限の確定状態（3値）。
///
/// **Bool 1つで持たない理由**: StoreKit の `currentEntitlements` は起動直後の読み込み中や
/// 通信失敗時に「読めない」ことがある。ここを Bool（`isPro: true/false`）で表現すると、
/// 読めなかった場合を `false` に丸めるしかなくなり、電波が無いだけで Pro ユーザーに
/// 透かしが入る事故になる。`.unknown` を独立した状態として持つことで、
/// 「読めなかった」を「free だった」と混同しない。
///
/// 端末に保存する値でもあるため `Codable`。
public enum EntitlementStatus: String, Codable, Sendable, Equatable {
    /// まだ確定していない（起動直後・通信失敗で保存値も無い）。
    case unknown
    case pro
    case free
}
