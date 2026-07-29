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

    /// 出力テクスチャの 1 行を走査し、値が一定である連なり（＝ブロック）の
    /// **最頻の長さ**を返す。端の欠けたブロックに引きずられないよう最頻値を使う。
    ///
    /// - Parameters:
    ///   - row: 走査する行（既定は中央）。
    ///   - xRange: 走査する列の範囲（既定は全幅）。顔メッシュ経路のように
    ///     **モザイクが画面の一部にしか掛からない**場合、素の入力（列ごとに値が変わる
    ///     ＝連なり長 1）が混ざると最頻値が 1 に張り付くため、範囲で絞る。
    ///   - minRun: この長さ未満の連なりを最頻値の集計から外す。同上の理由で、
    ///     モザイク領域の外縁や偶然の同値を弾く。
    private func measuredBlockWidth(
        of texture: MTLTexture, row: Int? = nil, xRange: Range<Int>? = nil, minRun: Int = 1
    ) -> Int {
        let width = texture.width
        let row = row ?? texture.height / 2
        var pixels = [UInt8](repeating: 0, count: width * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, row, width, 1), mipmapLevel: 0)
        }
        let range = xRange ?? 0..<width
        var runs: [Int: Int] = [:]
        var runLength = 1
        for x in (range.lowerBound + 1)..<range.upperBound {
            if pixels[x * 4] == pixels[(x - 1) * 4] {
                runLength += 1
            } else {
                if runLength >= minRun { runs[runLength, default: 0] += 1 }
                runLength = 1
            }
        }
        if runLength >= minRun { runs[runLength, default: 0] += 1 }
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

    // MARK: - 顔メッシュ経路（立体モザイク）

    /// 正面向きの合成フルメッシュ顔を作る。
    ///
    /// `FaceMeshTopology.frontalUV`（正面キャンバス上の正準 UV）をそのまま
    /// `rect`（正規化フレーム座標）へ線形に写した「正面を向いた顔」。warp が恒等の
    /// アフィン写像になるので、キャンバス上のブロックがフレーム上でも軸平行の矩形として
    /// 現れ、走査で長さを測れる。
    private func makeSyntheticFullMesh(in rect: CGRect) -> FaceLandmarkSet {
        let uv = FaceMeshTopology.frontalUV
        var points: [FaceLandmark] = []
        points.reserveCapacity(FaceLandmarkSet.fullMeshCount)
        for index in 0..<FaceMeshTopology.vertexCount {
            let u = CGFloat(uv[index * 2])
            let v = CGFloat(uv[index * 2 + 1])
            points.append(FaceLandmark(x: Float(rect.minX + u * rect.width),
                                       y: Float(rect.minY + v * rect.height)))
        }
        // 虹彩 10 点（468..477）はメッシュ描画に使われないが、`isFullMesh` を
        // 満たしてメッシュ経路へ入るために埋める。
        while points.count < FaceLandmarkSet.fullMeshCount {
            points.append(FaceLandmark(x: Float(rect.midX), y: Float(rect.midY)))
        }
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// **顔メッシュ経路の粗さも解像度に依らないこと。**
    ///
    /// この経路だけは `MosaicRenderer.effectiveBlock` を通らず、
    /// `FaceMeshMosaicRenderer` が固定 256px キャンバス基準へ独自に換算している
    /// (`block * canvasSize / referenceFaceWidth`)。式にテクスチャ幅が出てこないので
    /// 原理的に解像度非依存だが、**フルメッシュ顔はアプリの主経路**（TikTok 風の立体
    /// モザイクはここでしか出ない）なのに、背景・手動矩形と違って出力ピクセルで
    /// 固定されていなかった。ここで実測して固定する。
    ///
    /// 期待値: フレーム上のブロック px = `block * 顔の幅(px) / referenceFaceWidth(380)`。
    /// 顔がフレーム幅の一定割合を占める限り、ブロックはフレーム幅に比例する
    /// ＝ プレビュー(720px)と書き出し(原寸)で見た目の粗さが一致する。
    func test_faceMeshMosaicBlockScalesWithResolution() throws {
        let renderer = try makeRenderer()
        // 顔はフレーム幅の 50%。中央行(v=0.5)が必ず顔の中を通る。
        let faceRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        let face = makeSyntheticFullMesh(in: faceRect)
        var ratios: [Measurement] = []
        for width in widths {
            let height = width * 9 / 16
            let input = try makeColumnNoiseTexture(device: renderer.device,
                                                   width: width, height: height)
            let result = try XCTUnwrap(
                renderer.renderToNewTexture(input: input, landmarks: face),
                "顔メッシュ経路が描画されなかった")
            // 顔の縦中央の行を、顔の横幅の内側 70% だけ走査する（外縁の欠けたブロックと
            // 素通しの入力を避ける）。連なり 3px 未満は集計から外す。
            let row = Int((faceRect.minY + faceRect.height * 0.5) * CGFloat(height))
            let from = Int((faceRect.minX + faceRect.width * 0.15) * CGFloat(width))
            let to = Int((faceRect.minX + faceRect.width * 0.85) * CGFloat(width))
            let measured = measuredBlockWidth(of: result.texture, row: row,
                                              xRange: from..<to, minRun: 3)
            ratios.append(Measurement(width: width, measured: measured))
        }
        for entry in ratios {
            print("[BLOCKSCALE-mesh] width=\(entry.width) blockPx=\(entry.measured) "
                  + "ratio=\(String(format: "%.5f", entry.ratio))")
        }
        let base = try XCTUnwrap(ratios.first)
        XCTAssertGreaterThan(base.measured, 2, "メッシュ経路でブロックが検出できていない")
        // 期待値は block * 顔幅px / 380。720px フレームで顔幅 360px なら 26.5px。
        let expected = Double(block) * (Double(base.width) * faceRect.width) / 380
        XCTAssertEqual(Double(base.measured), expected, accuracy: expected * 0.2,
                       "メッシュ経路の換算（block * 顔幅 / referenceFaceWidth）から外れている")
        for entry in ratios.dropFirst() {
            XCTAssertEqual(entry.ratio, base.ratio, accuracy: base.ratio * 0.1,
                           "width=\(entry.width) のブロックが幅比で基準(720)と違う"
                           + "（プレビューと書き出しで立体モザイクの粗さが食い違う）")
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
