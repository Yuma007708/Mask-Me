import Foundation

/// `TextItem` 列・単体文字列の正規化の**唯一の実装**。
///
/// `TimelineState`（動画。`TimelineStateTextEditing.swift`）と `PhotoEditState`
/// （写真。`PhotoTextEditing.swift`）の両方がここを呼ぶ。**コピーしないこと。**
/// コピーすると、たとえば「ステッカーは書記素クラスタ 1 個へ切り詰める」規則を
/// 片方だけ実装し忘れ、写真だけ絵文字が複数個通ってしまう——という食い違いが生まれる
/// （数式・判定ロジックの二重実装を禁止する、このリポジトリ全体の規約と同じ理由）。
enum TextItemNormalization {
    /// テキスト列を不変条件へ正規化する。
    ///
    /// 1. `compositionStart` 昇順に並べ替える（描画の重ね順でもある）
    /// 2. 非有限・負の開始位置・最小長未満・空文字を落とす
    /// 3. 文字数の上限で切る（`role == .sticker` は書記素クラスタ 1 個へ切る）
    /// 4. 位置とスタイルを有効域へ収める（`fontSize` の上限は役割ごと）
    ///
    /// **重なりは解消しない**（テキストは重なってよい。BGM との違い）。
    static func normalizedTextItems(_ items: [TextItem]) -> [TextItem] {
        items.compactMap { item -> TextItem? in
            guard item.compositionStart.isFinite, item.duration.isFinite,
                  item.compositionStart >= 0,
                  item.duration >= TextItem.minimumDuration else { return nil }
            var trimmed = normalizedText(item.text)
            if item.role == .sticker {
                // 結合絵文字（家族・肌色修飾つき等）は Swift の `Character` が
                // 拡張書記素クラスタ単位でまとまっているので、`.first` を取るだけで
                // 壊さずに 1 個へ切れる（自前の Unicode 分割ロジックを書かない）。
                trimmed = trimmed.first.map(String.init) ?? ""
            }
            guard !trimmed.isEmpty else { return nil }
            var next = item
            next.text = trimmed
            next.center = item.center.clamped
            next.style = item.style.clamped(maximumFontSize: item.role.maximumFontSize)
            return next
        }
        .sorted { $0.compositionStart < $1.compositionStart }
    }

    /// 前後の空白を落とし、上限文字数で切る。
    static func normalizedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > TextItem.maximumTextLength else { return trimmed }
        return String(trimmed.prefix(TextItem.maximumTextLength))
    }
}
