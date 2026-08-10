import Metal
import MosaicCore

/// ラスタライズ結果（≒フォント解決込みのビットマップ）を再利用するためのキー。
///
/// **`TextStyle.fontSize` を含めない。** `TextRasterizer` は常に
/// `TextRasterConstants.referenceFontPoints` で焼き、実際の大きさは描画側
/// （`TextQuadLayout`）が頂点変換で吸収するため、`fontSize` だけが変わっても
/// 再ラスタライズは要らない（アニメーションで毎フレーム変わる値をキーに含めると
/// キャッシュが機能しなくなる）。
struct TextRasterKey: Hashable {
    let text: String
    let fontFamily: TextFontFamily
    let color: RGBAColor.HashableBox
    let strokeWidth: Double
    let strokeColor: RGBAColor.HashableBox
    let backgroundOpacity: Double
    let backgroundColor: RGBAColor.HashableBox

    init(item: TextItem) {
        let style = item.style.clamped
        text = item.text
        fontFamily = style.fontFamily
        color = RGBAColor.HashableBox(style.color)
        strokeWidth = style.strokeWidth
        strokeColor = RGBAColor.HashableBox(style.strokeColor)
        backgroundOpacity = style.backgroundOpacity
        backgroundColor = RGBAColor.HashableBox(style.backgroundColor)
    }
}

extension RGBAColor {
    /// `RGBAColor` は `MosaicCore` 側で `Hashable` にしていない（描画キャッシュ専用の
    /// 都合をコア層の型へ持ち込まないため）ので、辞書キーに使う分だけここで包む。
    struct HashableBox: Hashable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(_ color: RGBAColor) {
            red = color.red
            green = color.green
            blue = color.blue
            alpha = color.alpha
        }
    }
}

/// テキストのラスタライズ結果を「内容・スタイルが変わったときだけ」作り直すキャッシュ（E3-2）。
///
/// プレビュー（`MosaicPreviewController`）とエクスポート（`VideoMosaicExporter`）は
/// それぞれ自分の Metal デバイス／スレッドで動くため、インスタンスも別々に持つ
/// （テクスチャは特定の `MTLDevice` に紐づく）。
final class TextOverlayCache {
    private struct Entry {
        let texture: MTLTexture
        let pixelSize: (width: Double, height: Double)
    }

    private let device: MTLDevice
    private var entries: [TextRasterKey: Entry] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// `item` を描くためのテクスチャとラスタライズ時の px サイズ。失敗したら nil
    /// （文字が空・CoreText 描画失敗・テクスチャ確保失敗のいずれか。呼び出し側は
    /// そのアイテムの描画を諦めて他のアイテムへ進むこと）。
    func texture(for item: TextItem) -> (texture: MTLTexture, pixelSize: (width: Double, height: Double))? {
        let key = TextRasterKey(item: item)
        if let entry = entries[key] {
            return (entry.texture, entry.pixelSize)
        }
        guard let image = TextRasterizer.rasterize(text: item.text, style: item.style),
              let texture = try? MetalTextureUtilities.texture(from: image, device: device) else {
            return nil
        }
        let entry = Entry(texture: texture, pixelSize: (Double(image.width), Double(image.height)))
        entries[key] = entry
        return (entry.texture, entry.pixelSize)
    }
}
