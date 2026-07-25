import XCTest
import Metal
@testable import MosaicCore

/// **モザイクの粗さが解像度に依らないこと**（プレビューと書き出しの一致）を
/// 出力ピクセルから実測して固定する。
///
/// プレビューは pixelBuffer を `MosaicRenderer.referenceFrameWidth`(=720) 幅へ縮小してから
/// モザイクを掛け、書き出しは原寸のまま掛ける。`block` を「そのテクスチャのピクセル数」
/// として使うと、1080p 素材では書き出しのブロックがプレビューより 1.5 倍細かく、
/// 4K なら 5.3 倍細かくなる（＝**匿名化が弱い方向にずれる**うえ、書き出すまで気づけない）。
///
/// 顔メッシュ経路（`FaceMeshMosaicRenderer`）は固定 256px キャンバス基準へ換算するので
/// 元から解像度非依存。ここではその流儀に揃えた背景モザイク／コンタ（手動矩形）経路の
/// 実効ブロックサイズを測り、**フレーム幅に対する比**が解像度をまたいで一致することを見る。
final class MosaicBlockScaleTests: XCTestCase {
    /// 実測に使うフレーム幅。720 = プレビューの縮小後幅、1440/2160 = 原寸の書き出し相当。
    private let widths = [720, 1440, 2160]
    private let block: Float = 28

    /// 1 解像度ぶんの実測結果（実効ブロック px と、フレーム幅に対する比）。
    private struct Measurement {
        let width: Int
        let measured: Int
        var ratio: Double { Double(measured) / Double(width) }
    }

    // MARK: - 素材と計測

    /// 列ごとに擬似乱数の輝度を持つテクスチャ。列方向にしか変化しないので、
    /// モザイク後の 1 行を走査すればブロック境界が「値が変わる位置」として現れる。
    private func makeColumnNoiseTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("テクスチャを確保できない環境ではスキップ")
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            // 線形合同法（列インデックス→輝度）。隣接ブロックの平均が偶然一致しにくい値。
            let value = UInt8(truncatingIfNeeded: (x &* 1_103_515_245 &+ 12345) >> 7)
            for y in 0..<height {
                let offset = (y * width + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
            }
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// 出力テクスチャの中央行を走査し、値が一定である連なり（＝ブロック）の
    /// **最頻の長さ**を返す。端の欠けたブロックに引きずられないよう最頻値を使う。
    private func measuredBlockWidth(of texture: MTLTexture) -> Int {
        let width = texture.width
        let row = texture.height / 2
        var pixels = [UInt8](repeating: 0, count: width * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, row, width, 1), mipmapLevel: 0)
        }
        var runs: [Int: Int] = [:]
        var runLength = 1
        for x in 1..<width {
            if pixels[x * 4] == pixels[(x - 1) * 4] {
                runLength += 1
            } else {
                runs[runLength, default: 0] += 1
                runLength = 1
            }
        }
        runs[runLength, default: 0] += 1
        return runs.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key ?? 0
    }

    private func makeRenderer() throws -> MosaicRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        do {
            return try MosaicRenderer(device: device, params: MosaicParams(block: block),
                                      evaluator: TrackingEvaluator(smoothing: 1.0))
        } catch MosaicRendererError.libraryUnavailable {
            throw XCTSkip("シェーダーライブラリ未搭載環境ではスキップ（描画は Simulator/実機のみ）")
        }
    }

    // MARK: - 背景モザイク

    /// 背景モザイクの実効ブロックサイズが**フレーム幅に比例**すること
    /// （= 見た目の粗さが解像度に依らない）。
    ///
    /// 修正前は `params.block` をそのままテクスチャのピクセル数として使っていたため、
    /// 720px でも 2160px でも 28px ブロックになり、高解像度ほど相対的に細かくなっていた。
    func test_backgroundMosaicBlockScalesWithResolution() throws {
        let renderer = try makeRenderer()
        var ratios: [Measurement] = []
        for width in widths {
            let height = width * 9 / 16
            let input = try makeColumnNoiseTexture(device: renderer.device,
                                                   width: width, height: height)
            let mask = MaskBuffer(bytes: [UInt8](repeating: 255, count: width * height),
                                  width: width, height: height)
            let output = try XCTUnwrap(
                renderer.renderBackgroundToNewTexture(input: input, mask: mask, block: block),
                "背景モザイクが描画されなかった")
            let measured = measuredBlockWidth(of: output)
            ratios.append(Measurement(width: width, measured: measured))
        }
        for entry in ratios {
            print("[BLOCKSCALE-bg] width=\(entry.width) blockPx=\(entry.measured) "
                  + "ratio=\(String(format: "%.5f", entry.ratio))")
        }
        let base = try XCTUnwrap(ratios.first)
        XCTAssertEqual(base.measured, Int(block), accuracy: 1,
                       "基準幅(720)では従来どおり block そのままのはず（プレビューの見えを変えない）")
        for entry in ratios.dropFirst() {
            XCTAssertEqual(entry.ratio, base.ratio, accuracy: base.ratio * 0.1,
                           "width=\(entry.width) のブロックが幅比で基準(720)と違う"
                           + "（解像度が上がるほどモザイクが細かくなる＝匿名化が弱くなる）")
        }
    }

    // MARK: - 手動矩形（コンタ経路）

    /// 手動矩形（`additionalPaths`）のコンタ経路も同じく解像度非依存であること。
    /// プレビューは 720px 幅、書き出しは原寸で同じ矩形を描くため、ここがずれると
    /// 「プレビューで見た粗さ」と書き出しが食い違う。
    func test_manualRegionMosaicBlockScalesWithResolution() throws {
        let renderer = try makeRenderer()
        var ratios: [Measurement] = []
        for width in widths {
            let height = width * 9 / 16
            let input = try makeColumnNoiseTexture(device: renderer.device,
                                                   width: width, height: height)
            // 画面いっぱいの矩形（計測行が必ずマスク内に入る）。パスはピクセル座標。
            let path = FaceMaskBuilder.RegionPath(
                path: CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height),
                             transform: nil),
                value: 1)
            let result = try XCTUnwrap(
                renderer.renderToNewTexture(input: input, landmarkSets: [],
                                            additionalPaths: [path]),
                "コンタ経路が描画されなかった")
            let measured = measuredBlockWidth(of: result.texture)
            ratios.append(Measurement(width: width, measured: measured))
        }
        for entry in ratios {
            print("[BLOCKSCALE-manual] width=\(entry.width) blockPx=\(entry.measured) "
                  + "ratio=\(String(format: "%.5f", entry.ratio))")
        }
        let base = try XCTUnwrap(ratios.first)
        XCTAssertEqual(base.measured, Int(block), accuracy: 1,
                       "基準幅(720)では従来どおり block そのままのはず（プレビューの見えを変えない）")
        for entry in ratios.dropFirst() {
            XCTAssertEqual(entry.ratio, base.ratio, accuracy: base.ratio * 0.1,
                           "width=\(entry.width) のブロックが幅比で基準(720)と違う")
        }
    }

    /// 換算の純ロジック契約。基準幅以下では**縮めない**（＝小さい素材で
    /// モザイクが今より弱くなることは無い）、基準幅より上では幅に比例して粗くする。
    func test_effectiveBlockNeverShrinksBelowNominal() {
        XCTAssertEqual(MosaicRenderer.effectiveBlock(28, textureWidth: 720), 28, accuracy: 0.001)
        XCTAssertEqual(MosaicRenderer.effectiveBlock(28, textureWidth: 1080), 42, accuracy: 0.001)
        XCTAssertEqual(MosaicRenderer.effectiveBlock(28, textureWidth: 3840),
                       28 * 3840 / 720, accuracy: 0.001)
        // 基準幅未満は据え置き（プレビューも同じ倍率なので両者は一致したまま）。
        XCTAssertEqual(MosaicRenderer.effectiveBlock(28, textureWidth: 320), 28, accuracy: 0.001)
        XCTAssertEqual(MosaicRenderer.effectiveBlock(28, textureWidth: 0), 28, accuracy: 0.001)
    }
}
