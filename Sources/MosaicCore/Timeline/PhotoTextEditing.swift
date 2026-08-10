import Foundation

/// テキスト・ステッカー（`TextItem`）の写真モード編集操作（写真モード底上げ 第2段）。
///
/// `TimelineStateTextEditing.swift`（動画側）と同じ骨格。**失敗時は self をそのまま返す。**
///
/// ## 写真は「時間軸を持たない」が、`TextItem` は時間軸の値を要求する
///
/// `PhotoEditState` の型 doc（1〜3）が説明しているとおり、写真は合成タイムラインを
/// 持たない。しかし `TextItem` 自体は動画・写真で共有する値型で、`compositionStart` /
/// `duration` / `animation` を必ず持つ。ここでは追加時に固定値
/// （`compositionStart = 0` / `duration = PhotoEditState.textDuration` / `animation = .none`）
/// を詰めるが、**保存された値をそのまま信じて描画してはならない**——写真は
/// `visibleTextItems(atComposition:totalDuration:)`（`totalDuration == 0` で必ず空になる）を
/// 絶対に通らないので、描画は必ず `PhotoEditState.renderableTextItems` を経由すること
/// （このファイルの型 doc 最下部、および `renderableTextItems` 自身の doc 参照）。
///
/// ## 正規化はコピーしない
///
/// 書記素クラスタ 1 個への切り詰め・文字数上限・位置とスタイルのクランプは
/// `TextItemNormalization`（`TimelineStateTextEditing.swift` と共有）1 本だけで行う。
extension PhotoEditState {
    /// 写真1枚に対して置くテキスト・ステッカーの表示時間（秒）。
    ///
    /// 写真は合成タイムラインを持たないため「表示している長さ」に意味は無いが、
    /// `TextItem.minimumDuration`（0.1 秒）を満たす値を保持しておかないと
    /// `TextItemNormalization.normalizedTextItems` が最小長未満として弾いてしまう。
    /// 1 秒という具体値そのものに意味は無い（`renderableTextItems` が描画直前に
    /// 必ず上書きするため、これは「正規化を通すための形式上の値」でしかない）。
    public static let textDuration: Double = 1

    /// テキストを 1 本追加する。空文字（空白だけを含む）は追加しない
    /// （`TimelineState.addingTextItem` と同じ理由: 帯として出ても掴めず消せない）。
    public func addingText(_ text: String,
                           center: NormalizedPoint = .center,
                           style: TextStyle = TextStyle()) -> PhotoEditState {
        let trimmed = TextItemNormalization.normalizedText(text)
        guard !trimmed.isEmpty else { return self }
        var next = self
        next.texts = TextItemNormalization.normalizedTextItems(texts + [
            TextItem(text: trimmed,
                     compositionStart: 0, duration: PhotoEditState.textDuration,
                     center: center.clamped, style: style.clamped, animation: .none)
        ])
        return next
    }

    /// ステッカー（絵文字 1 個）を 1 本追加する。中身は `TextItemNormalization` が
    /// 書記素クラスタ 1 個へ切るので、ここでは空文字だけを弾く。
    public func addingSticker(_ emoji: String, center: NormalizedPoint = .center) -> PhotoEditState {
        let trimmed = TextItemNormalization.normalizedText(emoji)
        guard !trimmed.isEmpty else { return self }
        var next = self
        next.texts = TextItemNormalization.normalizedTextItems(texts + [
            TextItem(text: trimmed,
                     compositionStart: 0, duration: PhotoEditState.textDuration,
                     center: center.clamped, style: .stickerDefault, animation: .none,
                     role: .sticker)
        ])
        return next
    }

    /// 指定したテキストを取り除く。
    public func removingText(id: UUID) -> PhotoEditState {
        guard texts.contains(where: { $0.id == id }) else { return self }
        var next = self
        next.texts = texts.filter { $0.id != id }
        return next
    }

    /// 文面を書き換える（空文字にはできない）。**役割違い（ステッカー）は no-op**
    /// （`TimelineState.settingText` と同じ理由）。
    public func settingText(id: UUID, text: String) -> PhotoEditState {
        let trimmed = TextItemNormalization.normalizedText(text)
        guard !trimmed.isEmpty,
              let index = texts.firstIndex(where: { $0.id == id }),
              texts[index].role == .text,
              texts[index].text != trimmed else { return self }
        var next = self
        next.texts[index].text = trimmed
        return next
    }

    /// ステッカーの中身（絵文字）を差し替える。**役割違い（普通のテキスト）は no-op**
    /// （`TimelineState.settingStickerContent` と同じ理由）。
    public func settingStickerContent(id: UUID, emoji: String) -> PhotoEditState {
        let trimmed = TextItemNormalization.normalizedText(emoji)
        guard !trimmed.isEmpty,
              let index = texts.firstIndex(where: { $0.id == id }),
              texts[index].role == .sticker,
              texts[index].text != trimmed else { return self }
        var next = self
        next.texts[index].text = trimmed
        next.texts = TextItemNormalization.normalizedTextItems(next.texts)
        return next
    }

    /// 画面上の位置（正規化座標）を差し替える（プレビュー上のドラッグの確定）。
    public func settingTextCenter(id: UUID, center: NormalizedPoint) -> PhotoEditState {
        let clamped = center.clamped
        guard let index = texts.firstIndex(where: { $0.id == id }),
              texts[index].center != clamped else { return self }
        var next = self
        next.texts[index].center = clamped
        return next
    }

    /// 見た目を差し替える。**`fontSize` の上限は役割ごとに違う**
    /// （`TimelineState.settingTextStyle` と同じ理由）。
    public func settingTextStyle(id: UUID, style: TextStyle) -> PhotoEditState {
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return self }
        let clamped = style.clamped(maximumFontSize: texts[index].role.maximumFontSize)
        guard texts[index].style != clamped else { return self }
        var next = self
        next.texts[index].style = clamped
        return next
    }

    /// 描画へ渡す唯一の入口。**写真の描画はこれ 1 本だけを通すこと。**
    ///
    /// 保存値の `compositionStart` / `duration` / `animation` が何であれ
    /// （旧下書きの復元・将来のマイグレーション事故を含め）、`compositionStart = 0` /
    /// `duration = PhotoEditState.textDuration` / `animation = .none` へ正規化して返す。
    ///
    /// **`TimelineState.visibleTextItems(atComposition:totalDuration:)` を写真で
    /// 絶対に使わないこと。** `TextItem.clipped(toTotalDuration:)` は
    /// `totalDuration <= 0` で常に nil を返す設計なので、写真（`totalDuration == 0`）へ
    /// 通すとテキストが 1 本も描かれない（`PhotoEditState` の型 doc・規則 1 参照）。
    public var renderableTextItems: [TextItem] {
        texts.map { item in
            var next = item
            next.compositionStart = 0
            next.duration = PhotoEditState.textDuration
            next.animation = .none
            return next
        }
    }
}
