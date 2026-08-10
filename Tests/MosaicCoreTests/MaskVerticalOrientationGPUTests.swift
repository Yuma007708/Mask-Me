import XCTest
import Metal
import CoreGraphics
@testable import MosaicCore

/// GPU を通した実測で「手動矩形」と「フルメッシュ顔」がそれぞれ画像のどの行に
/// 焼かれるかを確定させる調査用テスト。
///
/// 入力は行ごとに値が変わる縞（ノイズ）にしてあり、モザイクが掛かった行だけ
/// 入力と値が変わる。差分の出た行の範囲でモザイク位置を特定する。
final class MaskVerticalOrientationGPUTests: XCTestCase {

    private func makeRenderer() throws -> MosaicRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        do {
            return try MosaicRenderer(device: device, params: MosaicParams(block: 16),
                                      evaluator: TrackingEvaluator(smoothing: 1.0))
        } catch MosaicRendererError.libraryUnavailable {
            throw XCTSkip("シェーダーライブラリ未搭載環境ではスキップ")
        }
    }

    /// 行ごと・列ごとに擬似乱数の輝度を持つテクスチャ（どの方向のモザイクも検出できる）。
    private func makeNoiseTexture(device: MTLDevice, width: Int, height: Int) throws -> (MTLTexture, [UInt8]) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("テクスチャを確保できない環境ではスキップ")
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(truncatingIfNeeded: ((x &* 7919) &+ (y &* 104_729)) &* 2_654_435_761 >> 13)
                let offset = (y * width + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value &+ 40
                bytes[offset + 2] = value &+ 80
            }
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return (texture, bytes)
    }

    private func readBytes(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        raw.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return raw
    }

    /// 差分のある行/列の範囲。
    private func changedBounds(_ lhs: [UInt8], _ rhs: [UInt8], width: Int, height: Int)
    -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        var minRow = Int.max, maxRow = Int.min, minCol = Int.max, maxCol = Int.min
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if lhs[offset] != rhs[offset] || lhs[offset + 1] != rhs[offset + 1] {
                    minRow = min(minRow, y); maxRow = max(maxRow, y)
                    minCol = min(minCol, x); maxCol = max(maxCol, x)
                }
            }
        }
        guard minRow <= maxRow else { return nil }
        return (minRow...maxRow, minCol...maxCol)
    }

    // MARK: - 手動矩形（additionalPaths → コンタマスク経路）

    func test_manualRect_burnsIntoTopRows() throws {
        let renderer = try makeRenderer()
        let size = 400
        let (input, inputBytes) = try makeNoiseTexture(device: renderer.device, width: size, height: size)
        let path = FaceMaskBuilder.rectPath(
            from: CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2), angle: 0,
            in: CGSize(width: size, height: size))
        let result = try XCTUnwrap(renderer.renderToNewTexture(
            input: input, landmarkSets: [],
            additionalPaths: [.init(path: path, value: 1.0)]))
        let out = readBytes(result.texture)
        let bounds = try XCTUnwrap(changedBounds(inputBytes, out, width: size, height: size))
        print("MEASURED manualRect GPU rows=\(bounds.rows) cols=\(bounds.cols)")
        // 実測: rows=300...379（期待 20...99）。コンタマスク経路が上下反転している。
        // 修正済み（`FaceMaskBuilder.flipToTopDown`）。ここが落ちたら反転が再発している。
        do {
            XCTAssertLessThan(bounds.rows.lowerBound, 200,
                              "y=0.05 の矩形は画像上部（行<200）に焼かれるべき")
        }
    }

    // MARK: - フルメッシュ顔（FaceMeshMosaicRenderer 経路）

    func test_fullMeshFace_burnsIntoTopRows() throws {
        let renderer = try makeRenderer()
        let size = 400
        let (input, inputBytes) = try makeNoiseTexture(device: renderer.device, width: size, height: size)
        // 478 点を y=0.05..0.25、x=0.35..0.65 の楕円上に配置（＝画像上部の顔）。
        var points: [FaceLandmark] = []
        for i in 0..<FaceLandmarkSet.fullMeshCount {
            let theta = Double(i) / Double(FaceLandmarkSet.fullMeshCount) * 2 * Double.pi
            let radius = 0.4 + 0.6 * Double((i % 7)) / 6.0
            points.append(FaceLandmark(
                x: Float(0.5 + 0.15 * radius * cos(theta)),
                y: Float(0.15 + 0.10 * radius * sin(theta))))
        }
        let face = FaceLandmarkSet(points: points, confidence: 0.95)
        let result = try XCTUnwrap(renderer.renderToNewTexture(input: input, landmarkSets: [face]))
        let out = readBytes(result.texture)
        let bounds = try XCTUnwrap(changedBounds(inputBytes, out, width: size, height: size))
        print("MEASURED fullMeshFace GPU rows=\(bounds.rows) cols=\(bounds.cols)")
        XCTAssertLessThan(bounds.rows.lowerBound, 200,
                          "y=0.05..0.25 の顔は画像上部（行<200）に焼かれるべき")
    }

    // MARK: - 部分メッシュ顔（コンタマスク経路）

    func test_partialMeshFace_burnsIntoTopRows() throws {
        let renderer = try makeRenderer()
        let size = 400
        let (input, inputBytes) = try makeNoiseTexture(device: renderer.device, width: size, height: size)
        var points = [FaceLandmark](repeating: FaceLandmark(x: 0, y: 0), count: 500)
        let ovalIndices = FaceRegion.faceOval.indices
        for (i, index) in ovalIndices.enumerated() {
            let theta = Double(i) / Double(ovalIndices.count) * 2 * Double.pi
            points[index] = FaceLandmark(x: Float(0.5 + 0.12 * cos(theta)),
                                         y: Float(0.15 + 0.08 * sin(theta)))
        }
        let face = FaceLandmarkSet(points: points, confidence: 0.95)
        let result = try XCTUnwrap(renderer.renderToNewTexture(
            input: input, landmarkSets: [face],
            faceOptions: [MosaicRenderer.FaceRenderOption(forceConvexHull: true)]))
        let out = readBytes(result.texture)
        let bounds = try XCTUnwrap(changedBounds(inputBytes, out, width: size, height: size))
        print("MEASURED partialMeshFace GPU rows=\(bounds.rows) cols=\(bounds.cols)")
        // 実測: rows=304...375（期待 ~28...92）。手動矩形と同じ経路なので同じく反転する。
        // 修正済み（`FaceMaskBuilder.flipToTopDown`）。ここが落ちたら反転が再発している。
        do {
            XCTAssertLessThan(bounds.rows.lowerBound, 200,
                              "y=0.07..0.23 の部分メッシュ顔は画像上部（行<200）に焼かれるべき")
        }
    }
}

/// `MetalTextureUtilities.texture(from:)` / `cgImage(from:)` が上下反転を掛けるか、
/// CGImage の「上」がテクスチャの行 0 かどうかを実測で確定させる。
final class TextureRoundTripOrientationTests: XCTestCase {
    /// 上半分 255・下半分 0 の 8x8 グレー CGImage（CGImage の行 0 は上）。
    private func makeTopWhiteImage(size: Int) throws -> CGImage {
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        for row in 0..<size {
            let value: UInt8 = row < size / 2 ? 255 : 0
            for col in 0..<size {
                let offset = row * bytesPerRow + col * 4
                bytes[offset] = value; bytes[offset + 1] = value
                bytes[offset + 2] = value; bytes[offset + 3] = 255
            }
        }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let context = try XCTUnwrap(CGContext(data: &bytes, width: size, height: size,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        return try XCTUnwrap(context.makeImage())
    }

    func test_cgImageTopMapsToTextureRowZero() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal なし") }
        let size = 8
        let image = try makeTopWhiteImage(size: size)
        let texture = try MetalTextureUtilities.texture(from: image, device: device)
        var raw = [UInt8](repeating: 0, count: size * size * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        print("MEASURED texture row0=\(raw[0]) rowLast=\(raw[(size - 1) * size * 4])")
        XCTAssertEqual(raw[0], 255, "CGImage の上（白）はテクスチャ行 0 に来るべき")
        XCTAssertEqual(raw[(size - 1) * size * 4], 0, "CGImage の下（黒）はテクスチャ最終行")

        // 戻り: cgImage(from:) も行 0 を上に戻すか。
        let back = try XCTUnwrap(MetalTextureUtilities.cgImage(from: texture))
        var outBytes = [UInt8](repeating: 0, count: size * size * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let outContext = try XCTUnwrap(CGContext(data: &outBytes, width: size, height: size,
                                                 bitsPerComponent: 8, bytesPerRow: size * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        outContext.draw(back, in: CGRect(x: 0, y: 0, width: size, height: size))
        print("MEASURED roundtrip row0=\(outBytes[0]) rowLast=\(outBytes[(size - 1) * size * 4])")
        XCTAssertEqual(outBytes[0], 255, "往復しても上は白のまま（反転していない）")
    }
}

/// `RealFaceMosaicTests` が使っている指標（顔矩形内の total variation が
/// 区間外より十分低い）が、上下反転を**実際に検出できる**かを確かめる。
/// 反転した矩形で測ると平坦にならない＝指標は反転に敏感、を示す。
final class RealFaceMetricFlipSensitivityTests: XCTestCase {
    private func totalVariation(_ plane: [UInt8], width: Int, rect: CGRect, height: Int) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(width))), x1 = min(width, Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height))), y1 = min(height, Int(rect.maxY * CGFloat(height)))
        guard x1 > x0 + 1, y1 > y0 else { return .nan }
        var sum = 0.0, count = 0
        for y in y0..<y1 {
            for x in (x0 + 1)..<x1 {
                sum += abs(Double(plane[y * width + x]) - Double(plane[y * width + x - 1]))
                count += 1
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    func test_totalVariationMetricDetectsVerticalFlip() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal なし") }
        let renderer: MosaicRenderer
        do {
            renderer = try MosaicRenderer(device: device, params: MosaicParams(block: 16),
                                          evaluator: TrackingEvaluator(smoothing: 1.0))
        } catch MosaicRendererError.libraryUnavailable { throw XCTSkip("シェーダー無し") }

        let size = 400
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                // 4px 市松（高周波）。全面一様なので素材の向きでは説明できない。
                let value: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 20 : 235
                let offset = (y * size + x) * 4
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value
            }
        }
        bytes.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        // 上寄り（y=0.05..0.25）のフルメッシュ顔。
        var points: [FaceLandmark] = []
        for i in 0..<FaceLandmarkSet.fullMeshCount {
            let theta = Double(i) / Double(FaceLandmarkSet.fullMeshCount) * 2 * Double.pi
            let radius = 0.4 + 0.6 * Double(i % 7) / 6.0
            points.append(FaceLandmark(x: Float(0.5 + 0.15 * radius * cos(theta)),
                                       y: Float(0.15 + 0.10 * radius * sin(theta))))
        }
        let face = FaceLandmarkSet(points: points, confidence: 0.95)
        let result = try XCTUnwrap(renderer.renderToNewTexture(input: input, landmarkSets: [face]))
        var out = [UInt8](repeating: 0, count: size * size * 4)
        out.withUnsafeMutableBytes {
            result.texture.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                                    from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        var plane = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) { plane[i] = out[i * 4] }

        // RealFaceMosaicTests と同じ「顔の中心 60%」。
        let rect = CGRect(x: 0.5 - 0.15, y: 0.15 - 0.10, width: 0.30, height: 0.20)
        let core = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
        let flipped = CGRect(x: core.minX, y: 1 - core.maxY, width: core.width, height: core.height)
        let tvCore = totalVariation(plane, width: size, rect: core, height: size)
        let tvFlipped = totalVariation(plane, width: size, rect: flipped, height: size)
        print("MEASURED TV core(y-down)=\(tvCore) TV flipped=\(tvFlipped)")
        XCTAssertLessThan(tvCore, tvFlipped * 0.6,
                          "y-down 矩形の中だけ平坦＝指標は上下反転を検出できる")
    }
}
