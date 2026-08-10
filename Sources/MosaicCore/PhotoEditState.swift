import Foundation

/// 写真モードの編集状態。**時間軸を持たない値型。**
///
/// `TimelineState`（動画モード用）を写真へ流用しないのは、以下の理由による
/// （`MosaicCore` は動画・写真どちらの都合にも中立でいるべきで、写真モードのために
/// 動画専用の型へ「時刻を持たない」特例を増やすと不変条件が緩んでいく）:
///
/// 1. 写真は `mapping.totalDuration == 0` になる。テキストの表示判定
///    `TextItem.clipped(toTotalDuration:)` は `totalDuration <= 0` で `nil` を返す設計
///    ——つまり `TimelineState` をそのまま写真へ流用すると、テキストが**1 本も描かれない**。
/// 2. `TimelineState.colorGrade(atComposition:)` はクリップと合成時刻の対応が無いと
///    解決できない。写真のために嘘のクリップ（ダミーの `sourceStart`/`sourceEnd`）を
///    でっち上げると、`TimelineStateValidation` が守っている「クリップは実在の素材区間を
///    指す」という不変条件に嘘が混じる。
/// 3. `TimelineClip` の `compositionStart` / `duration` / `animation` のような、写真には
///    そもそも定義されない値が下書きの JSON に永続化されてしまう。次にその下書きを読む人が
///    「読める値＝意味のある値」だと信じて参照するのが事故の起点になる
///    （実際には合成タイムラインが無いのでゴミ値でしかない）。
///
/// 写真モード底上げ 第1段で `colorGrade` を、第2段で `texts` を、第4段（今回）で
/// `orientation` を持たせた。
public struct PhotoEditState: Equatable, Sendable, Codable {
    /// 色調補正（明るさ・コントラスト・彩度・暖かみ）。
    public var colorGrade: ColorGrade

    /// テキスト・ステッカー（写真モード底上げ 第2段）。
    ///
    /// **保存値をそのまま描画へ渡さないこと。** `compositionStart` / `duration` /
    /// `animation` は写真には意味を持たない形式上の値（`PhotoTextEditing.swift` の
    /// 型 doc 参照）。描画は必ず `renderableTextItems` を経由する。
    ///
    /// **既定は `[]`。** 旧下書き（`texts` キーを持たない JSON）は
    /// `decodeIfPresent` で吸収し、空配列へ倒す（`init(from:)` 参照）。
    public var texts: [TextItem]

    /// 写真の向き（90 度単位の回転 + 左右反転。写真モード底上げ 第4段）。
    ///
    /// クリップの `ClipOrientation`（`TimelineStateOrientationEditing`）とは別スロット。
    /// `MosaicEditorModel.renderLayout` が写真モードのときだけこれを
    /// `stillOrientation` へ注入する（`renderLayout` の doc 参照）。
    ///
    /// **既定は `.identity`。** 旧下書き（`orientation` キーを持たない JSON）は
    /// `decodeIfPresent` で吸収し、無変換へ倒す（`init(from:)` 参照）。
    public var orientation: ClipOrientation

    public init(colorGrade: ColorGrade = .identity, texts: [TextItem] = [],
                orientation: ClipOrientation = .identity) {
        self.colorGrade = colorGrade
        self.texts = texts
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case colorGrade, texts, orientation
    }

    /// `texts` / `orientation`（この後追加された項目）を持たない旧下書きを既定値へ倒す。
    ///
    /// **`decodeIfPresent` を使う。** キー自体が無い旧 JSON でも
    /// `container.decode(forKey:)` で throw させない——`TextItem.init(from:)` の
    /// `role` 欠如吸収と同じ流儀（`TextItem.swift` の doc 参照）。`orientation` 自体は
    /// `ClipOrientation.init(from:)` が壊れた値を無変換へ倒すので、ここでは
    /// キー欠如だけを吸収すればよい。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorGrade = try container.decode(ColorGrade.self, forKey: .colorGrade)
        texts = try container.decodeIfPresent([TextItem].self, forKey: .texts) ?? []
        orientation = try container.decodeIfPresent(ClipOrientation.self, forKey: .orientation) ?? .identity
    }

    /// 無編集（既定値）。
    public static let identity = PhotoEditState()

    /// 全項目が既定値と一致するか（＝無編集）。
    public var isIdentity: Bool {
        colorGrade.isIdentity && texts.isEmpty && orientation.isIdentity
    }
}
