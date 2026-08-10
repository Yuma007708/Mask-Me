import CoreGraphics
import Foundation

/// 無料プランの書き出しに載せる透かしの見た目を決める純関数群（課金 P2）。
///
/// **プレビューと書き出しは必ずこの型を通すこと**（数式の二重実装を禁止。
/// `TextQuadLayout` と同じ思想）。透かしそのものの描画（ラスタライズ・合成）は
/// アプリ層の `WatermarkCompositor`（`MaskMe/Model/TextOverlayCompositor.swift`）が
/// 既存のテキスト描画部品を呼んで行う。ここは「どこに・どれくらいの大きさで」だけを
/// 決める、MediaPipe は当然、UIKit/Metal にも依存しない純関数の集まり。
public enum ExportWatermark {
    /// 透かしの文字列。1 種類だけで多言語化はしない（ブランド表記なので固定文字列）。
    public static let text = "Mask Me"

    /// 出力枠の**短辺**に対する文字サイズ比。
    ///
    /// `TextStyle.defaultFontSize`（0.05 = 出力枠高さの 5%、1080p で約 54px）より
    /// 一回り小さい 0.035 を採用。ユーザーが自分で置くテキストより目立たせないことが
    /// 「控えめ」の要件なので、既定文字サイズの 7 割程度に抑えた
    /// （1080p 縦動画・横動画のどちらでも、判読はできるが主張しない大きさ）。
    public static let fontSizeRatio: Double = 0.035

    /// 右下の余白（短辺比）。
    ///
    /// 文字サイズ比（0.035）の6割弱に設定。これより狭いと文字が枠に張り付いて見え、
    /// これより広いと右下から浮いて見える。1080p で約 22px、4K 相当でも比率が
    /// 短辺基準のため見た目の余白感が変わらない。
    public static let marginRatio: Double = 0.02

    /// 不透明度（0...1）。
    ///
    /// 0.5 を採用。存在は視認できるが映像の下地を完全には隠さない、目視確認で
    /// 「透かし」として自然に見える最小限の主張の強さとして選んだ。
    public static let opacity: Double = 0.5

    /// 透かしの中心（0...1 の正規化座標、出力枠の左上原点）。
    ///
    /// ラスタ済みビットマップの実寸（`rasterSize`）と出力枠のサイズ（`canvasSize`）から
    /// 右下寄せの中心を逆算する。**プレビューと書き出しが必ずこの関数を通すこと**。
    /// 縮退入力（0 以下・非有限）は nil を返し、呼び出し側は描画をスキップする。
    ///
    /// - Parameters:
    ///   - rasterSize: `TextRasterizer.rasterize` が焼いたビットマップの px サイズ
    ///     （`TextRasterConstants.referenceFontPoints` 基準）。
    ///   - canvasSize: 描画先テクスチャの px サイズ。
    public static func center(rasterSize: CGSize, canvasSize: CGSize) -> CGPoint? {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              rasterSize.width.isFinite, rasterSize.height.isFinite,
              rasterSize.width > 0, rasterSize.height > 0 else { return nil }

        let shortSide = min(canvasSize.width, canvasSize.height)

        // `TextQuadLayout.compute` の baseScale と同じ式（`style(canvasSize:).fontSize`
        // が高さ比、`fontSizeRatio` が短辺比なので、換算すると短辺基準の式に潰れる）。
        // ここで直接同じ結果を出すことで、`style(canvasSize:)` を経由せずに
        // 実際の表示サイズを求められる。
        let scale = (shortSide * CGFloat(fontSizeRatio)) / CGFloat(TextRasterConstants.referenceFontPoints)
        guard scale.isFinite, scale > 0 else { return nil }

        let displayWidth = rasterSize.width * scale
        let displayHeight = rasterSize.height * scale
        guard displayWidth.isFinite, displayHeight.isFinite,
              displayWidth > 0, displayHeight > 0 else { return nil }

        let margin = shortSide * CGFloat(marginRatio)
        let centerX = canvasSize.width - margin - displayWidth / 2
        let centerY = canvasSize.height - margin - displayHeight / 2
        guard centerX.isFinite, centerY.isFinite else { return nil }

        return CGPoint(x: centerX / canvasSize.width, y: centerY / canvasSize.height)
    }

    /// 透かし用の `TextStyle`。既存の `TextStyle` の表現力で作る（新しいスタイル型を足さない）。
    ///
    /// 白文字・黒縁取りで、明暗どちらの映像の上でも読める既存の可読性設計を流用する。
    ///
    /// **縁取りは既定（0.08）より細い 0.04 にすること。** 縁取りの太さは文字サイズに対する
    /// 比なので、透かしのように小さい文字へ既定値を当てると**縁が文字の内側まで食い込んで
    /// 塗り潰し、白文字のはずが黒い塊に見える**（シミュレータで実際にそう見えた）。
    /// 読みやすさが要件なので、輪郭が付く最小限に留める。
    ///
    /// **色の alpha は 1 のまま**にして、
    /// 不透明度は `WatermarkCompositor` が `TextRenderParameters.opacity` として
    /// `opacity` 定数を渡すことで掛ける（`TextItem` のアニメーション不透明度と同じ経路）。
    ///
    /// `fontSize`（`TextStyle` の契約上は出力枠**高さ**比）は、透かしの
    /// `fontSizeRatio`（**短辺**比）を呼び出し時の `canvasSize` で換算して埋める。
    /// これにより向きが変わっても短辺基準の見た目が保たれる。
    public static func style(canvasSize: CGSize) -> TextStyle {
        TextStyle(
            fontSize: heightRatioFontSize(canvasSize: canvasSize),
            fontFamily: .systemBold,
            color: .white,
            strokeWidth: 0.04,
            strokeColor: .black,
            backgroundOpacity: 0,
            backgroundColor: .black
        )
    }

    /// `fontSizeRatio`（短辺比）を `TextStyle.fontSize`（高さ比）へ換算する。
    /// 縮退入力は `TextStyle.defaultFontSize` に倒す（`TextStyle.clamped` と同じ安全側）。
    private static func heightRatioFontSize(canvasSize: CGSize) -> Double {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return TextStyle.defaultFontSize
        }
        let shortSide = min(canvasSize.width, canvasSize.height)
        let ratio = Double(shortSide) * fontSizeRatio / Double(canvasSize.height)
        guard ratio.isFinite else { return TextStyle.defaultFontSize }
        return min(max(ratio, TextStyle.minimumFontSize), TextStyle.maximumFontSize)
    }
}
