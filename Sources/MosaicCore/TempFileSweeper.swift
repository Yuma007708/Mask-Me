import Foundation

/// 一時ファイル掃除の判定ロジック（純関数）。
///
/// 書き出し・取り込みの中間ファイル（`picked-*.mov` / `photoclip-*.mp4` / `mosaic-*.mp4`）は
/// これまで削除されず tmp に溜まり続けていた。実際の列挙・削除はアプリ層（FileManager）が行い、
/// ここは**消してよいかの判断だけ**を担う。
///
/// ⚠️ 下書きの素材本体（`source-*`）・サムネイル（`thumb-*`）・索引 JSON は
/// **絶対に削除対象にしない**。消すと復元できない下書き破壊になるため、
/// 判定は「このアプリが作った中間ファイルだと明示的に分かるもの」だけを許可する
/// ホワイトリスト方式にしてある。
public enum TempFileSweeper {
    /// 掃除対象とする接頭辞。これ以外のファイルは一切削除しない。
    public static let managedPrefixes = ["picked-", "photoclip-", "mosaic-"]

    /// 一時ファイルの既定の保持期間（24 時間）。
    /// 書き出し中・編集中のセッションを巻き込まないよう、当日中は残す。
    public static let defaultMaxAge: TimeInterval = 24 * 60 * 60

    /// 削除してよいか（`prefixes` のいずれかに前方一致し、かつ `maxAge` より古い）。
    ///
    /// 次の場合は `false`（＝残す）。判断がつかないときは常に残す側へ倒す:
    /// - 接頭辞が一致しない（`source-` / `thumb-` / 索引 JSON はここで落ちる）
    /// - 空文字の接頭辞（全ファイルに一致してしまうため無視する）
    /// - 経過時間がちょうど `maxAge`（境界は残す）、または `maxAge` が非有限
    /// - `modifiedAt > now`（時計の巻き戻し・未来日時。経過時間が負になるので自然に残る）
    public static func shouldDelete(name: String,
                                    modifiedAt: Date,
                                    now: Date,
                                    prefixes: [String] = managedPrefixes,
                                    maxAge: TimeInterval = defaultMaxAge) -> Bool {
        guard prefixes.contains(where: { !$0.isEmpty && name.hasPrefix($0) }) else { return false }
        guard maxAge.isFinite else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        return age > maxAge
    }
}
