import CoreGraphics
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

/// 無料プランの透かしを最後に焼き込む（課金 P2）。
///
/// **`TextItem` として作らないこと。** `TextItem` はタイムラインの編集対象で
/// 下書きにも保存されるため、透かしを混ぜると「透かしがタイムラインの段に出る」
/// 「下書きに入って復元される」事故になる。描画部品（ラスタライズ・配置・Metal 描画）
/// だけを再利用し、データとしては混ぜない。`TextOverlayCompositor` と役割が近く
/// 同じ部品を使うため、新規ファイルを作らずここへ同居させてある。
///
/// **描画順は「モザイク → テキスト → 透かし」固定。** 呼び出し側は
/// `TextOverlayCompositor.apply(...)` の**直後**にここを呼ぶこと（ユーザーのテキストで
/// 透かしを隠せないよう、透かしを一番上に置く）。
enum WatermarkCompositor {
    /// - Parameters:
    ///   - renderer: `TextOverlayCompositor.apply` に渡したのと同じ `MosaicRenderer`。
    ///   - cache: `renderer.device` に紐づいたラスタライズキャッシュ（透かし専用の
    ///     1 スロットを内部に持つ。`TextOverlayCache.watermarkTexture(style:)` 参照）。
    ///   - input: モザイク・テキストを焼き込み終えたテクスチャ。
    /// - Returns: 透かしを重ねたテクスチャ。ラスタライズ・レイアウト計算に失敗したら
    ///   `input` をそのまま返す（透かしが出ないだけで、書き出し自体は失敗させない）。
    static func apply(renderer: MosaicRenderer, cache: TextOverlayCache, input: MTLTexture) -> MTLTexture {
        let canvasSize = CGSize(width: input.width, height: input.height)
        let style = ExportWatermark.style(canvasSize: canvasSize)
        guard let (textTexture, pixelSize) = cache.watermarkTexture(style: style) else { return input }

        let rasterSize = CGSize(width: pixelSize.width, height: pixelSize.height)
        guard let center = ExportWatermark.center(rasterSize: rasterSize, canvasSize: canvasSize) else {
            return input
        }

        guard let layout = TextQuadLayout.compute(
            center: NormalizedPoint(x: Double(center.x), y: Double(center.y)),
            style: style,
            rasterSize: pixelSize,
            canvasSize: (Double(input.width), Double(input.height)),
            // `TextItem` のアニメーションを経由しないので `.identity` に
            // `ExportWatermark.opacity` だけ差し替える（色の alpha は 1 のまま。
            // `ExportWatermark.style(canvasSize:)` の doc 参照）。
            renderParameters: TextRenderParameters(
                opacity: ExportWatermark.opacity, offsetX: 0, offsetY: 0, scale: 1
            )
        ) else { return input }

        return renderer.renderTextToNewTexture(input: input, textTexture: textTexture, layout: layout) ?? input
    }
}
