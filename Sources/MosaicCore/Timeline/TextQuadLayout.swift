import Foundation

/// テキストのラスタライズ・描画で共有する定数。
///
/// `TextRasterizer`（アプリ層。フォント解決を担う唯一の場所）はこの点数で
/// ビットマップを焼く。`TextQuadLayout` はその px サイズを、実際に置く
/// `TextStyle.fontSize`（出力枠高さ比）へ逆算で合わせ込む。**両者は同じ基準点数を
/// 見ていなければならない**（片方だけ変えると文字の実寸がずれる）。
public enum TextRasterConstants {
    /// ラスタライズ基準フォントサイズ（pt = 無変換のビットマップ座標では px と等価）。
    /// 大きめに取って後段の縮小描画で滲まないようにする。
    public static let referenceFontPoints: Double = 200
}

/// 出力キャンバス上にテキストのビットマップを置く矩形（px、左上原点）と不透明度。
///
/// **プレビューと書き出しの唯一の入口。** ラスタライズした画像の px サイズと
/// 現在のキャンバスサイズから矩形を計算するのはこの関数だけであり、
/// 呼び出し側（プレビュー・書き出し）はこの結果をそのまま Metal へ渡すこと
/// （px 換算を呼び出し側で書くと、プレビューと書き出しで文字の大きさが食い違う）。
public struct TextQuadLayout: Equatable, Sendable {
    /// 左上原点（px、キャンバス座標）。
    public var originX: Double
    public var originY: Double
    /// 矩形サイズ（px）。
    public var width: Double
    public var height: Double
    /// 不透明度（0...1）。`TextRenderParameters.opacity` をそのまま運ぶ。
    public var opacity: Double

    public init(originX: Double, originY: Double, width: Double, height: Double, opacity: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.opacity = opacity
    }

    /// - Parameters:
    ///   - center: 出力枠に対する中心位置（0...1）。`TextItem.center`。
    ///   - style: `TextItem.style`（`fontSize` が px 換算の元）。
    ///   - rasterSize: ラスタライズ済みビットマップの px サイズ
    ///     （`TextRasterConstants.referenceFontPoints` で焼いたときの実寸）。
    ///   - canvasSize: 描画先テクスチャの px サイズ（プレビューは縮小後、書き出しは原寸）。
    ///   - renderParameters: `TextItem.renderParameters(atComposition:)` の戻り値
    ///     （offset/scale/opacity）。
    /// - Returns: 非有限・0 以下のサイズが混じったら nil（描画をスキップする合図）。
    public static func compute(
        center: NormalizedPoint,
        style: TextStyle,
        rasterSize: (width: Double, height: Double),
        canvasSize: (width: Double, height: Double),
        renderParameters: TextRenderParameters
    ) -> TextQuadLayout? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              rasterSize.width > 0, rasterSize.height > 0,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              rasterSize.width.isFinite, rasterSize.height.isFinite,
              center.isFinite else { return nil }

        // fontSize は出力枠「高さ」に対する比。基準点数で焼いたビットマップを
        // その比になるよう縮小/拡大する一様スケール（縦横で別スケールにすると
        // フォントの縦横比が崩れる）。
        let baseScale = (style.fontSize * canvasSize.height) / TextRasterConstants.referenceFontPoints
        let scale = baseScale * renderParameters.scale
        guard scale.isFinite, scale > 0 else { return nil }

        let width = rasterSize.width * scale
        let height = rasterSize.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

        // offsetX/offsetY は `NormalizedPoint` と同じ流儀でそれぞれの軸に対する比。
        let centerX = center.x * canvasSize.width + renderParameters.offsetX * canvasSize.width
        let centerY = center.y * canvasSize.height + renderParameters.offsetY * canvasSize.height
        guard centerX.isFinite, centerY.isFinite else { return nil }

        let opacity = renderParameters.opacity.isFinite
            ? min(max(renderParameters.opacity, 0), 1)
            : 0

        return TextQuadLayout(
            originX: centerX - width / 2,
            originY: centerY - height / 2,
            width: width,
            height: height,
            opacity: opacity
        )
    }
}
