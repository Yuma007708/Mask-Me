import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// 無料プランの透かし（課金 P2）が**書き出し経路**で実際に画素へ焼き込まれることを
/// 直接確かめる（プレビュー側は目視確認済みだが、書き出しは別経路
/// `VideoMosaicExporter.export(needsWatermark:)` → `WatermarkCompositor` を通るため未検証だった）。
///
/// `ExportWatermark.center` などの座標計算そのものは `MosaicCore` 側の純関数テストが
/// 既に固定しているので、ここでは位置の細かい数式に依存しない。
/// 「右下 1/4 に有意な差分画素が一定数以上ある」「左上 1/4 には無い」という
/// ゆるい・しかし実質的な判定にとどめる。
/// RGB 単色（0...255）。3 要素タプルの代わりに使う小さな値型。
private struct FlatColor {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

/// `AVAssetImageGenerator` で取り出した 1 フレームの生 RGBA バッファ。
private struct RawFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

final class ExportWatermarkBurnInTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    // MARK: - 素材生成

    /// 全画面を単色で塗った mp4 を生成する。
    ///
    /// 透かしが乗る右下が均一な色であるほど、圧縮ノイズと透かし由来の変化が
    /// 区別しやすい。ノイズを混ぜる（`CompositionFidelityTests` 参照）のは
    /// ビットレート比較のための工夫であり、画素差分の検出にはむしろ不利なので使わない。
    private func makeFlatColorVideo(seconds: Double, color: FlatColor) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bytesPerRow + x * 4
                        // BGRA 順。
                        base[offset] = color.b
                        base[offset + 1] = color.g
                        base[offset + 2] = color.r
                        base[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// `AVAssetImageGenerator` で 1 フレームを取り出し、RGBA 生ピクセルを返す
    /// （`MultiClipExportTests.displayedQuadrants` と同じ考え方だが、象限平均ではなく
    /// 画素単位の差分を数えたいので生バッファのまま返す）。
    private func rawFramePixels(url: URL, at seconds: Double) throws -> RawFrame {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cg = try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RawFrame(width: w, height: h, pixels: pixels)
    }

    /// 領域内で「有意に違う」画素の数を数える（R+G+B の絶対差の合計が閾値を超える画素）。
    /// 圧縮ノイズは通常この閾値を超えない小さなブレに収まる。
    private func significantDiffCount(
        _ a: RawFrame,
        _ b: RawFrame,
        xRange: Range<Int>, yRange: Range<Int>,
        channelDiffThreshold: Int = 30
    ) -> Int {
        let w = min(a.width, b.width)
        let h = min(a.height, b.height)
        var count = 0
        for y in yRange where y < h {
            for x in xRange where x < w {
                let offsetA = (y * a.width + x) * 4
                let offsetB = (y * b.width + x) * 4
                let diff = abs(Int(a.pixels[offsetA]) - Int(b.pixels[offsetB]))
                    + abs(Int(a.pixels[offsetA + 1]) - Int(b.pixels[offsetB + 1]))
                    + abs(Int(a.pixels[offsetA + 2]) - Int(b.pixels[offsetB + 2]))
                if diff > channelDiffThreshold { count += 1 }
            }
        }
        return count
    }

    private func makeExporter() throws -> VideoMosaicExporter {
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        return VideoMosaicExporter(renderer: renderer, landmarker: NullFaceLandmarker())
    }

    // MARK: - テスト

    /// `needsWatermark: true` で書き出すと、出力の右下 1/4 領域の画素が
    /// （透かし無しで書き出した同じ素材と比べて）実際に変わっていること。
    /// 左上 1/4 には透かしが及んでいない（画面全体を汚していない）ことも併せて確かめる。
    func test_needsWatermarkTrue_burnsInVisibleDifferenceAtBottomRightOnly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let sourceURL = try await makeFlatColorVideo(seconds: 1.0, color: FlatColor(r: 90, g: 90, b: 90))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)

        let watermarkedExporter = try makeExporter()
        let watermarkedURL = try await watermarkedExporter.export(
            asset: asset, needsWatermark: true
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: watermarkedURL) }

        let plainExporter = try makeExporter()
        let plainURL = try await plainExporter.export(
            asset: asset, needsWatermark: false
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let watermarked = try rawFramePixels(url: watermarkedURL, at: 0.5)
        let plain = try rawFramePixels(url: plainURL, at: 0.5)

        let bottomRightDiff = significantDiffCount(
            watermarked, plain,
            xRange: (watermarked.width / 2)..<watermarked.width,
            yRange: (watermarked.height / 2)..<watermarked.height)
        let topLeftDiff = significantDiffCount(
            watermarked, plain,
            xRange: 0..<(watermarked.width / 2),
            yRange: 0..<(watermarked.height / 2))

        print("[WATERMARK] bottomRightDiff=\(bottomRightDiff) topLeftDiff=\(topLeftDiff)")
        XCTAssertGreaterThanOrEqual(bottomRightDiff, 15,
                                    "needsWatermark:true なのに右下領域の画素がほぼ変わっていない。"
                                    + "透かしが書き出しへ焼き込まれていない可能性がある。")
        XCTAssertLessThanOrEqual(topLeftDiff, 5,
                                 "左上領域まで画素が変わっている。透かしが画面全体を汚している可能性がある。")
    }

    /// `needsWatermark: false`（既定）では、右下領域が素材のまま
    /// （透かしを勝手に載せない）ことを確かめる。
    ///
    /// 比較対象は「透かし無しで書き出した動画」対「元の素材動画」。書き出しは
    /// 一度デコード・Metal 合成・再エンコードを経るため微小な圧縮差は避けられないが、
    /// 単色素材の右下領域であれば有意な差分画素はごくわずかに収まるはずで、
    /// 透かし焼き込み（数十〜数百画素規模の変化）とは桁が違う。
    func test_needsWatermarkFalse_keepsBottomRightAsSourceMaterial() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let sourceURL = try await makeFlatColorVideo(seconds: 1.0, color: FlatColor(r: 90, g: 90, b: 90))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: asset, needsWatermark: false
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let source = try rawFramePixels(url: sourceURL, at: 0.5)
        let out = try rawFramePixels(url: outURL, at: 0.5)

        let bottomRightDiff = significantDiffCount(
            source, out,
            xRange: (source.width / 2)..<source.width,
            yRange: (source.height / 2)..<source.height)

        print("[WATERMARK] needsWatermark=false bottomRightDiff=\(bottomRightDiff)")
        XCTAssertLessThanOrEqual(bottomRightDiff, 10,
                                 "needsWatermark:false なのに右下領域が素材から大きく変わっている。"
                                 + "透かしが既定で載ってしまっている可能性がある。")
    }
}

#endif
