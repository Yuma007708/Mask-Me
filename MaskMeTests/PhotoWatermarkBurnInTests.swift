import XCTest
import CoreGraphics
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// 無料プランの写真透かし（課金 P2・写真モード底上げ 第3段）が
/// `PhotoRenderPipeline.render` で実際に画素へ焼き込まれることを直接確かめる。
///
/// `ExportWatermarkBurnInTests.swift`（動画書き出し経路）の写し。写真は
/// `AVAssetWriter` を経由しないぶん検証がシンプルになる
/// （`PhotoTextBurnInTests` の doc と同じ理由で `PhotoRenderPipeline.render` を直接叩く）。
final class PhotoWatermarkBurnInTests: XCTestCase {
    private let canvasSize = 400

    private func makeFlatTexture(device: MTLDevice, gray: CGFloat) throws -> MTLTexture {
        let size = CGSize(width: canvasSize, height: canvasSize)
        let uiImage = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: gray, green: gray, blue: gray, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        let cgImage = try XCTUnwrap(uiImage.cgImage)
        return try MetalTextureUtilities.texture(from: cgImage, device: device)
    }

    private func makeRenderer() throws -> MosaicRenderer {
        try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
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

    private func significantDiffCount(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
        xRange: Range<Int>, yRange: Range<Int>, threshold: Int = 20
    ) -> Int {
        var count = 0
        for y in yRange where y < height {
            for x in xRange where x < width {
                let offset = (y * width + x) * 4
                let diff = abs(Int(a[offset]) - Int(b[offset]))
                    + abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                    + abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                if diff > threshold { count += 1 }
            }
        }
        return count
    }

    /// `needsWatermark: true` で render すると、出力の右下 1/4 領域の画素が
    /// （`needsWatermark: false` と比べて）実際に変わっていること。左上 1/4 には
    /// 及んでいないこと（画面全体を汚していないこと）も併せて確かめる。
    func test_needsWatermarkTrue_burnsInVisibleDifferenceAtBottomRightOnly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, gray: 0.35)

        let watermarked = PhotoRenderPipeline.render(
            source: source, photoEdit: .identity, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: true))
        let plain = PhotoRenderPipeline.render(
            source: source, photoEdit: .identity, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

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

        print("[PHOTO WATERMARK] bottomRightDiff=\(bottomRightDiff) topLeftDiff=\(topLeftDiff)")
        XCTAssertGreaterThanOrEqual(bottomRightDiff, 15,
            "needsWatermark:true なのに右下領域の画素がほぼ変わっていない。透かしが焼き込まれていない可能性がある。")
        XCTAssertEqual(topLeftDiff, 0, "左上領域まで画素が変わっている。透かしが画面全体を汚している可能性がある。")
    }

    /// `needsWatermark: false` では出力が入力とバイト単位で完全一致すること。
    /// **「変化が小さい」ではなく完全一致で判定する**（薄く常時描く実装を通さないため。
    /// `PhotoRenderPipeline` の素通り対策の項参照）。
    func test_needsWatermarkFalse_producesPixelIdenticalOutput() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, gray: 0.5)

        let output = PhotoRenderPipeline.render(
            source: source, photoEdit: .identity, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

        let sourceBytes = try rawBytes(source)
        let outputBytes = try rawBytes(output)
        XCTAssertEqual(sourceBytes, outputBytes,
            "needsWatermark:false・無編集なのに出力が入力とバイト単位で一致しない")
    }

    /// ユーザーテキストを透かしと同じ右下（`center = (0.9, 0.9)`）に置いて重ねても、
    /// 透かし側の画素が勝つ（最後に描かれる）こと。
    ///
    /// 「透かしが載っている」ことだけでなく、**描画順（テキスト → 透かし）が
    /// 実際に守られている**ことまで確かめる（透かしをユーザーが自分のテキストで
    /// 隠せてしまったら透かしの意味が無い）。
    func test_watermarkIsDrawnAboveUserText() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try makeRenderer()
        let cache = TextOverlayCache(device: renderer.device)
        let source = try makeFlatTexture(device: renderer.device, gray: 0.35)

        // 透かしと完全に重なるよう、大きな不透明の背景帯を持つテキストを右下へ敷く。
        var coveringStyle = TextStyle()
        coveringStyle.fontSize = 0.4
        coveringStyle.color = .black
        coveringStyle.strokeWidth = 0
        coveringStyle.backgroundOpacity = 1
        coveringStyle.backgroundColor = .black
        let withCoveringText = PhotoEditState.identity.addingText(
            "COVER", center: NormalizedPoint(x: 0.9, y: 0.9), style: coveringStyle)

        let output = PhotoRenderPipeline.render(
            source: source, photoEdit: withCoveringText, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: true))
        let textOnlyNoWatermark = PhotoRenderPipeline.render(
            source: source, photoEdit: withCoveringText, renderer: renderer,
            mosaic: PhotoRenderPipeline.MosaicInput(), overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: false))

        let outputBytes = try rawBytes(output)
        let textOnlyBytes = try rawBytes(textOnlyNoWatermark)
        let width = output.width
        let height = output.height

        // 透かしが「ユーザーの黒い帯の上」に実際に乗っているなら、右下領域は
        // watermark あり/なしで有意に異なるはず（黒一色のままなら透かしが埋もれている）。
        let bottomRightDiff = significantDiffCount(
            outputBytes, textOnlyBytes, width: width, height: height,
            xRange: (width / 2)..<width, yRange: (height / 2)..<height)
        print("[PHOTO WATERMARK ABOVE TEXT] bottomRightDiff=\(bottomRightDiff)")
        XCTAssertGreaterThanOrEqual(bottomRightDiff, 15,
            "ユーザーテキストの背景帯に透かしが隠れている（描画順が崩れている可能性がある）")
    }
}
#endif
