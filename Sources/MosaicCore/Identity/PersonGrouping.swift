import Foundation

/// 検出顔の並びを「人物」単位へまとめる純ロジック。
///
/// **なぜ必要か**: 顔一覧は今まで「検出された顔」を 1 件ずつ並べていた。同じ人が
/// 途中でフレームアウトして再入すると別のターゲットとして増え、利用者から見ると
/// 「同じ人が 2 人いる」状態になる。署名で人物 ID が付いた顔は 1 つのチップにまとめ、
/// 選択も人物単位で行う。
///
/// **人物 ID が付いていない顔（`nil`）は、まとめない**。署名が取れていない顔どうしを
/// 「たぶん同じ人」でまとめると、別人を一括で選択解除してしまう。この機能は
/// 「選んだ人だけ隠す」意味なので、まとめ損ねる（チップが 2 つに割れる）方は
/// 見た目の問題で済むが、まとめ間違えると**隠すべき人が素で映る**。
public enum PersonGrouping {

    /// `personIDs` の並びを、同じ人物 ID どうしのまとまりへ分割する。
    ///
    /// - Returns: 元の並び順（各グループの**最初の要素が現れた順**）を保った添字のグループ。
    ///   `nil` の要素はそれぞれ単独のグループになる。
    ///   返り値の全添字を集めると `0..<personIDs.count` に一致する（欠落も重複もない）。
    public static func groupIndices(personIDs: [UUID?]) -> [[Int]] {
        var groups: [[Int]] = []
        var indexOfPerson: [UUID: Int] = [:]
        for (i, personID) in personIDs.enumerated() {
            guard let personID else {
                groups.append([i])
                continue
            }
            if let existing = indexOfPerson[personID] {
                groups[existing].append(i)
            } else {
                indexOfPerson[personID] = groups.count
                groups.append([i])
            }
        }
        return groups
    }
}
