import CoreGraphics
import UIKit
import MosaicCore

/// `TextItem` の文字をビットマップへ焼く、フォント解決の唯一の場所（E3-2）。
///
/// `TextFontFamily` を文字列で持たずに列挙で持っているのは「端末に無いフォント名を
/// 保存すると復元時に黙って別書体になる」ためで、実際のフォント解決は
/// **アプリ層のこの 1 箇所に閉じる**（`TextFontFamily` の doc 参照）。`MosaicCore` は
/// UIKit に依存させない。
///
/// 基準フォントサイズは `TextRasterConstants.referenceFontPoints`
/// （`TextQuadLayout` と共有）。**ここでは `TextStyle.fontSize` を使わない**:
/// 常に基準点数で焼き、実際の大きさは `TextQuadLayout` が描画側で縮小/拡大する
/// 頂点変換に任せる。これにより、同じ文字・同じスタイルなら `fontSize` が
/// アニメーションで変化しても再ラスタライズが要らない（設計判断 6）。
enum TextRasterizer {
    private static let referenceFontPoints = CGFloat(TextRasterConstants.referenceFontPoints)

    /// `family` を実際のフォントへ解決する。未対応の組み合わせは system へフォールバックする
    /// （未知の値で `nil` を返して描画自体を諦めない）。
    static func font(for family: TextFontFamily, size: CGFloat) -> UIFont {
        switch family {
        case .system:
            return UIFont.systemFont(ofSize: size)
        case .systemBold:
            return UIFont.boldSystemFont(ofSize: size)
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            if let descriptor = base.fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return base
        case .serif:
            let base = UIFont.systemFont(ofSize: size, weight: .semibold)
            if let descriptor = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return base
        case .monospaced:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }
    }

    /// `text` を `style` の見た目（色・縁取り・背景帯）で 1 枚のビットマップへ描く。
    ///
    /// 呼び出し側（`TextOverlayCache`）が内容・スタイルの変化時だけ呼ぶこと
    /// （毎フレーム呼ぶと CoreText 描画コストがフレームごとにかかる）。
    /// 出力は `MetalTextureUtilities.texture(from:device:)` が期待する
    /// premultiplied-first / little-endian の BGRA。
    static func rasterize(text: String, style: TextStyle) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let clamped = style.clamped
        let font = font(for: clamped.fontFamily, size: referenceFontPoints)
        let strokeWidthPx = clamped.strokeWidth * referenceFontPoints
        let hasBackground = clamped.backgroundOpacity > 0
        // 縁取り・背景帯がはみ出さないよう周囲に余白を取る。
        let padding = max(strokeWidthPx, 2) * 2 + (hasBackground ? referenceFontPoints * 0.25 : 0)

        let color = clamped.color.uiColor
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let textSize = attributed.size()
        guard textSize.width.isFinite, textSize.height.isFinite else { return nil }

        let width = max(1, Int(ceil(textSize.width + padding * 2)))
        let height = max(1, Int(ceil(textSize.height + padding * 2)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // CGContext は左下原点。UIKit の文字列描画は上原点前提なので反転する。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if hasBackground {
            let backgroundColor = clamped.backgroundColor.uiColor
                .withAlphaComponent(CGFloat(clamped.backgroundOpacity) * clamped.backgroundColor.alpha)
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: referenceFontPoints * 0.06)
            backgroundColor.setFill()
            path.fill()
        }

        let textRect = CGRect(
            x: (CGFloat(width) - textSize.width) / 2,
            y: (CGFloat(height) - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        if clamped.strokeWidth > 0 {
            // NSAttributedString の strokeWidth は「フォントサイズに対する百分率」で、
            // 負の値にすると塗り + 縁取りの両方を描く（正だと縁取りだけになる）。
            let percent = -(strokeWidthPx / font.pointSize * 100)
            let strokeAttributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .strokeColor: clamped.strokeColor.uiColor,
                .strokeWidth: percent
            ])
            strokeAttributed.draw(in: textRect)
        } else {
            attributed.draw(in: textRect)
        }

        return context.makeImage()
    }
}

extension RGBAColor {
    /// `MosaicCore` は UIKit に依存しないため、色の実体化はアプリ層のここで行う。
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}
