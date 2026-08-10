import Metal
import MosaicCore

/// テキストをモザイクの上に焼き込む、プレビュー・書き出し共通の合成手順（E3-2）。
///
/// **描画順は「モザイク → テキスト」固定。** 呼び出し側は `input` にモザイク
/// （＋背景モザイク）を焼き込み終えたテクスチャを渡すこと。逆順にすると
/// 顔に被った文字がモザイクで潰れる。
///
/// 「どれが出ているか」「どう変形するか」の判断はここでは行わない
/// （`TextItem.renderParameters(atComposition:)` を呼ぶだけ）。呼び出し側は
/// `items` に `TimelineState.visibleTextItems(atComposition:totalDuration:)`
/// （または同じ拡張の配列版）の戻り値をそのまま渡すこと。
enum TextOverlayCompositor {
    /// - Parameters:
    ///   - items: 描く順（`compositionStart` 昇順）に並んだ、表示中のテキスト。
    ///   - compositionTime: `items` を得たのと同じ合成時刻。
    ///   - renderer: モザイクの焼き込みに使ったのと同じ `MosaicRenderer`
    ///     （同じ Metal デバイス／コマンドキューを共有する）。
    ///   - cache: `renderer.device` に紐づいたラスタライズキャッシュ。
    ///   - input: モザイク（＋背景モザイク）焼き込み済みのテクスチャ。
    /// - Returns: 全テキストを重ね終えたテクスチャ。描く対象が無ければ `input` をそのまま返す。
    static func apply(
        items: [TextItem],
        at compositionTime: Double,
        renderer: MosaicRenderer,
        cache: TextOverlayCache,
        input: MTLTexture
    ) -> MTLTexture {
        var current = input
        for item in items {
            guard let params = item.renderParameters(atComposition: compositionTime),
                  params.opacity > 0.001 else { continue }
            guard let (textTexture, pixelSize) = cache.texture(for: item) else { continue }
            guard let layout = TextQuadLayout.compute(
                center: item.center,
                style: item.style,
                rasterSize: pixelSize,
                canvasSize: (Double(current.width), Double(current.height)),
                renderParameters: params
            ) else { continue }
            if let next = renderer.renderTextToNewTexture(
                input: current, textTexture: textTexture, layout: layout
            ) {
                current = next
            }
        }
        return current
    }
}
