import Foundation

/// ステッカーピッカーが出す絵文字の分類。
public enum StickerCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case faces
    case gestures
    case hearts
    case symbols

    /// 設定画面に出す名前（`TextFontFamily.displayName` と同じ流儀。
    /// rawValue は永続化に関わらないが、UI 表示名と識別子の変更理由を分けておく）。
    public var displayName: String {
        switch self {
        case .faces: return "顔"
        case .gestures: return "ジェスチャー"
        case .hearts: return "ハート"
        case .symbols: return "記号"
        }
    }
}

/// カテゴリ付きの絵文字ステッカーカタログ（v1）。
///
/// **iOS 16 で確実に描ける絵文字だけを載せる。** iOS 16 が発売された 2022 年より後に
/// 追加された絵文字（Unicode 15 以降の新規絵文字等）は端末によって「.notdef」の
/// 四角として描かれるおそれがあるため、それより前から存在する定番の絵文字だけを選ぶ。
///
/// **カタログはデコードのゲートではない。** `TextItem.text`（ステッカーの中身）は
/// ただの `String` で、カタログに無い絵文字が入っていてもデコードは弾かない
/// （`role` が未知の文字列を `.text` へ倒すのと同じ「保存済みの下書きを壊さない」
/// 方針。カタログは UI が選択肢を並べるための一覧に過ぎない）。
public enum StickerCatalog {
    /// カテゴリごとの絵文字一覧（表示順）。
    public static let items: [StickerCategory: [String]] = [
        .faces: ["😀", "😂", "😍", "😎", "😭", "😡", "🥳", "😱", "🤔", "😴"],
        .gestures: ["👍", "👎", "👏", "🙌", "✌️", "🤞", "👌", "🤙", "💪", "🙏"],
        .hearts: ["❤️", "💛", "💚", "💙", "💜", "🖤", "🤍", "💕", "💔", "💯"],
        .symbols: ["🔥", "⭐️", "✨", "🎉", "❗️", "❓", "✅", "⚠️", "🚫", "💡"]
    ]

    /// 全カテゴリを表示順に並べたフラットな一覧。
    public static var allItems: [String] {
        StickerCategory.allCases.flatMap { items[$0] ?? [] }
    }

    /// 指定カテゴリの絵文字一覧（未登録カテゴリは空配列）。
    public static func items(in category: StickerCategory) -> [String] {
        items[category] ?? []
    }
}
