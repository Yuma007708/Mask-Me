import XCTest
import AVFoundation
import CoreGraphics
import MosaicCore
import UIKit
@testable import MaskMe

#if canImport(Metal)
import Metal

/// ステッカー機能（アプリ層、S12）のテスト。
///
/// Core 層（`TimelineState.addingStickerItem` / `TextItemRole.maximumFontSize` 等）の
/// 契約は Core 側のテストが担う。ここではアプリ層に固有の実装だけを確かめる:
///
/// - `TextRasterizer` が絵文字を実際にラスタライズできている（豆腐や空画像でない）
/// - 書き出し経路（`VideoMosaicExporter`）へ実際に焼き込まれる（指定位置の画素が
///   変わり、枠外は変わらない。**プレビューだけ確かめても意味が無い**という
///   `MultiClipExportTests` の教訓に揃える）
/// - ステッカーとテキストが同時にあるとき両方が焼き込まれる
/// - `MosaicEditorModel.addStickerItem` が undo 1 回で消え、redo で戻る
final class StickerLayerTests: XCTestCase {

    // MARK: - 1. ラスタライズ（豆腐・空画像になっていないか）

    /// `TextRasterizer.rasterize` が絵文字を焼くと、中央に不透明画素があり
    /// 四隅は透明（＝背景を塗りつぶしていない）こと。
    func test_rasterizeSticker_hasOpaqueCenterAndTransparentCorners() throws {
        let cgImage = try XCTUnwrap(
            TextRasterizer.rasterize(text: "😀", style: .stickerDefault),
            "😀 のラスタライズが nil を返した（豆腐や空画像になっている疑い）")
        let width = cgImage.width
        let height = cgImage.height
        XCTAssertGreaterThan(width, 4, "出力画像の幅が小さすぎる")
        XCTAssertGreaterThan(height, 4, "出力画像の高さが小さすぎる")

        let data = try XCTUnwrap(cgImage.dataProvider?.data, "画素データを取得できない")
        let pixels = try XCTUnwrap(CFDataGetBytePtr(data), "画素バッファを取得できない")
        let bytesPerRow = cgImage.bytesPerRow

        // `TextRasterizer` の doc どおり premultiplied-first / little-endian BGRA。
        // メモリ上のバイト順は B, G, R, A なのでアルファはオフセット +3。
        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[y * bytesPerRow + x * 4 + 3]
        }

        let centerAlpha = alpha(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(centerAlpha, 200,
                             "絵文字の中央が不透明でない（豆腐や空画像として焼かれている疑い）")

        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            XCTAssertEqual(alpha(x: x, y: y), 0,
                           "四隅（\(x), \(y)）が透明でない（余白まで塗りつぶされている）")
        }
    }

    /// **不透明度スライダーが本当に効くことの実測。**
    ///
    /// ステッカーの不透明度は `style.color` のアルファに載せている。カラー絵文字は
    /// 前景色で色が変わらないため「アルファも効かないのでは」という疑いが実装時に
    /// 挙がった（CoreText の一般的な挙動からの推測で、実測されていなかった）。
    /// **推測のまま出すと「スライダーを動かしても何も起きない」UI になる**ので、
    /// ここで実際の画素を測って固定する。落ちたら別の仕組み（合成側でのアルファ）
    /// が要るという合図。
    func test_rasterizeSticker_不透明度が実際の画素に効く() throws {
        var half = TextStyle.stickerDefault
        half.color.alpha = 0.4

        let opaque = try XCTUnwrap(TextRasterizer.rasterize(text: "😀", style: .stickerDefault))
        let faded = try XCTUnwrap(TextRasterizer.rasterize(text: "😀", style: half))

        func centerAlpha(_ image: CGImage) throws -> UInt8 {
            let data = try XCTUnwrap(image.dataProvider?.data)
            let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
            return pixels[(image.height / 2) * image.bytesPerRow + (image.width / 2) * 4 + 3]
        }

        let opaqueAlpha = try centerAlpha(opaque)
        let fadedAlpha = try centerAlpha(faded)
        XCTAssertGreaterThan(opaqueAlpha, 200, "テスト前提: 不透明側の中央が不透明であること")
        XCTAssertLessThan(fadedAlpha, opaqueAlpha - 40,
                          "アルファを下げても画素の不透明度が変わらない"
                          + "（＝不透明度スライダーが効かない。別の仕組みが要る）")
    }

    // MARK: - 2. 書き出しへの焼き込み

    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    private struct RawFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    /// 全画面をグレー（輝度 90）で塗った mp4 を作る。均一なほど、ステッカー由来の
    /// 画素差分が圧縮ノイズと区別しやすい（`ExportWatermarkBurnInTests` と同じ考え方）。
    private func makeFlatGrayVideo(seconds: Double) async throws -> URL {
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
                        base[offset] = 90
                        base[offset + 1] = 90
                        base[offset + 2] = 90
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

    /// 領域内で「有意に違う」画素の数（R+G+B の絶対差の合計が閾値超）。
    private func significantDiffCount(
        _ a: RawFrame, _ b: RawFrame,
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

    private func buildFlatGraySource(seconds: Double) async throws
    -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition?,
        audioMix: AVMutableAudioMix?, layout: TimelineRenderLayout, clip: TimelineClip, sourceURL: URL) {
        let sourceURL = try await makeFlatGrayVideo(seconds: seconds)
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: seconds)
        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], sources: [sourceID: AVURLAsset(url: sourceURL)], isPro: true)
        return (built.composition, built.videoComposition, built.audioMix, built.layout, clip, sourceURL)
    }

    /// ステッカー 1 個を右下寄りへ置いた 1 フレームを書き出し、**指定した位置の画素が
    /// 変化し、離れた位置（左上）の画素は不変**であることを確かめる
    /// （`ExportWatermarkBurnInTests` と同じ「意図した位置にだけ効いているか」の判定手筋）。
    func test_sticker_burnsInAtSpecifiedPositionOnly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let source = try await buildFlatGraySource(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source.sourceURL) }

        var style = TextStyle.stickerDefault
        style.fontSize = 0.3
        let sticker = TextItem(text: "🔥", compositionStart: 0, duration: 1,
                               center: NormalizedPoint(x: 0.8, y: 0.8),
                               style: style, animation: .none, role: .sticker)

        let stickeredExporter = try makeExporter()
        let stickeredURL = try await stickeredExporter.export(
            asset: source.composition,
            mapping: TimelineMapping(clips: [source.clip]),
            textItems: [sticker],
            videoComposition: source.videoComposition,
            audioMix: source.audioMix,
            renderLayout: source.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: stickeredURL) }

        let plainExporter = try makeExporter()
        let plainURL = try await plainExporter.export(
            asset: source.composition,
            mapping: TimelineMapping(clips: [source.clip]),
            videoComposition: source.videoComposition,
            audioMix: source.audioMix,
            renderLayout: source.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let stickered = try rawFramePixels(url: stickeredURL, at: 0.5)
        let plain = try rawFramePixels(url: plainURL, at: 0.5)

        let cx = Int(Double(stickered.width) * 0.8)
        let cy = Int(Double(stickered.height) * 0.8)
        let stickerDiff = significantDiffCount(
            stickered, plain,
            xRange: max(0, cx - 20)..<min(stickered.width, cx + 20),
            yRange: max(0, cy - 20)..<min(stickered.height, cy + 20))
        let farDiff = significantDiffCount(
            stickered, plain,
            xRange: 0..<(stickered.width / 4),
            yRange: 0..<(stickered.height / 4))

        print("[STICKER] stickerDiff=\(stickerDiff) farDiff=\(farDiff)")
        XCTAssertGreaterThanOrEqual(stickerDiff, 15,
                                    "指定位置にステッカーが焼き込まれていない")
        XCTAssertLessThanOrEqual(farDiff, 5,
                                 "指定位置から離れた領域（左上）まで画素が変わっている")
    }

    /// ステッカーとテキストが同時にあるとき、**両方**が焼き込まれること
    /// （片方が上書きで消える／どちらかしか描かれない、を防ぐ）。
    func test_stickerAndText_bothBurnedInSimultaneously() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let source = try await buildFlatGraySource(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source.sourceURL) }

        var stickerStyle = TextStyle.stickerDefault
        stickerStyle.fontSize = 0.3
        let sticker = TextItem(text: "🔥", compositionStart: 0, duration: 1,
                               center: NormalizedPoint(x: 0.8, y: 0.8),
                               style: stickerStyle, animation: .none, role: .sticker)

        var textStyle = TextStyle()
        textStyle.fontSize = 0.2
        let text = TextItem(text: "MASK", compositionStart: 0, duration: 1,
                            center: NormalizedPoint(x: 0.2, y: 0.2),
                            style: textStyle, animation: .none, role: .text)

        let bothExporter = try makeExporter()
        let bothURL = try await bothExporter.export(
            asset: source.composition,
            mapping: TimelineMapping(clips: [source.clip]),
            textItems: [sticker, text],
            videoComposition: source.videoComposition,
            audioMix: source.audioMix,
            renderLayout: source.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: bothURL) }

        let plainExporter = try makeExporter()
        let plainURL = try await plainExporter.export(
            asset: source.composition,
            mapping: TimelineMapping(clips: [source.clip]),
            videoComposition: source.videoComposition,
            audioMix: source.audioMix,
            renderLayout: source.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let both = try rawFramePixels(url: bothURL, at: 0.5)
        let plain = try rawFramePixels(url: plainURL, at: 0.5)

        let stickerCx = Int(Double(both.width) * 0.8)
        let stickerCy = Int(Double(both.height) * 0.8)
        let stickerDiff = significantDiffCount(
            both, plain,
            xRange: max(0, stickerCx - 20)..<min(both.width, stickerCx + 20),
            yRange: max(0, stickerCy - 20)..<min(both.height, stickerCy + 20))

        let textCx = Int(Double(both.width) * 0.2)
        let textCy = Int(Double(both.height) * 0.2)
        let textDiff = significantDiffCount(
            both, plain,
            xRange: max(0, textCx - 30)..<min(both.width, textCx + 30),
            yRange: max(0, textCy - 15)..<min(both.height, textCy + 15))

        print("[STICKER+TEXT] stickerDiff=\(stickerDiff) textDiff=\(textDiff)")
        XCTAssertGreaterThanOrEqual(stickerDiff, 15, "ステッカーが焼き込まれていない")
        XCTAssertGreaterThanOrEqual(textDiff, 15, "テキストが焼き込まれていない")
    }

    // MARK: - 3. undo / redo（アプリ層 API: `MosaicEditorModel.addStickerItem`）

    /// `addStickerItem` が undo 1 回で消え、redo で戻ること
    /// （`FreezeFrameTests.test_freezeFrame_undoRestoresOriginalTimeline` と同じ流儀）。
    @MainActor
    func test_addStickerItem_undoRemovesRedoRestores() async throws {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        model.setClipsForTesting([clip])
        model.commitEdit()
        let timelineBefore = model.timeline

        model.addStickerItem("😀", atCompositionTime: 0)

        XCTAssertEqual(model.timeline.textItems.count, 1,
                       "ステッカーの追加が timeline へ反映されていない")
        XCTAssertEqual(model.timeline.textItems.first?.role, .sticker,
                       "追加した項目の role が .sticker になっていない")

        model.undo()
        XCTAssertEqual(model.timeline, timelineBefore,
                       "undo 1 回でステッカー追加前のタイムラインへ戻っていない")

        model.redo()
        XCTAssertEqual(model.timeline.textItems.count, 1,
                       "redo でステッカーの追加が戻っていない")
        XCTAssertEqual(model.timeline.textItems.first?.role, .sticker)
    }
}

#endif
