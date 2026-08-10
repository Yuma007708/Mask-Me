import Foundation

/// 正規化座標の点（0...1。出力枠の左上原点）。
///
/// **`CGPoint` を使わない。** コア層の値型を `Sendable` に保ちたいのと、
/// 「これは正規化座標であって px ではない」を型で示すため。px への換算は
/// 描画側が出力枠サイズを掛けて行う（プレビューと書き出しで同じ関数を通すこと）。
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)

    /// 0...1 へ収める（画面外へ出したテキストを永久に掴めなくしない）。
    public var clamped: NormalizedPoint {
        NormalizedPoint(x: Self.clamp(x), y: Self.clamp(y))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// 不透明度つきの色（0...1）。
///
/// `UIColor` / `SwiftUI.Color` を持たないのはコア層を UI 非依存に保つため
/// （`MosaicCore` は MediaPipe 非依存と同じ理由で、描画フレームワークからも独立させる）。
public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    /// 各成分を 0...1 へ収める（非有限は不透明な白に落とす。`TimelineClip.clampedRate`
    /// と同じ流儀で、NaN が描画層まで流れると色が実装依存で化ける）。
    public var clamped: RGBAColor {
        guard red.isFinite, green.isFinite, blue.isFinite, alpha.isFinite else { return .white }
        func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
        return RGBAColor(red: unit(red), green: unit(green), blue: unit(blue), alpha: unit(alpha))
    }
}

/// テキストの書体（システム標準から数種）。
///
/// **フォント名を文字列で持たない。** 端末に無いフォント名を保存すると、復元時に
/// 黙って別の書体で描かれる（下書きを開くたびに見た目が変わる）。列挙にしておけば
/// 実際のフォント解決はアプリ層の 1 箇所に閉じ、未知の値は Codable が弾く。
public enum TextFontFamily: String, Codable, Sendable, CaseIterable {
    /// 標準（`.systemFont`）。
    case system
    /// 太字の標準。見出し向け。
    case systemBold
    /// 丸ゴシック（`.rounded`）。やわらかい印象。
    case rounded
    /// 明朝（`.serif`）。
    case serif
    /// 等幅（`.monospaced`）。数字が揃う。
    case monospaced

    /// 設定画面に出す名前。
    ///
    /// **`rawValue` をそのまま画面へ出さないこと。** rawValue は永続化の識別子なので、
    /// 表示名を変えたくなったときに保存済みの下書きが読めなくなる（両者の変更理由が違う）。
    public var displayName: String {
        switch self {
        case .system: return "標準"
        case .systemBold: return "太字"
        case .rounded: return "丸ゴシック"
        case .serif: return "明朝"
        case .monospaced: return "等幅"
        }
    }
}

/// テキストの見た目。
///
/// **`fontSize` は出力枠の高さに対する比**（px ではない）。px で持つと、
/// 解像度の違う素材を並べたときや、プレビュー（画面サイズ）と書き出し（renderSize）で
/// 文字の大きさが変わる。換算は描画側が `outputHeight * fontSize` で行う。
public struct TextStyle: Codable, Equatable, Sendable {
    /// これを下回る文字は読めないので許さない（出力枠高さ比）。
    public static let minimumFontSize: Double = 0.01
    /// これを超えると 1 文字で画面が埋まる（出力枠高さ比）。
    public static let maximumFontSize: Double = 0.5
    /// 既定の文字サイズ（1080p で約 54px）。
    public static let defaultFontSize: Double = 0.05

    /// ステッカー（絵文字 1 個）に許す上限（出力枠高さ比）。文字と違い 1 個しか
    /// 置かないので、画面いっぱいまで拡大してよい。
    public static let maximumStickerSize: Double = 1.0

    public var fontSize: Double
    public var fontFamily: TextFontFamily
    public var color: RGBAColor
    /// 縁取りの太さ（文字サイズに対する比）。0 なら縁取りなし。
    ///
    /// **既定で縁取りを入れる。** 明るい映像に白文字を置くと読めなくなるので、
    /// 何も設定しない状態でどんな映像の上でも読めることを既定にする。
    public var strokeWidth: Double
    public var strokeColor: RGBAColor
    /// 文字の後ろに敷く帯の不透明度。0 なら帯なし。
    public var backgroundOpacity: Double
    public var backgroundColor: RGBAColor

    public init(fontSize: Double = TextStyle.defaultFontSize,
                fontFamily: TextFontFamily = .systemBold,
                color: RGBAColor = .white,
                strokeWidth: Double = 0.08,
                strokeColor: RGBAColor = .black,
                backgroundOpacity: Double = 0,
                backgroundColor: RGBAColor = .black) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.color = color
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.backgroundOpacity = backgroundOpacity
        self.backgroundColor = backgroundColor
    }

    /// ステッカーの既定見た目。絵文字自体が装飾を持つので、縁取り・背景は載せない。
    public static let stickerDefault = TextStyle(fontSize: 0.18, strokeWidth: 0, backgroundOpacity: 0)

    /// 全項目を有効域へ収める（`fontSize` の上限は `TextStyle.maximumFontSize`）。
    /// **描画へ渡す前に必ず通すこと**（非有限が 1 つ混じるだけでレイアウト全体が
    /// NaN 汚染される）。
    ///
    /// ステッカーは上限が異なる（`TextItemRole.maximumFontSize` 参照）ので、
    /// その経路は `clamped(maximumFontSize:)` を直接呼ぶこと。数式はそちら 1 本に
    /// まとめてあり、ここはその既定引数版でしかない。
    public var clamped: TextStyle { clamped(maximumFontSize: Self.maximumFontSize) }

    /// 全項目を有効域へ収める（`fontSize` の上限を呼び出し側から指定する版）。
    ///
    /// **数式は 1 本。** 役割ごとの上限違いは呼び出し側（`TextItemRole.maximumFontSize`）
    /// が渡す引数の違いだけで表現し、ここに役割の分岐を書かない。
    public func clamped(maximumFontSize: Double) -> TextStyle {
        func unit(_ value: Double, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, 0), 1)
        }
        var result = self
        result.fontSize = fontSize.isFinite
            ? min(max(fontSize, Self.minimumFontSize), maximumFontSize)
            : Self.defaultFontSize
        result.strokeWidth = unit(strokeWidth, fallback: 0)
        result.backgroundOpacity = unit(backgroundOpacity, fallback: 0)
        result.color = color.clamped
        result.strokeColor = strokeColor.clamped
        result.backgroundColor = backgroundColor.clamped
        return result
    }
}

/// `TextItem` が画面上で担う役割。
///
/// **新しい型・新しいレイヤー段は作らない。** 絵文字ステッカーは `TextItem` に
/// この役割を 1 つ足すだけで相乗りさせる（CoreText がそのまま絵文字を描けるので、
/// 描画経路は無変更で済む）。
public enum TextItemRole: String, Codable, Equatable, Sendable {
    /// 通常の文字。
    case text
    /// 絵文字ステッカー（書記素クラスタ 1 個）。
    case sticker

    /// この役割に許す `TextStyle.fontSize` の上限（出力枠高さ比）。
    ///
    /// **`normalizedTextItems` と `validateTextItems` の両方がこの 1 本だけを見る。**
    /// 二重に書くと「正規化は通すが validate は落ちる」状態を作れてしまう
    /// （`TimelineStateTextEditing.swift` の doc 参照）。
    public var maximumFontSize: Double {
        switch self {
        case .text: return TextStyle.maximumFontSize
        case .sticker: return TextStyle.maximumStickerSize
        }
    }
}

/// 画面に置く文字 1 本（E3）。
///
/// ## アンカーは BGM と同じ「合成時刻」
///
/// クリップの分割・並べ替え・トリムには追従しない（`AudioItem` 型の doc と同じ理由。
/// 字幕は特定のクリップに紐づく効果ではない）。したがって
/// `TimelineApplySpan.anchorClipID` は `.text` でも nil になる。
///
/// クリップを消して合成尺が縮んだときは、**データを温存して表示・描画の側で切る**
/// （`TimelineState.effectiveTextItems(totalDuration:)`）。適用区間の孤児・BGM と同じ規則。
///
/// ## 位置は正規化座標で持つ
///
/// `center` は出力枠に対する 0...1。px で持つと解像度混在のタイムラインで位置が飛ぶ。
public struct TextItem: Codable, Equatable, Sendable, Identifiable {
    /// これを下回る表示時間は許さない（帯として掴めない）。
    public static let minimumDuration: Double = 0.1
    /// 1 本のテキストに許す最大文字数。**上限を持つこと**: 無制限だと 1 本で
    /// 画面が埋まり、ラスタライズの負荷も青天井になる。
    public static let maximumTextLength = 200

    public let id: UUID
    public var text: String
    /// 合成タイムライン上の開始位置（秒）。
    public var compositionStart: Double
    /// 表示している長さ（秒）。
    public var duration: Double
    /// 出力枠に対する中心位置（0...1）。
    public var center: NormalizedPoint
    public var style: TextStyle
    public var animation: TextAnimation
    /// この項目が「文字」か「絵文字ステッカー」か（S12 で追加）。既定は `.text`
    /// （v5 以前の下書きは全部これだった）。
    public var role: TextItemRole

    public init(id: UUID = UUID(), text: String,
                compositionStart: Double, duration: Double,
                center: NormalizedPoint = .center,
                style: TextStyle = TextStyle(),
                animation: TextAnimation = .none,
                role: TextItemRole = .text) {
        self.id = id
        self.text = text
        self.compositionStart = compositionStart
        self.duration = duration
        self.center = center
        self.style = style
        self.animation = animation
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, compositionStart, duration, center, style, animation, role
    }

    /// `role`（v6 で追加）を持たない旧下書き、および未知の役割文字列を `.text` へ倒す。
    ///
    /// **ここで throw すると `role` の無い旧下書きが丸ごと開けなくなる。**
    /// `TimelineAspectRatio` の decode（`TimelineStateCodable.swift`）と同じ流儀:
    /// 二重オプショナルでコンテナ自体の欠如（キー無し）と型不一致（未知の値）の
    /// 両方を吸収し、どちらも `.text` に倒す。
    ///
    /// **`encode(to:)` は書かない。** `CodingKeys` に格納プロパティ以外の case が
    /// 無いので、Encodable の自動合成がそのまま成立し `role` も書かれる
    /// （`TimelineStateCodable.swift` の `schemaVersion` のような手書きが必要なケースとは違う）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        compositionStart = try container.decode(Double.self, forKey: .compositionStart)
        duration = try container.decode(Double.self, forKey: .duration)
        center = try container.decode(NormalizedPoint.self, forKey: .center)
        style = try container.decode(TextStyle.self, forKey: .style)
        animation = try container.decode(TextAnimation.self, forKey: .animation)
        let decodedRole: TextItemRole?? = try? container.decodeIfPresent(TextItemRole.self, forKey: .role)
        role = (decodedRole ?? .text) ?? .text
    }

    /// 合成タイムライン上の終端（秒・半開区間の右端）。
    public var compositionEnd: Double { compositionStart + duration }

    /// 合成尺 `totalDuration` で切った、実際に表示される部分。1 秒も出ないなら nil。
    ///
    /// **描画と帯表示は必ずこれを通すこと**（`AudioItem.clipped(toTotalDuration:)` と同じ役目）。
    public func clipped(toTotalDuration totalDuration: Double) -> TextItem? {
        guard totalDuration.isFinite, totalDuration > 0,
              compositionStart.isFinite, duration.isFinite else { return nil }
        let start = max(compositionStart, 0)
        let end = min(compositionEnd, totalDuration)
        guard end - start >= Self.minimumDuration else { return nil }
        var result = self
        result.compositionStart = start
        result.duration = end - start
        return result
    }

    /// 指定した合成時刻でこのテキストが出ているか（半開区間 `[start, end)`）。
    public func isVisible(atComposition time: Double) -> Bool {
        guard time.isFinite else { return false }
        return time >= compositionStart && time < compositionEnd
    }
}

extension Sequence where Element == TextItem {
    /// 指定した合成時刻に出ているテキストを、**描く順**（`compositionStart` 昇順）で返す。
    ///
    /// **`TimelineState.visibleTextItems(atComposition:totalDuration:)` と
    /// `VideoMosaicExporter` はこの 1 本だけを通すこと。** 「どれが出ているか」の
    /// 選択・整列ロジックを呼び出し側ごとに書くと、プレビューと書き出しで
    /// 半開区間の扱いや重ね順が食い違いかねない（数式の二重実装禁止と同じ理由）。
    public func visibleTextItems(atComposition time: Double, totalDuration: Double) -> [TextItem] {
        compactMap { $0.clipped(toTotalDuration: totalDuration) }
            .filter { $0.isVisible(atComposition: time) }
            .sorted { $0.compositionStart < $1.compositionStart }
    }
}
