import CoreGraphics
import Metal
import MosaicCore

/// レターボックス（余白）を塗る、プレビュー・書き出し共通の合成手順（S13）。
///
/// ## 呼ぶ位置は「モザイクの後・テキストの前」で固定
///
/// - **モザイクの後**でなければならない。ぼかしは渡されたテクスチャを読んで作るので、
///   焼く前を渡すと素顔が余白へ拡大されて出る。ぼかしは隠す手段ではない
///   （`TimelineBackground` の型 doc に理由の全文がある）。
/// - **テキストの前**でなければならない。文字・ステッカーは出力枠基準で置かれ、
///   余白の上にも置ける。後に塗ると余白に置いた文字が塗り潰される。
///
/// ## 何もしない条件をここで判定する
///
/// 「余白が無い」「黒（＝合成の既定の背景色そのまま）」のときは `input` をそのまま返し、
/// **1 パスも発行しない**。無変換タイムラインの忠実度を、見た目が変わらない塗りで
/// 崩さないため（`VideoCompositionPlan` が黒のときに装着を強制しないのと同じ考え方）。
enum LetterboxCompositor {
    /// - Parameters:
    ///   - background: 余白の埋め方（`TimelineState.background`）。
    ///   - contentRect: 素材が置かれている範囲（合成フレーム基準・正規化）。
    ///     `TimelineRenderLayout.contentBounds` を渡すこと。**この中は 1 ピクセルも
    ///     変えない**ので、モザイクを塗り潰して顔を出す形の事故は起きない。
    ///   - renderer: モザイクの焼き込みに使ったのと同じ `MosaicRenderer`。
    ///   - input: モザイク（＋背景モザイク）焼き込み済みのテクスチャ。
    /// - Returns: 余白を塗り終えたテクスチャ。塗るものが無ければ `input` をそのまま返す。
    static func apply(
        background: TimelineBackground,
        contentRect: CGRect,
        renderer: MosaicRenderer,
        input: MTLTexture
    ) -> MTLTexture {
        guard shouldFill(background: background, contentRect: contentRect) else { return input }
        guard let output = MetalTextureUtilities.makeOutputTexture(like: input,
                                                                   device: renderer.device) else {
            // テクスチャを作れないときは塗らずに素通しする。**余白の見た目のために
            // 書き出しを止めない**（欠けても編集内容は失われない値、という
            // `TimelineBackground` の永続化の扱いと同じ判断）。
            return input
        }
        renderer.renderLetterbox(input: input, into: output,
                                 contentRect: contentRect, background: background,
                                 waitForCompletion: true)
        return output
    }

    /// 塗る必要があるか。**判定をここ 1 箇所に置く**ので、プレビューと書き出しで
    /// 「片方だけ塗る」食い違いが作れない。
    static func shouldFill(background: TimelineBackground, contentRect: CGRect) -> Bool {
        guard background.kind != .black else { return false }
        let epsilon: CGFloat = 0.001
        return contentRect.minX > epsilon || contentRect.minY > epsilon
            || contentRect.maxX < 1 - epsilon || contentRect.maxY < 1 - epsilon
    }
}
