import Foundation

/// テキスト（`TextItem`）の編集操作と正規化（E3）。
///
/// BGM（`TimelineStateAudioEditing.swift`）と同じ契約に従う:
/// **失敗時は self をそのまま返す**。合成時刻アンカーなのでクリップ編集への追従は無い。
///
/// **BGM との違いは「重なってよい」こと。** 複数の文字を同時に出せるので、
/// 移動・伸縮で隣とぶつかってもクランプしない（`movingAudioItem` との対比）。
extension TimelineState {
    /// テキストを 1 本追加する。
    ///
    /// 空文字（空白だけを含む）は追加しない。**入口で弾く**のは、空のテキストが
    /// 帯として出ても掴めず消せない（幅は出るが中身が無い）ためである。
    public func addingTextItem(_ text: String,
                               atCompositionTime start: Double,
                               duration: Double,
                               center: NormalizedPoint = .center,
                               style: TextStyle = TextStyle(),
                               animation: TextAnimation = .none) -> TimelineState {
        let trimmed = Self.normalizedText(text)
        guard !trimmed.isEmpty, start.isFinite, start >= 0,
              duration.isFinite, duration >= TextItem.minimumDuration else { return self }
        var next = self
        next.textItems = Self.normalizedTextItems(textItems + [
            TextItem(text: trimmed, compositionStart: start, duration: duration,
                     center: center.clamped, style: style.clamped, animation: animation)
        ])
        return next
    }

    /// 指定したテキストを取り除く。
    public func removingTextItem(id: UUID) -> TimelineState {
        guard textItems.contains(where: { $0.id == id }) else { return self }
        var next = self
        next.textItems = textItems.filter { $0.id != id }
        return next
    }

    /// 文面を書き換える（空文字にはできない）。**役割違い（ステッカー）は no-op**
    /// （中身の差し替えは `settingStickerContent(id:emoji:)` を通す。ここは書記素
    /// クラスタ 1 個への切り詰めをしないので、素通しするとステッカーの不変条件
    /// 〈`role == .sticker` は文字数 1〉が破れる）。
    public func settingText(id: UUID, text: String) -> TimelineState {
        let trimmed = Self.normalizedText(text)
        guard !trimmed.isEmpty,
              let index = textItems.firstIndex(where: { $0.id == id }),
              textItems[index].role == .text,
              textItems[index].text != trimmed else { return self }
        var next = self
        next.textItems[index].text = trimmed
        return next
    }

    /// 見た目を差し替える。
    ///
    /// **`fontSize` の上限は役割ごとに違う**（`TextItemRole.maximumFontSize`）ので、
    /// 対象の役割を先に引いてから `TextStyle.clamped(maximumFontSize:)` へ渡す。
    /// 既定の `TextStyle.clamped`（＝文字の上限 0.5 固定）をここで使うと、
    /// ステッカーの拡大が 0.5 で頭打ちになってしまう。
    public func settingTextStyle(id: UUID, style: TextStyle) -> TimelineState {
        guard let index = textItems.firstIndex(where: { $0.id == id }) else { return self }
        let clamped = style.clamped(maximumFontSize: textItems[index].role.maximumFontSize)
        guard textItems[index].style != clamped else { return self }
        var next = self
        next.textItems[index].style = clamped
        return next
    }

    /// ステッカー（絵文字 1 個）を 1 本追加する。
    ///
    /// **新しい配列・レイヤー段は作らない**（`TextItem.role` で相乗り）。中身は
    /// `normalizedTextItems` が書記素クラスタ 1 個へ切るので、ここでは空文字だけを弾く。
    public func addingStickerItem(_ emoji: String,
                                  atCompositionTime start: Double,
                                  duration: Double,
                                  center: NormalizedPoint = .center,
                                  animation: TextAnimation = .none) -> TimelineState {
        let trimmed = Self.normalizedText(emoji)
        guard !trimmed.isEmpty, start.isFinite, start >= 0,
              duration.isFinite, duration >= TextItem.minimumDuration else { return self }
        var next = self
        next.textItems = Self.normalizedTextItems(textItems + [
            TextItem(text: trimmed, compositionStart: start, duration: duration,
                     center: center.clamped, style: .stickerDefault, animation: animation,
                     role: .sticker)
        ])
        return next
    }

    /// ステッカーの中身（絵文字）を差し替える。**役割違い（普通のテキスト）は no-op**
    /// （`settingText(id:text:)` と役割を対称に分けておくことで、UI がステッカー
    /// ピッカーとテキスト入力を取り違えて書き込むのを防ぐ）。
    public func settingStickerContent(id: UUID, emoji: String) -> TimelineState {
        let trimmed = Self.normalizedText(emoji)
        guard !trimmed.isEmpty,
              let index = textItems.firstIndex(where: { $0.id == id }),
              textItems[index].role == .sticker,
              textItems[index].text != trimmed else { return self }
        var next = self
        next.textItems[index].text = trimmed
        next.textItems = Self.normalizedTextItems(next.textItems)
        return next
    }

    /// 出し方（アニメーション）を差し替える。
    public func settingTextAnimation(id: UUID, animation: TextAnimation) -> TimelineState {
        guard let index = textItems.firstIndex(where: { $0.id == id }),
              textItems[index].animation != animation else { return self }
        var next = self
        next.textItems[index].animation = animation
        return next
    }

    /// 画面上の位置（正規化座標）を差し替える（プレビュー上のドラッグの確定）。
    public func settingTextCenter(id: UUID, center: NormalizedPoint) -> TimelineState {
        let clamped = center.clamped
        guard let index = textItems.firstIndex(where: { $0.id == id }),
              textItems[index].center != clamped else { return self }
        var next = self
        next.textItems[index].center = clamped
        return next
    }

    /// 合成時刻で `delta` 秒だけ平行移動する。
    ///
    /// **隣とはぶつからない**（テキストは重なってよい）。0 秒より前へは行かない。
    /// 合成尺の右端では止めない（BGM と同じ温存の規則）。
    public func movingTextItem(id: UUID, byCompositionDelta delta: Double) -> TimelineState {
        guard delta.isFinite, delta != 0,
              let index = textItems.firstIndex(where: { $0.id == id }) else { return self }
        let desired = max(textItems[index].compositionStart + delta, 0)
        guard desired.isFinite,
              abs(desired - textItems[index].compositionStart) > 1e-9 else { return self }
        var next = self
        next.textItems[index].compositionStart = desired
        next.textItems = Self.normalizedTextItems(next.textItems)
        return next
    }

    /// 端を合成時刻で `delta` 秒だけ動かす（つまみの伸縮）。
    ///
    /// テキストは素材を持たないので**伸ばす上限が無い**（BGM の `sourceDuration` に
    /// あたるものが無い）。下限は `TextItem.minimumDuration` だけ。
    public func trimmingTextItem(id: UUID, edge: TimelineTrimEdge,
                                 byCompositionDelta delta: Double) -> TimelineState {
        guard delta.isFinite, delta != 0,
              let index = textItems.firstIndex(where: { $0.id == id }) else { return self }
        let item = textItems[index]
        var next = item
        switch edge {
        case .start:
            // 左端: 0 秒より前へは行かず、最小長は保つ。
            let minDelta = -item.compositionStart
            let maxDelta = item.duration - TextItem.minimumDuration
            let applied = min(max(delta, minDelta), maxDelta)
            guard abs(applied) > 1e-9 else { return self }
            next.compositionStart += applied
            next.duration -= applied
        case .end:
            let minDelta = TextItem.minimumDuration - item.duration
            let applied = max(delta, minDelta)
            guard abs(applied) > 1e-9 else { return self }
            next.duration += applied
        }
        guard next.duration >= TextItem.minimumDuration else { return self }
        var result = self
        result.textItems[index] = next
        result.textItems = Self.normalizedTextItems(result.textItems)
        return result
    }

    /// 合成尺で切った、実際に表示されるテキストだけを返す（表示と描画の唯一の入口）。
    ///
    /// **`textItems` を直接描画へ渡さないこと**（`effectiveAudioItems` と同じ役目）。
    public func effectiveTextItems(totalDuration: Double) -> [TextItem] {
        textItems.compactMap { $0.clipped(toTotalDuration: totalDuration) }
    }

    /// 指定した合成時刻に出ているテキストを、**描く順**（`compositionStart` 昇順）で返す。
    ///
    /// 描画側（プレビュー・書き出し）はこれ 1 本だけを呼ぶこと。「どれが出ているか」を
    /// 呼び出し側で書くと、プレビューと書き出しで半開区間の扱いが揃わない。
    ///
    /// **ここで並べ替えること。** `textItems` の順序は編集操作と Codable が正規化して
    /// いるが、`init` への直接代入（テスト・復元前の状態）は通らないので、順序を
    /// 保証すると約束したこの関数自身が並べ替える必要がある
    /// （並べ替えを呼び出し側に任せると、重ね順が呼び出し経路ごとに変わる）。
    public func visibleTextItems(atComposition time: Double,
                                 totalDuration: Double) -> [TextItem] {
        // 選択・整列ロジックの実体は `Sequence.visibleTextItems` 1 本だけに置く
        // （`VideoMosaicExporter` も同じ拡張を通すことで二重実装を避ける）。
        textItems.visibleTextItems(atComposition: time, totalDuration: totalDuration)
    }

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
