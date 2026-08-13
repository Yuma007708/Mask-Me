import AVFoundation
import Metal
import MosaicCore
import XCTest
@testable import MaskMe

/// レターボックス（余白）の**描画結果**を実ピクセルで固定する。
///
/// `LetterboxBackgroundWiringTests` が見ているのは「合成の背景色に値が届くか」まで。
/// こちらは **Metal のカーネルが実際に何を書いたか**を読む。
///
/// ここで守るのは 3 つ:
/// 1. 余白が指定の色／ぼかしで埋まる（＝黒帯のままにならない）
/// 2. **素材の範囲は 1 ピクセルも変わらない**（モザイクを塗り潰して顔を出さない）
/// 3. 黒のときは 1 パスも発行しない（無変換の忠実度を落とさない）
final class LetterboxRenderTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MosaicRenderer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        self.device = device
        self.renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
    }

    override func tearDownWithError() throws {
        renderer = nil
        device = nil
        try super.tearDownWithError()
    }

    /// 上下に余白がある絵を作る（中央 1/2 だけが素材、上下 1/4 ずつが余白）。
    private let contentRect = CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
    private let size = (width: 64, height: 64)

    private func makeTexture(fillingContentWith value: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // 素材の範囲だけ `value`、余白は黒（＝合成が置く既定の色）。
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let y0 = Int(contentRect.minY * CGFloat(size.height))
        let y1 = Int(contentRect.maxY * CGFloat(size.height))
        for y in y0..<y1 {
            for x in 0..<size.width {
                let offset = (y * size.width + x) * 4
                pixels[offset] = value       // B
                pixels[offset + 1] = value   // G
                pixels[offset + 2] = value   // R
                pixels[offset + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size.width, size.height),
                        mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: size.width * 4)
        return texture
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        texture.getBytes(&pixels, bytesPerRow: size.width * 4,
                         from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        return pixels
    }

    /// (x, y) の BGRA。
    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let offset = (y * size.width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    private func makeOutput() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    // MARK: - 色

    func test_余白が指定の色で埋まる() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let output = try makeOutput()
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        renderer.renderLetterbox(input: input, into: output, contentRect: contentRect,
                                 background: TimelineBackground(kind: .color, color: red),
                                 waitForCompletion: true)
        let pixels = read(output)
        // 上端（余白）は赤。
        let top = pixel(pixels, 32, 2)
        XCTAssertGreaterThan(top.r, 200, "余白が赤で塗られていない（R=\(top.r)）")
        XCTAssertLessThan(top.g, 40)
        XCTAssertLessThan(top.b, 40)
        // 下端（余白）も赤。
        XCTAssertGreaterThan(pixel(pixels, 32, size.height - 3).r, 200)
    }

    /// **素材の範囲は 1 ピクセルも変えない。** ここが崩れると、モザイクを塗り潰して
    /// 顔を出す形の事故になる（この案件で最も重い壊れ方）。
    func test_素材の範囲は変わらない() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let output = try makeOutput()
        renderer.renderLetterbox(input: input, into: output, contentRect: contentRect,
                                 background: TimelineBackground(kind: .color,
                                                                color: RGBAColor(red: 1, green: 0, blue: 0)),
                                 waitForCompletion: true)
        let pixels = read(output)
        for y in stride(from: 18, to: 46, by: 4) {
            for x in stride(from: 2, to: size.width, by: 8) {
                let sample = pixel(pixels, x, y)
                XCTAssertEqual(sample.r, 200, "素材の中が塗り替えられた (x:\(x) y:\(y))")
                XCTAssertEqual(sample.g, 200)
                XCTAssertEqual(sample.b, 200)
            }
        }
    }

    // MARK: - ぼかし

    /// ぼかしは素材の絵を種にするので、**余白が黒でなくなる**こと。
    /// 種が明るい素材なら余白も明るくなる。
    func test_ぼかしは素材の絵を種にするので余白が黒でなくなる() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let output = try makeOutput()
        renderer.renderLetterbox(input: input, into: output, contentRect: contentRect,
                                 background: TimelineBackground(kind: .blur, blurStrength: 0.6),
                                 waitForCompletion: true)
        let pixels = read(output)
        let top = pixel(pixels, 32, 2)
        XCTAssertGreaterThan(top.r, 150,
                             "ぼかしの余白が黒のまま（素材を種にできていない。R=\(top.r)）")
    }

    /// **ぼかしが余白そのものを読んでいないこと。** サンプル位置を素材の範囲へ
    /// クランプしていないと、黒い余白を平均に混ぜて縁が暗くなる。
    func test_ぼかしは余白を読まない() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let output = try makeOutput()
        renderer.renderLetterbox(input: input, into: output, contentRect: contentRect,
                                 background: TimelineBackground(kind: .blur, blurStrength: 1.0),
                                 waitForCompletion: true)
        let pixels = read(output)
        // 素材は一様な 200 なので、正しくクランプしていれば余白も 200 付近になる。
        // 黒を混ぜていれば目に見えて暗くなる。
        let top = pixel(pixels, 32, 1)
        XCTAssertGreaterThan(top.r, 180,
                             "余白の黒を平均に混ぜている（縁が暗くなる。R=\(top.r)）")
    }

    // MARK: - 何もしない条件

    func test_黒のときは合成手順が入力をそのまま返す() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let result = LetterboxCompositor.apply(background: .default, contentRect: contentRect,
                                               renderer: renderer, input: input)
        XCTAssertTrue(result === input, "黒なのに 1 パス発行している")
    }

    func test_余白が無いときは入力をそのまま返す() throws {
        let input = try makeTexture(fillingContentWith: 200)
        let result = LetterboxCompositor.apply(
            background: TimelineBackground(kind: .blur),
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            renderer: renderer, input: input)
        XCTAssertTrue(result === input, "余白が無いのに 1 パス発行している")
    }
}
