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
/// 今回（写真モード底上げ 第1段）は `colorGrade` だけを持つ。テキスト・回転はこの後の段で足す。
public struct PhotoEditState: Equatable, Sendable, Codable {
    /// 色調補正（明るさ・コントラスト・彩度・暖かみ）。
    public var colorGrade: ColorGrade

    public init(colorGrade: ColorGrade = .identity) {
        self.colorGrade = colorGrade
    }

    /// 無編集（既定値）。
    public static let identity = PhotoEditState()

    /// 全項目が既定値と一致するか（＝無編集）。
    public var isIdentity: Bool {
        colorGrade.isIdentity
    }
}
