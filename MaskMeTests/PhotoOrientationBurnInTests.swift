import XCTest
import CoreGraphics
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// 写真の回転（写真モード底上げ 第5段）が `PhotoRenderPipeline.render` で実際に
/// 画素へ焼き込まれることを直接確かめる。
///
/// **この作業ツリーでは実行できない**（`MaskMeTests/` は `xcodebuild` 経由でのみ動く。
/// `CLAUDE.md` の作業ツリー制約参照）。`PhotoTextBurnInTests` / `PhotoWatermarkBurnInTests`
/// と同じ理由で `PhotoRenderPipeline.render` を直接叩く（`MosaicEditorModel` /
/// `xcodebuild` を経由しない）。
final class PhotoOrientationBurnInTests: XCTestCase {
    private let canvasSize = 400

    private func makeRenderer() throws -> MosaicRenderer {
        try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
    }

    private func makeFlatTexture(device: MTLDevice, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> MTLTexture {
        let size = CGSize(width: canvasSize, height: canvasSize)
        let uiImage = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        let cgImage = try XCTUnwrap(uiImage.cgImage)
        return try MetalTextureUtilities.texture(from: cgImage, device: device)
    }

    /// 高周波の市松模様（4px 角）。モザイクを掛けるとブロック内が平均化されて中間色に
    /// なるので、「その場所が実際にモザイクされたか」が確実に検出できる。
    ///
    /// **滑らかなグラデーションでは検出できない。** 400px 幅の線形グラデーションは
    /// 1px あたり 255/400 ≒ 0.64 しか変化せず、ブロック平均との差は最大でも
    /// ブロック半径 ×0.64 程度（2 チャンネル合計でも 20 弱）にしかならないため、
    /// `significantDiffCount` の閾値 20 を超えず、**モザイクが正しく効いていても
    /// 差分 0 と判定される**（親の実機検証で実際にこれを踏んだ）。
    private func makeGradientTexture(device: MTLDevice) throws -> MTLTexture {
        let width = canvasSize
        let height = canvasSize
        let cell = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isLight = ((x / cell) + (y / cell)) % 2 == 0
                let value: UInt8 = isLight ? 255 : 0
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            throw XCTSkip("グラデーションテクスチャの生成に失敗した")
        }
        return try MetalTextureUtilities.texture(from: cgImage, device: device)
    }

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

    private func significantDiffCount(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
        xRange: Range<Int>, yRange: Range<Int>, threshold: Int = 20
    ) -> Int {
        var count = 0
        for y in yRange where y >= 0 && y < height {
            for x in xRange where x >= 0 && x < width {
                let offset = (y * width + x) * 4
                let diff = abs(Int(a[offset]) - Int(b[offset]))
                    + abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                    + abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                if diff > threshold { count += 1 }
            }
        }
        return count
    }

    private func layout(orientation: ClipOrientation) -> TimelineRenderLayout {
        TimelineRenderLayout(placements: [:], stillPlacement: TimelineRenderLayout.unitRect,
                             stillOrientation: orientation)
    }

    private let allOrientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
        [ClipOrientation(rotation: rotation, isMirrored: false),
         ClipOrientation(rotation: rotation, isMirrored: true)]
    }

    // MARK: - 出力サイズ

    func test_rotatedOutputSwapsDimensionsFor90And270() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        // 縦横比を変えて確かめる（正方形だと入れ替えが見た目上わからない）。
        //
        // **`UIGraphicsImageRendererFormat.scale = 1` を明示すること。** 既定は画面
        // スケール（実機・Simulator では 3）なので、`CGSize(300, 200)` で描いても
        // 実際の `cgImage` は 900×600 になり、期待値が 3 倍ずれる（親の実機検証で踏んだ）。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let uiImage = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { _ in
            UIColor.gray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let cgImage = try XCTUnwrap(uiImage.cgImage)
        XCTAssertEqual(cgImage.width, 300, "テクスチャの実寸が想定と違う（scale の指定漏れ）")
        let source = try MetalTextureUtilities.texture(from: cgImage, device: renderer.device)

        for rotation: ClipRotation in [.none, .right90, .half, .left90] {
            let orientation = ClipOrientation(rotation: rotation)
            let output = PhotoRenderPipeline.render(
                source: source, photoEdit: PhotoEditState(orientation: orientation), renderer: renderer,
                layout: layout(orientation: orientation), mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))
            if rotation.swapsDimensions {
                XCTAssertEqual(output.width, 200, "rotation=\(rotation)")
                XCTAssertEqual(output.height, 300, "rotation=\(rotation)")
            } else {
                XCTAssertEqual(output.width, 300, "rotation=\(rotation)")
                XCTAssertEqual(output.height, 200, "rotation=\(rotation)")
            }
        }
    }

    // MARK: - 画素の厳密一致（CPU 参照回転との突き合わせ）

    /// モザイク・色調補正・テキスト無しで回転だけ掛け、`ClipOrientation.map` から作った
    /// CPU 参照回転と**全画素一致**すること（補間なしなので厳密一致を要求できる）。全 8 向き。
    func test_rotationOnlyOutputMatchesCPUReferenceRotation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeGradientTexture(device: renderer.device)
        let sourceBytes = try rawBytes(source)
        let width = canvasSize
        let height = canvasSize

        for orientation in allOrientations {
            let output = PhotoRenderPipeline.render(
                source: source, photoEdit: PhotoEditState(orientation: orientation), renderer: renderer,
                layout: layout(orientation: orientation), mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))
            let outputBytes = try rawBytes(output)
            let outWidth = output.width
            let outHeight = output.height

            var mismatches = 0
            for outY in 0..<outHeight {
                for outX in 0..<outWidth {
                    // CPU 参照: 出力ピクセル中心の正規化座標を `inverseMap` で入力側へ戻す
                    // （`MaskBufferOrientation.oriented` と同じ手口。Metal カーネルの整数
                    // 実装とは別経路で同じ写像を計算するので、独立した突き合わせになる）。
                    let normalized = CGPoint(x: (CGFloat(outX) + 0.5) / CGFloat(outWidth),
                                             y: (CGFloat(outY) + 0.5) / CGFloat(outHeight))
                    let sourceNormalized = orientation.inverseMap(normalized)
                    let srcX = min(max(Int(sourceNormalized.x * CGFloat(width)), 0), width - 1)
                    let srcY = min(max(Int(sourceNormalized.y * CGFloat(height)), 0), height - 1)
                    let srcOffset = (srcY * width + srcX) * 4
                    let outOffset = (outY * outWidth + outX) * 4
                    if sourceBytes[srcOffset] != outputBytes[outOffset]
                        || sourceBytes[srcOffset + 1] != outputBytes[outOffset + 1]
                        || sourceBytes[srcOffset + 2] != outputBytes[outOffset + 2] {
                        mismatches += 1
                    }
                }
            }
            XCTAssertEqual(mismatches, 0,
                "orientation=\(orientation) で CPU 参照回転と一致しない画素が \(mismatches) 個ある")
        }
    }

    // MARK: - 位置（`remap(..., clipID: nil)` の取り違えを落とすためのテスト）

    /// 素材の `rect=(0.05,0.05,0.2,0.2)` にモザイク矩形を置き、`right90` で描画する。
    /// **回転後の期待位置（`layout.remapStill(rect)`）がぼけていること**と、
    /// **回転前の位置（写像を掛けなかった場合の rect そのまま）がぼけていないこと**の
    /// **両方**を assert する（片側だけだと全面モザイクの実装が通ってしまう）。
    ///
    /// これは `remap(..., clipID: nil)` と書いた実装（`clipID: nil` を「クリップ未登録
    /// ＝単位矩形・無変換」として扱ってしまい、静止画の向きを無視する——回転が黙って
    /// 効かなくなる）を落とすためのテスト（`ObjectMaskResolver.placements` の
    /// `clipID == nil` 分岐の doc 参照）。
    func test_rotatedPhoto_mosaicsTheRotatedLocationAndNotTheOriginalOne() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeGradientTexture(device: renderer.device)

        let orientation = ClipOrientation(rotation: .right90)
        let currentLayout = layout(orientation: orientation)
        let sourceRect = CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2)
        // 正しい実装が焼き込む先: `layout.remapStill` で写した回転後フレーム基準の矩形。
        let mappedRect = currentLayout.remapStill(sourceRect)
        let outputSize = orientation.displaySize(CGSize(width: canvasSize, height: canvasSize))
        let path = FaceMaskBuilder.rectPath(from: mappedRect, angle: 0, in: outputSize)

        let photoEdit = PhotoEditState(orientation: orientation)
        let mosaicOn = PhotoRenderPipeline.render(
            source: source, photoEdit: photoEdit, renderer: renderer, layout: currentLayout,
            mosaic: PhotoRenderPipeline.MosaicInput(additionalPaths: [.init(path: path, value: 1.0)]),
            overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))
        let mosaicOff = PhotoRenderPipeline.render(
            source: source, photoEdit: photoEdit, renderer: renderer, layout: currentLayout,
            mosaic: PhotoRenderPipeline.MosaicInput(),
            overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

        let onBytes = try rawBytes(mosaicOn)
        let offBytes = try rawBytes(mosaicOff)
        let width = mosaicOn.width
        let height = mosaicOn.height

        // 回転後の期待位置（`mappedRect`）はぼけている（差分あり）。
        let mappedPixelRect = CGRect(x: mappedRect.minX * CGFloat(width), y: mappedRect.minY * CGFloat(height),
                                     width: mappedRect.width * CGFloat(width), height: mappedRect.height * CGFloat(height))
        let mappedDiff = significantDiffCount(
            onBytes, offBytes, width: width, height: height,
            xRange: Int(mappedPixelRect.minX)..<Int(mappedPixelRect.maxX),
            yRange: Int(mappedPixelRect.minY)..<Int(mappedPixelRect.maxY))
        XCTAssertGreaterThan(mappedDiff, 0, "回転後の期待位置（\(mappedRect)）に差分が無い（モザイクが効いていない）")

        // 回転前の位置（写像しなかった場合の rect をそのまま出力へ当てた場所）は
        // ぼけていない（差分なし）。
        let rawPixelRect = CGRect(x: sourceRect.minX * CGFloat(width), y: sourceRect.minY * CGFloat(height),
                                  width: sourceRect.width * CGFloat(width), height: sourceRect.height * CGFloat(height))
        let rawDiff = significantDiffCount(
            onBytes, offBytes, width: width, height: height,
            xRange: Int(rawPixelRect.minX)..<Int(rawPixelRect.maxX),
            yRange: Int(rawPixelRect.minY)..<Int(rawPixelRect.maxY))
        XCTAssertEqual(rawDiff, 0, "回転前の位置（\(sourceRect)）まで差分が出ている（全面モザイクの疑い）")
    }

    // MARK: - テキスト・透かしは回らない

    /// テキスト 1 本（`center=(0.8,0.2)`）で 4 つの回転それぞれについて「テキスト有り」
    /// 「無し」を描いて差分を取り、**変化領域の外接矩形の正規化中心が回転によらず
    /// `center` のまま**であること（＝「回転してもテキストは回らない」の機械的保証）。
    func test_rotationDoesNotMoveText() throws {
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
        style.fontSize = 0.15
        let textCenter = NormalizedPoint(x: 0.8, y: 0.2)

        for rotation: ClipRotation in [.none, .right90, .half, .left90] {
            let orientation = ClipOrientation(rotation: rotation)
            let currentLayout = layout(orientation: orientation)
            let withText = PhotoEditState(orientation: orientation)
                .addingText("A", center: textCenter, style: style)
            let withoutText = PhotoEditState(orientation: orientation)

            let textured = PhotoRenderPipeline.render(
                source: source, photoEdit: withText, renderer: renderer, layout: currentLayout,
                mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))
            let plain = PhotoRenderPipeline.render(
                source: source, photoEdit: withoutText, renderer: renderer, layout: currentLayout,
                mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

            let texturedBytes = try rawBytes(textured)
            let plainBytes = try rawBytes(plain)
            guard let center = significantDiffBoundingBoxCenter(
                texturedBytes, plainBytes, width: textured.width, height: textured.height
            ) else {
                XCTFail("rotation=\(rotation): テキストを描いたのに差分画素が1つも無い")
                continue
            }
            XCTAssertEqual(center.x, textCenter.x, accuracy: 0.05, "rotation=\(rotation)")
            XCTAssertEqual(center.y, textCenter.y, accuracy: 0.05, "rotation=\(rotation)")
        }
    }

    /// 同じ手口で、透かしが常に**出力フレームの右下**にあること（回転しても動かない）。
    func test_rotationDoesNotMoveWatermark() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, red: 0.35, green: 0.35, blue: 0.35)

        for rotation: ClipRotation in [.none, .right90, .half, .left90] {
            let orientation = ClipOrientation(rotation: rotation)
            let currentLayout = layout(orientation: orientation)
            let photoEdit = PhotoEditState(orientation: orientation)

            let watermarked = PhotoRenderPipeline.render(
                source: source, photoEdit: photoEdit, renderer: renderer, layout: currentLayout,
                mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: true))
            let plain = PhotoRenderPipeline.render(
                source: source, photoEdit: photoEdit, renderer: renderer, layout: currentLayout,
                mosaic: PhotoRenderPipeline.MosaicInput(),
                overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

            let watermarkedBytes = try rawBytes(watermarked)
            let plainBytes = try rawBytes(plain)
            let width = watermarked.width
            let height = watermarked.height

            let bottomRightDiff = significantDiffCount(
                watermarkedBytes, plainBytes, width: width, height: height,
                xRange: (width / 2)..<width, yRange: (height / 2)..<height)
            let topLeftDiff = significantDiffCount(
                watermarkedBytes, plainBytes, width: width, height: height,
                xRange: 0..<(width / 2), yRange: 0..<(height / 2))
            XCTAssertGreaterThanOrEqual(bottomRightDiff, 15,
                "rotation=\(rotation): 右下領域の画素がほぼ変わっていない（透かしが焼き込まれていない）")
            XCTAssertEqual(topLeftDiff, 0, "rotation=\(rotation): 左上領域まで画素が変わっている")
        }
    }
}
#endif
