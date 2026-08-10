import XCTest
import CoreGraphics
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// 写真モードのテキスト焼き込み（写真モード底上げ 第2段）が
/// `PhotoRenderPipeline.render` で実際に画素へ焼き込まれることを直接確かめる。
///
/// **`MosaicEditorModel` / `xcodebuild` を経由しない。** `PhotoRenderPipeline.render` は
/// 「写真の絵を作る唯一の関数」（型 doc 参照）なので、この関数 1 本を直接叩けば
/// UI・下書き・検出のどれも要らず、この作業ツリーで完結できる
/// （`ExportWatermarkBurnInTests` は動画書き出し経路を要するため `AVAssetWriter` を
/// 使うが、写真はその必要が無い）。
///
/// `XCTSkip` は `MTLCreateSystemDefaultDevice()` が nil のときだけ。**「テキストが
/// 見つからない」を skip 条件にしない**（0 件はまさに検出したい退行そのもの）。
final class PhotoTextBurnInTests: XCTestCase {
    private let canvasSize = 400

    /// 単色 `MTLTexture` を作る（透かし焼き込みテストと同じ「均一な下地のほうが
    /// 圧縮ノイズと変化を区別しやすい」考え方。写真はエンコードを経ないので
    /// ノイズは無いが、単色にしておけば差分画素の判定がより厳密になる）。
    private func makeFlatTexture(device: MTLDevice, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> MTLTexture {
        let size = CGSize(width: canvasSize, height: canvasSize)
        let uiImage = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        let cgImage = try XCTUnwrap(uiImage.cgImage)
        return try MetalTextureUtilities.texture(from: cgImage, device: device)
    }

    private func makeRenderer() throws -> MosaicRenderer {
        try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
    }

    /// テクスチャの生 RGBA バイト列。
    private func rawBytes(_ texture: MTLTexture) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(MetalTextureUtilities.cgImage(from: texture))
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// 有意に違う画素（RGB 絶対差の合計が閾値超）の外接矩形を、正規化座標(0...1)の
    /// 中心で返す。差分が無ければ nil。
    private func significantDiffBoundingBoxCenter(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int, threshold: Int = 20
    ) -> (x: Double, y: Double)? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let diff = abs(Int(a[offset]) - Int(b[offset]))
                    + abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                    + abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                if diff > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let centerX = (Double(minX) + Double(maxX)) / 2 / Double(width)
        let centerY = (Double(minY) + Double(maxY)) / 2 / Double(height)
        return (centerX, centerY)
    }

    /// 指定した象限（0...0.5 の正規化範囲）に有意な差分画素が 1 個も無いこと。
    private func hasNoDiff(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
        xRange: Range<Int>, yRange: Range<Int>, threshold: Int = 20
    ) -> Bool {
        for y in yRange where y < height {
            for x in xRange where x < width {
                let offset = (y * width + x) * 4
                let diff = abs(Int(a[offset]) - Int(b[offset]))
                    + abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                    + abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                if diff > threshold { return false }
            }
        }
        return true
    }

    /// テキスト 1 本（`center = (0.75, 0.25)`）で render した出力と `texts = []` の
    /// 出力を差分し、**変化画素の外接矩形の正規化中心が `center` と ±0.05 で一致**、
    /// かつ反対側の象限（左下）は完全一致であることを確かめる。
    ///
    /// 「どこかに1画素置くだけの実装」を通さないため、単なる非ゼロ判定ではなく
    /// 位置まで検証する（`PhotoTextBurnInTests` の素通り対策）。
    func test_photoPipeline_burnsTextOnlyAroundItsCenter() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, red: 0.4, green: 0.4, blue: 0.4)

        var style = TextStyle()
        style.color = .white
        style.strokeWidth = 0
        style.backgroundOpacity = 0
        style.fontSize = 0.2
        let withText = PhotoEditState.identity.addingText(
            "A", center: NormalizedPoint(x: 0.75, y: 0.25), style: style)

        let textured = PhotoRenderPipeline.render(
            source: source, photoEdit: withText, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))
        let plain = PhotoRenderPipeline.render(
            source: source, photoEdit: .identity, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

        let texturedBytes = try rawBytes(textured)
        let plainBytes = try rawBytes(plain)
        let width = textured.width
        let height = textured.height

        guard let center = significantDiffBoundingBoxCenter(
            texturedBytes, plainBytes, width: width, height: height
        ) else {
            XCTFail("テキストを描いたのに差分画素が1つも無い（焼き込みが効いていない）")
            return
        }
        print("[PHOTO TEXT] diffCenter=\(center)")
        XCTAssertEqual(center.x, 0.75, accuracy: 0.05)
        XCTAssertEqual(center.y, 0.25, accuracy: 0.05)

        // 反対側の象限（左下: x < 0.5, y > 0.5）には一切変化が無いこと。
        let bottomLeftClean = hasNoDiff(
            texturedBytes, plainBytes, width: width, height: height,
            xRange: 0..<(width / 2), yRange: (height / 2)..<height)
        XCTAssertTrue(bottomLeftClean, "反対側の象限（左下）まで画素が変わっている")
    }

    /// テキスト 0 本ならゼロコスト（旧経路と1画素も違わない）。
    ///
    /// 「旧経路」は色調補正のみを適用した結果（テキスト・透かしの合成器が存在しない
    /// 頃の `PhotoRenderPipeline.render` と等価）として、`ColorGradeCompositor.apply` を
    /// 直接呼んだ結果と比較する。モザイク・テキスト・透かしをすべて無効にした状態の
    /// `PhotoRenderPipeline.render` が、この「旧経路」の結果とバイト単位で完全一致すること
    /// を確かめる。
    func test_photoPipeline_withoutText_isPixelIdenticalToPreviousStage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, red: 0.6, green: 0.2, blue: 0.8)

        let grade = ColorGrade(brightness: 0.1, contrast: 1.1, saturation: 0.9, warmth: -0.1)

        // 「旧経路」相当: 色調補正だけを直接適用（モザイク・テキスト・透かしは無し）。
        let expected = ColorGradeCompositor.apply(grade: grade, renderer: renderer, input: source)

        let actual = PhotoRenderPipeline.render(
            source: source, photoEdit: PhotoEditState(colorGrade: grade, texts: []),
            renderer: renderer, mosaic: PhotoRenderPipeline.MosaicInput(),
            overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

        let expectedBytes = try rawBytes(expected)
        let actualBytes = try rawBytes(actual)
        XCTAssertEqual(expectedBytes, actualBytes,
            "テキスト0本・透かし無しなのに旧経路（色調補正のみ）とバイト単位で一致しない")
    }
}
#endif
