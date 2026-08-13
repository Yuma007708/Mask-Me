import CoreGraphics
import Metal
import MosaicCore
import UIKit
import XCTest
@testable import MaskMe

/// **診断**（合否の門番ではない）: 余白の塗りが実際にどう見えるかを画で出す。
///
/// 数値のテスト（`LetterboxRenderTests`）は「素材の中を触らない」「余白の黒を混ぜない」
/// といった**約束**を守るが、**見た目が意図どおりか**は画を見ないと分からない
/// （ぼかしが強すぎる・弱すぎる、拡大の倍率が不自然、等）。
///
/// 実行すると tmp へ JPEG を書き、パスを print する。速い（書き出しを含まない）ので
/// 除外リストには入れない。
///
/// **ここへ渡す絵はモザイクを焼いていない生の素材である。** 見た目（ぼけ具合・拡大の
/// 倍率）だけを見るための診断なので、そこは意図的にそうしてある。**製品の経路では
/// 必ずモザイクを焼いた後のフレームが入る**（`LetterboxCompositor` の呼び出し位置）。
/// この診断の画を見て「ぼかしに素顔が出る」と読み違えないこと。
final class DiagLetterboxLookTests: XCTestCase {
    func test_Diag_letterboxLook() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        guard let source = FixtureLoader.images(in: "faces").first else {
            throw XCTSkip("Fixtures/faces に画像がありません")
        }

        // 9:16 の枠へ、横長になるよう素材を中央配置した「余白のある絵」を作る。
        let frame = CGSize(width: 540, height: 960)
        let content = AspectFit.placement(of: CGSize(width: source.size.width,
                                                     height: source.size.height),
                                          in: frame)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let composed = UIGraphicsImageRenderer(size: frame, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: frame))
            source.draw(in: CGRect(x: content.minX * frame.width, y: content.minY * frame.height,
                                   width: content.width * frame.width,
                                   height: content.height * frame.height))
        }

        for (name, background) in [
            ("color", TimelineBackground(kind: .color,
                                         color: RGBAColor(red: 0.2, green: 0.5, blue: 0.9))),
            ("blur-weak", TimelineBackground(kind: .blur, blurStrength: 0.25)),
            ("blur-strong", TimelineBackground(kind: .blur, blurStrength: 1.0))
        ] {
            guard let input = try? texture(from: composed, device: device),
                  let output = MetalTextureUtilities.makeOutputTexture(like: input, device: device)
            else { continue }
            renderer.renderLetterbox(input: input, into: output, contentRect: content,
                                     background: background, waitForCompletion: true)
            guard let cgImage = MetalTextureUtilities.cgImage(from: output),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
            else { continue }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("letterbox-\(name).jpg")
            try? data.write(to: url)
            print("[DIAG-LETTERBOX] \(name) dumped \(url.path)")
        }
    }

    private func texture(from image: UIImage, device: MTLDevice) throws -> MTLTexture {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }
}
