import XCTest
import AVFoundation
import CoreGraphics
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// 色調補正（P4）のアプリ層配線を検証する。
///
/// Core 層（`ColorGrade.apply` / `colorGradeKernel` / `TimelineState.colorGrade`）は
/// 別コミットで固定済み。ここは**配線**（両経路への結線・検出との順序・透かしとの順序・
/// モザイク幾何の不変性・ツールバーの項目数）だけを見る。
///
/// 実顔素材（MediaPipe）を使わず、単色 mp4 と決定的なフェイクの `FaceLandmarking` で
/// 完結させてある（`ExportWatermarkBurnInTests` / `MultiClipExportTests` と同じ流儀）。
/// **理由**: 「検出は補正前を見ている」を実 MediaPipe で確かめようとすると、
/// `contrast = 0` は全画面を厳密な中間グレーへ潰すため、モザイクの有無が画素で
/// 区別できなくなる（ブロック平均も背景と同じ値に潰れるため）。かわりに
/// `SpyFaceLandmarker` で「検出へ渡された画像の平均輝度」を直接観測し、
/// 補正前の輝度と一致することを確かめる（検出対象が本当に生バッファかどうかを
/// 画素の平坦さ経由の間接推論ではなく直接見る、より強い検証）。
final class ColorGradeAppLayerTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    // MARK: - 素材生成

    /// 全画面を単色で塗った mp4 を生成する（`ExportWatermarkBurnInTests.makeFlatColorVideo`
    /// と同じ手法。フラット素材は H.264 の圧縮誤差が小さく、輝度の期待値比較に向く）。
    private func makeFlatColorVideo(seconds: Double, r: UInt8, g: UInt8, b: UInt8) async throws -> URL {
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
                        base[offset] = b
                        base[offset + 1] = g
                        base[offset + 2] = r
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

    /// 市松模様（8px 格子・2 色交互）の mp4。フラット素材と違い、ブロック平均が
    /// 元画素と必ず変わるので「モザイクが実際に効いたか」を画素差分で判定できる
    /// （`test_mosaicGeometryUnaffectedByColorGrade` 用）。
    private func makeCheckerboardVideo(seconds: Double) async throws -> URL {
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
                        let isLight = ((x / 8) + (y / 8)).isMultiple(of: 2)
                        let value: UInt8 = isLight ? 220 : 40
                        let offset = y * bytesPerRow + x * 4
                        base[offset] = value
                        base[offset + 1] = value
                        base[offset + 2] = value
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

    // MARK: - フレーム読み出し

    private struct RawFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
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

    /// 指定領域の平均 RGB（0...255）。
    private func averageRGB(_ frame: RawFrame, xRange: Range<Int>, yRange: Range<Int>) -> (r: Double, g: Double, b: Double) {
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        for y in yRange where y < frame.height {
            for x in xRange where x < frame.width {
                let offset = (y * frame.width + x) * 4
                sumR += Double(frame.pixels[offset])
                sumG += Double(frame.pixels[offset + 1])
                sumB += Double(frame.pixels[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (sumR / Double(count), sumG / Double(count), sumB / Double(count))
    }

    /// 「有意に違う」画素の位置集合（線形添字 `y*width+x`）。
    /// `ExportWatermarkBurnInTests.significantDiffCount` と同じ判定を、件数ではなく
    /// **位置集合**として返す（モザイクの幾何一致テストは位置そのものを比較したいため）。
    private func significantDiffPositions(
        _ a: RawFrame, _ b: RawFrame, channelDiffThreshold: Int = 30
    ) -> Set<Int> {
        let w = min(a.width, b.width)
        let h = min(a.height, b.height)
        var positions: Set<Int> = []
        for y in 0..<h {
            for x in 0..<w {
                let offsetA = (y * a.width + x) * 4
                let offsetB = (y * b.width + x) * 4
                let diff = abs(Int(a.pixels[offsetA]) - Int(b.pixels[offsetB]))
                    + abs(Int(a.pixels[offsetA + 1]) - Int(b.pixels[offsetB + 1]))
                    + abs(Int(a.pixels[offsetA + 2]) - Int(b.pixels[offsetB + 2]))
                if diff > channelDiffThreshold { positions.insert(y * w + x) }
            }
        }
        return positions
    }

    /// しきい値ごとの差分画素数の一覧（**診断専用**。合否判定には使わない）。
    /// 「この判定しきい値が符号化ノイズを数えていないか」を数字で見るために出す。
    private func diffProfile(_ a: RawFrame, _ b: RawFrame) -> String {
        [10, 20, 40, 60, 90, 120, 180]
            .map { "\($0):\(significantDiffPositions(a, b, channelDiffThreshold: $0).count)" }
            .joined(separator: " ")
    }

    private func makeExporter(landmarker: FaceLandmarking = NullFaceLandmarker()) throws -> VideoMosaicExporter {
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        return VideoMosaicExporter(renderer: renderer, landmarker: landmarker)
    }

    // MARK: - フェイクの検出器

    /// 呼ばれるたびに、指定した矩形を覆う固定の顔（非フルメッシュ→コンタマスク経路）を返す。
    /// モザイクの有無を「検出できたかどうか」に依存させたくないテスト
    /// （幾何不変性・透かし独立性）で、常に同じ場所へモザイクを掛けさせるために使う。
    ///
    /// ⚠️ **点を 4 つだけ返してはいけない。** マスクは
    /// `FaceMaskBuilder.regionPaths` → `FaceLandmarkSet.polygon(for:)` を通り、
    /// 輪郭は **MediaPipe 正準の添字**（`faceOval` は 10…454）で引かれる。疎な
    /// 4 点集合ではどの添字も範囲外になり `polygon` が空を返す → 領域パスが 0 本 →
    /// マスクが全面 0 → **モザイクが 1 画素も乗らない**（実測: 幾何テストの
    /// 差分画素数が 0 になり、テスト自体が無意味になっていた）。
    /// そこで `fullMeshCount`(478) 未満の 468 点を作り（フルメッシュ判定に
    /// 引っかからないのでコンタマスク経路を通る）、`faceOval` の添字を矩形の
    /// 内接楕円上へ、残りの点は矩形の内側へ置く。
    private final class FixedRectLandmarker: FaceLandmarking, @unchecked Sendable {
        private let set: FaceLandmarkSet
        init(rect: CGRect) { self.set = Self.makeFace(rect: rect) }

        private static func makeFace(rect: CGRect) -> FaceLandmarkSet {
            let count = 468
            precondition(count < FaceLandmarkSet.fullMeshCount)
            // 既定値は矩形内部の決定的な格子（目・口の輪郭添字もここに落ちるので、
            // それらの小さな凸包は必ず矩形の内側に収まる）。
            var points: [FaceLandmark] = (0..<count).map { i in
                let gx = Double(i % 20) / 19.0
                let gy = Double(i / 20) / Double((count - 1) / 20)
                return FaceLandmark(
                    x: Float(rect.minX + rect.width * (0.3 + 0.4 * gx)),
                    y: Float(rect.minY + rect.height * (0.3 + 0.4 * gy)))
            }
            // faceOval を矩形の内接楕円上へ等間隔に置く（凸包が矩形をほぼ覆う）。
            let oval = FaceRegion.faceOval.indices
            for (n, index) in oval.enumerated() where index < count {
                let theta = 2 * Double.pi * Double(n) / Double(oval.count)
                points[index] = FaceLandmark(
                    x: Float(rect.midX + rect.width / 2 * cos(theta)),
                    y: Float(rect.midY + rect.height / 2 * sin(theta)))
            }
            return FaceLandmarkSet(points: points, confidence: 1)
        }

        func landmarks(in image: UIImage) -> FaceLandmarkSet? { set }
        func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? { set }
        func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] { [set] }
        func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] { [set] }
    }

    /// 検出へ渡された画像の平均輝度を記録するスパイ。顔は検出しない（`NullFaceLandmarker`
    /// と同じ戻り値）ので、モザイクの有無ではなく**入力そのもの**を直接見る
    /// （`test_detectionSeesPreGradeBuffer` 用）。
    private final class SpyBrightnessLandmarker: FaceLandmarking, @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Double] = []
        var meanBrightness: Double? {
            lock.lock()
            defer { lock.unlock() }
            guard !samples.isEmpty else { return nil }
            return samples.reduce(0, +) / Double(samples.count)
        }
        private func record(_ image: UIImage) {
            guard let cg = image.cgImage else { return }
            let w = cg.width, h = cg.height
            guard w > 0, h > 0 else { return }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                sum += Double(pixels[i])
            }
            let mean = sum / Double(w * h)
            lock.lock()
            samples.append(mean)
            lock.unlock()
        }
        func landmarks(in image: UIImage) -> FaceLandmarkSet? { record(image); return nil }
        func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? { record(image); return nil }
        func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] { record(image); return [] }
        func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] { record(image); return [] }
    }

    // MARK: - 1) 書き出しで色が実際に変わる（数値で測る）

    /// 2 クリップ（A: `brightness = +0.5`、B: identity）を書き出し、各区間のフレームの
    /// 平均輝度を測る。
    ///
    /// ⚠️ **絶対値で期待値を立ててはいけない。** H.264 の符号化・復号は輝度の恒等写像では
    /// ない（フルレンジ／ビデオレンジの往復等）。実測で、補正を **1 回も掛けない**
    /// identity クリップですら 100 → 111 とずれる。したがって「補正なしで書き出した
    /// 実測値」を baseline に取り、**baseline との差分**で `ColorGrade.apply` と
    /// 突き合わせる（同じ素材・同じ書き出しなので、往復誤差は差分でほぼ相殺される）。
    /// baseline は同じ出力ファイルの identity 区間（clipB）そのものを使う。
    func test_exporterAppliesColorGrade_matchesCoreFormulaWithinTolerance() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let sourceValue: UInt8 = 100
        let urlA = try await makeFlatColorVideo(seconds: 1.0, r: sourceValue, g: sourceValue, b: sourceValue)
        defer { try? FileManager.default.removeItem(at: urlA) }
        let urlB = try await makeFlatColorVideo(seconds: 1.0, r: sourceValue, g: sourceValue, b: sourceValue)
        defer { try? FileManager.default.removeItem(at: urlB) }

        let sourceIDA = UUID()
        let sourceIDB = UUID()
        let clipA = TimelineClip(sourceID: sourceIDA, sourceStart: 0, sourceEnd: 1.0)
        let clipB = TimelineClip(sourceID: sourceIDB, sourceStart: 0, sourceEnd: 1.0)
        let clips = [clipA, clipB]
        let sources: [UUID: AVAsset] = [sourceIDA: AVURLAsset(url: urlA), sourceIDB: AVURLAsset(url: urlB)]
        let built = try await TimelineCompositionBuilder().build(clips: clips, sources: sources, isPro: true)
        let mapping = TimelineMapping(clips: clips)

        let grade = ColorGrade(brightness: 0.5, contrast: 1, saturation: 1, warmth: 0)
        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: built.composition, mapping: mapping,
            colorGrades: [clipA.id: grade, clipB.id: .identity]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let frameA = try rawFramePixels(url: outURL, at: 0.5)
        let frameB = try rawFramePixels(url: outURL, at: 1.5)
        let avgA = averageRGB(frameA, xRange: 0..<frameA.width, yRange: 0..<frameA.height)
        let avgB = averageRGB(frameB, xRange: 0..<frameB.width, yRange: 0..<frameB.height)

        // baseline（identity 区間）の実測値を `ColorGrade.apply` の入力に使う。
        // これで「符号化往復でずれた入力」に対する正しい期待差が出る。
        let baseline = avgB.r / 255.0
        let expected = grade.apply(r: baseline, g: baseline, b: baseline)
        let expectedDelta = (expected.0 - baseline) * 255.0

        print("[COLORGRADE] clipA avg=\(avgA) clipB(baseline) avg=\(avgB) "
              + "observedDelta=\(avgA.r - avgB.r) expectedDelta=\(expectedDelta) source=\(sourceValue)")

        // 許容 4.0/255（≒1.6%）の根拠（実測値。通るまで緩めた値ではない）:
        // - identity の往復は 100 → 111 で、恒等ではなく傾き ≒0.97 のアフィンに近い。
        // - そのため出力側の再符号化だけでも、期待差 63.75 は実測 62.0 になる（不足 1.75）。
        // - 4.0 はこの実測誤差の約 2 倍。一方、配線の欠陥はこの桁に収まらない
        //   （補正が効かない → 差 0 / 二重適用 → 差 ≒127 / 係数違い → 差が数十ずれる）ので、
        //   落とすべきものは確実に落ちる。
        let tolerance = 4.0
        XCTAssertEqual(avgA.r - avgB.r, expectedDelta, accuracy: tolerance,
                       "brightness=+0.5 の輝度差が ColorGrade.apply の期待差から外れている")
        XCTAssertEqual(avgA.g - avgB.g, expectedDelta, accuracy: tolerance)
        XCTAssertEqual(avgA.b - avgB.b, expectedDelta, accuracy: tolerance)
        XCTAssertGreaterThan(avgA.r, avgB.r + 10,
                             "brightness=+0.5 区間が identity 区間より明るくなっていない")
    }

    // MARK: - 2) identity では画素が完全一致

    /// `colorGrades` を明示的に渡さない（既定 `[:]` = 全クリップ identity）書き出しと、
    /// 明示的に `.identity` を渡した書き出しが同一の画素になること
    /// （`grade.isIdentity` なら 1 パスも発行しないので、両者は同じ計算経路を通る）。
    func test_identityColorGrade_producesPixelIdenticalOutput() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let sourceURL = try await makeFlatColorVideo(seconds: 1.0, r: 60, g: 140, b: 200)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)

        // 実際に `colorGrade(mapping:at:)` の「クリップは解決できたが辞書の値が
        // `.identity`」という分岐を通す（`mapping` を空のままにすると
        // `sourceLocations(at:)` が空を返して常に `.identity` に落ちてしまい、
        // `colorGrades` の中身が一切試されないまま無意味な比較になる）。
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1.0)
        let mapping = TimelineMapping(clips: [clip])

        let withoutGrade = try makeExporter()
        let urlWithout = try await withoutGrade.export(asset: asset, mapping: mapping) { _ in }
        defer { try? FileManager.default.removeItem(at: urlWithout) }

        let withIdentity = try makeExporter()
        let urlWithIdentity = try await withIdentity.export(
            asset: asset, mapping: mapping,
            colorGrades: [clip.id: .identity]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: urlWithIdentity) }

        let a = try rawFramePixels(url: urlWithout, at: 0.5)
        let b = try rawFramePixels(url: urlWithIdentity, at: 0.5)
        let diffPositions = significantDiffPositions(a, b, channelDiffThreshold: 6)

        print("[COLORGRADE] identity diffPositions=\(diffPositions.count)")
        XCTAssertEqual(diffPositions.count, 0,
                       "identity の色調補正で画素が変わっている（ゼロコスト経路が壊れている）")
    }

    // MARK: - 3) モザイクの幾何が変わらない

    /// grade は全画面に掛かる（モザイク領域の外の色も変わる）ので、「元フレームと
    /// 何が違うか」を直接 grade 有り／無しで比べると、grade 由来の色変化がそのまま
    /// 大量の疑似差分になり、モザイクの幾何比較にならない。**そこでモザイクだけが
    /// 動かした画素**を、同じ grade 条件のペア（モザイク有り − モザイク無し）で
    /// 抽出してから、grade 有り側の集合と grade 無し側の集合を比べる。
    ///
    /// - `gradedWithMosaic` − `gradedWithoutMosaic` = grade を掛けた状態でモザイクが
    ///   動かした画素位置の集合
    /// - `plainWithMosaic` − `plainWithoutMosaic` = grade 無しでモザイクが動かした
    ///   画素位置の集合
    ///
    /// この 2 集合が一致すれば「モザイクの幾何は grade の有無で変わっていない」。
    func test_mosaicGeometryUnaffectedByColorGrade() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let sourceURL = try await makeCheckerboardVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1.0)
        let mapping = TimelineMapping(clips: [clip])
        // 画面中央に固定矩形。モザイクの有無は検出結果ではなく `FixedRectLandmarker` が
        // 決めるので、grade の有無で検出結果が変わっても幾何は影響を受けない
        // （このクラスの冒頭 doc・`test_detectionSeesPreGradeBuffer` が別途検出順序を見る）。
        let mosaicLandmarker = FixedRectLandmarker(rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        let noMosaicLandmarker = NullFaceLandmarker()
        let applyRanges = MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [])
        // ⚠️ **クランプする grade を使わないこと。** ここは「モザイクが動かした画素の
        // **位置集合**」をしきい値つきの画素差分で近似している。`ColorGrade.apply` の
        // 最終クランプに掛かるほど強い補正を掛けると、明部・暗部が 0/1 へ張り付いて
        // 「モザイク後の色」と「元の色」が同じ値に潰れ、その画素だけ差分が消える。
        // これは**幾何の変化ではなく測り方の副作用**なのに、対称差として計上されてしまう
        // （実測: brightness=-0.4/contrast=1.8 で暗部が 0 に張り付き、対称差 1107）。
        // 市松（0.157 / 0.863）が 0...1 に収まる範囲で、なお十分に強い補正を使う。
        let strongGrade = ColorGrade(brightness: 0, contrast: 1.2, saturation: 0.5, warmth: 0.1)

        func export(landmarker: FaceLandmarking, grade: ColorGrade?) async throws -> URL {
            let exporter = try makeExporter(landmarker: landmarker)
            return try await exporter.export(
                asset: asset, mapping: mapping, applyRanges: applyRanges,
                colorGrades: grade.map { [clip.id: $0] } ?? [:]
            ) { _ in }
        }

        let gradedWithMosaicURL = try await export(landmarker: mosaicLandmarker, grade: strongGrade)
        defer { try? FileManager.default.removeItem(at: gradedWithMosaicURL) }
        let gradedNoMosaicURL = try await export(landmarker: noMosaicLandmarker, grade: strongGrade)
        defer { try? FileManager.default.removeItem(at: gradedNoMosaicURL) }
        let plainWithMosaicURL = try await export(landmarker: mosaicLandmarker, grade: nil)
        defer { try? FileManager.default.removeItem(at: plainWithMosaicURL) }
        let plainNoMosaicURL = try await export(landmarker: noMosaicLandmarker, grade: nil)
        defer { try? FileManager.default.removeItem(at: plainNoMosaicURL) }

        let gradedWithMosaic = try rawFramePixels(url: gradedWithMosaicURL, at: 0.5)
        let gradedNoMosaic = try rawFramePixels(url: gradedNoMosaicURL, at: 0.5)
        let plainWithMosaic = try rawFramePixels(url: plainWithMosaicURL, at: 0.5)
        let plainNoMosaic = try rawFramePixels(url: plainNoMosaicURL, at: 0.5)

        // しきい値 120（3 チャンネルの絶対差の和 = 1 チャンネルあたり 40）は実測で決めた:
        // モザイクが実際に動かす量は「市松の 220/40 → ブロック平均 130」で 90/ch（和 270）と
        // 桁違いに大きく、一方 H.264 の再符号化ノイズ（4 本を別々に符号化している）は
        // エッジ周辺で 1 チャンネルあたり十数まで出る。20（和）だと後者を大量に数え、
        // 集合が符号化ノイズで揺れて幾何比較にならない。
        let mosaicPixelsWithGrade = significantDiffPositions(gradedNoMosaic, gradedWithMosaic, channelDiffThreshold: 120)
        let mosaicPixelsWithoutGrade = significantDiffPositions(plainNoMosaic, plainWithMosaic, channelDiffThreshold: 120)

        let symmetricDiff = mosaicPixelsWithGrade.symmetricDifference(mosaicPixelsWithoutGrade).count
        print("[COLORGRADE] geometry withGrade=\(mosaicPixelsWithGrade.count) "
              + "withoutGrade=\(mosaicPixelsWithoutGrade.count) symmetricDiff=\(symmetricDiff)")
        print("[COLORGRADE] geometry profile graded=[\(diffProfile(gradedNoMosaic, gradedWithMosaic))] "
              + "plain=[\(diffProfile(plainNoMosaic, plainWithMosaic))]")

        XCTAssertGreaterThan(mosaicPixelsWithoutGrade.count, 0,
                             "テスト前提: モザイクが一度も効いていない（テスト自体が意味を成していない）")
        XCTAssertGreaterThan(mosaicPixelsWithGrade.count, 0,
                             "テスト前提: 色調補正を掛けた側でモザイクが一度も効いていない")
        // 完全一致は圧縮ノイズの端で数ピクセルぶれうるため、対称差が全体の 2% 未満なら
        // 「同じ幾何」とみなす（既存の実写系テストと同じ、閾値つきの実測比較）。
        let tolerance = max(20, mosaicPixelsWithoutGrade.count / 50)
        XCTAssertLessThanOrEqual(symmetricDiff, tolerance,
                                 "色調補正の有無でモザイクの掛かる画素位置が変わっている"
                                     + "（幾何に影響してはならない）: symmetricDiff=\(symmetricDiff)")
    }

    // MARK: - 4) 透かしが補正の影響を受けない

    /// 色調補正の**固定点**（r=g=b=0.5 の中間グレー。`ColorGrade.apply` は
    /// brightness=0・warmth=0 のとき常にこの値を不動点にする）を背景にした素材で、
    /// コントラスト・彩度だけを極端にした grade を掛けて無料プラン書き出しする。
    /// 背景は grade の有無で画素が変わらないので、透かし（背景と 50% で alpha
    /// ブレンドされる。`ExportWatermark.opacity = 0.5`）も grade の有無で変わらないはず
    /// （ここが崩れたら「透かしは補正の影響を受けない」という設計上の期待が壊れている）。
    func test_watermarkUnaffectedByColorGrade() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let midGray: UInt8 = 128
        let sourceURL = try await makeFlatColorVideo(seconds: 1.0, r: midGray, g: midGray, b: midGray)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)

        // brightness と warmth は不動点を崩すので identity のまま、コントラスト・彩度だけ
        // 最大まで振る（不動点を保ったまま「極端な grade」にする）。
        let extremeGrade = ColorGrade(brightness: 0, contrast: 2.0, saturation: 0.0, warmth: 0)

        // `colorGrades` は clipID をキーに合成時刻から引く（`colorGrade(mapping:at:)` の
        // doc 参照）。**`mapping` を空のままにすると `sourceLocations(at:)` が空を返し、
        // どんな `colorGrades` を渡しても `.identity` へ落ちて grade が一切効かない**
        // （このテストで最初に踏んだ罠。`mapping` は必ずクリップ付きで渡すこと）。
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1.0)
        let mapping = TimelineMapping(clips: [clip])

        let gradedExporter = try makeExporter()
        let gradedURL = try await gradedExporter.export(
            asset: asset, mapping: mapping,
            colorGrades: [clip.id: extremeGrade], needsWatermark: true
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: gradedURL) }

        let plainExporter = try makeExporter()
        let plainURL = try await plainExporter.export(
            asset: asset, mapping: mapping, needsWatermark: true
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: plainURL) }

        // テスト前提の対照: 透かし**なし**の書き出し。これが無いと、透かしが焼かれなく
        // なった日にこのテストは「差が無い＝合格」で素通りしてしまう。
        let noWatermarkExporter = try makeExporter()
        let noWatermarkURL = try await noWatermarkExporter.export(
            asset: asset, mapping: mapping
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: noWatermarkURL) }

        let graded = try rawFramePixels(url: gradedURL, at: 0.5)
        let plain = try rawFramePixels(url: plainURL, at: 0.5)
        let noWatermark = try rawFramePixels(url: noWatermarkURL, at: 0.5)

        // 右下 1/4（透かしの位置。`ExportWatermark` の doc 参照）を比較する。
        // ⚠️ `cropped` の戻り値をそのまま使うこと。切り出した画素配列に**元の**
        // width/height を付けた `RawFrame` を組み直すと、`significantDiffPositions` が
        // 元サイズで走査して配列外参照（Index out of range）でクラッシュする。
        let gradedCrop = cropped(graded, xRange: (graded.width / 2)..<graded.width,
                                 yRange: (graded.height / 2)..<graded.height)
        let plainCrop = cropped(plain, xRange: (plain.width / 2)..<plain.width,
                                yRange: (plain.height / 2)..<plain.height)
        XCTAssertGreaterThan(gradedCrop.width * gradedCrop.height, 0,
                             "テスト前提: 透かし領域の切り出しが空になっている")
        // 対照: 透かしの無い左上 1/4。ここが動いていれば「透かしが補正を受けた」ではなく
        // 「不動点が符号化往復で崩れて画面全体が動いた」＝測り方の問題だと分かる。
        let controlGraded = cropped(graded, xRange: 0..<(graded.width / 2), yRange: 0..<(graded.height / 2))
        let controlPlain = cropped(plain, xRange: 0..<(plain.width / 2), yRange: 0..<(plain.height / 2))
        print("[COLORGRADE] watermark control(左上)=[\(diffProfile(controlGraded, controlPlain))]")

        // テスト前提: そもそも透かしがこの領域に焼かれていること。
        let noWatermarkCrop = cropped(noWatermark, xRange: (noWatermark.width / 2)..<noWatermark.width,
                                      yRange: (noWatermark.height / 2)..<noWatermark.height)
        let watermarkPixels = significantDiffPositions(plainCrop, noWatermarkCrop, channelDiffThreshold: 60)
        print("[COLORGRADE] watermark 焼き込み画素数=\(watermarkPixels.count)")
        XCTAssertGreaterThan(watermarkPixels.count, 100,
                             "テスト前提: 右下 1/4 に透かしが焼き込まれていない")

        // しきい値 60（3 チャンネルの絶対差の和 = 1 チャンネルあたり 20）の根拠（実測）:
        // - 透かしの無い左上 1/4 は**全しきい値で差 0**（不動点が保たれている）。
        // - 透かし領域の差はしきい値 10 で 155 画素、20 で 47、40 で 5、**60 で 0**。
        //   すなわち差の実体は 1 チャンネルあたり 20 未満の微小値で、透かしの
        //   高周波エッジを含むマクロブロックで H.264 の量子化判断が変わったもの
        //   （平坦な左上では量子化が同じ値へ丸めるので差が出ない）。
        // - 一方、**本当に壊れたとき**（透かしを補正より前に重ねてしまったとき）の差は
        //   桁が違う: 背景 0.5 に 50% で載る白は 0.75 になり、contrast=2.0 が
        //   (0.75-0.5)*2+0.5 = 1.0 へ押し上げるので 1 チャンネルあたり 64（和 192）が
        //   グリフ全体（上の実測で 100 画素超）に出る。60 はこの 2 つの間にある。
        let diffPositions = significantDiffPositions(gradedCrop, plainCrop, channelDiffThreshold: 60)

        print("[COLORGRADE] watermark diffPositions=\(diffPositions.count) "
              + "profile=[\(diffProfile(gradedCrop, plainCrop))] area=\(gradedCrop.width * gradedCrop.height)")
        XCTAssertLessThanOrEqual(diffPositions.count, 20,
                                 "透かし領域の画素が色調補正の有無で変わっている"
                                     + "（透かしが補正の影響を受けてはならない）")
    }

    /// `averageRGB` と同じ座標規約で矩形を切り出し、新しい密な `RawFrame` として返す。
    private func cropped(_ frame: RawFrame, xRange: Range<Int>, yRange: Range<Int>) -> RawFrame {
        let w = min(xRange.upperBound, frame.width) - xRange.lowerBound
        let h = min(yRange.upperBound, frame.height) - yRange.lowerBound
        guard w > 0, h > 0 else { return RawFrame(width: 0, height: 0, pixels: []) }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let srcOffset = ((y + yRange.lowerBound) * frame.width + (x + xRange.lowerBound)) * 4
                let dstOffset = (y * w + x) * 4
                pixels[dstOffset] = frame.pixels[srcOffset]
                pixels[dstOffset + 1] = frame.pixels[srcOffset + 1]
                pixels[dstOffset + 2] = frame.pixels[srcOffset + 2]
                pixels[dstOffset + 3] = frame.pixels[srcOffset + 3]
            }
        }
        return RawFrame(width: w, height: h, pixels: pixels)
    }

    // MARK: - 5) 検出は補正前を見ている

    /// `contrast = 0`（一面グレーへ潰す）を掛けた状態で書き出すと、検出（`SpyBrightnessLandmarker`）
    /// へ渡される画像の平均輝度は**元素材の輝度のまま**であること（潰れた 127 付近になって
    /// いたら、検出が補正後の画像を見ている＝顔検出が壊れる致命的な欠陥）。
    func test_detectionSeesPreGradeBuffer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 中間グレー（127付近）から離れた、はっきりした色にする
        // （補正で潰れた場合の 127 と混同しないため）。
        let sourceR: UInt8 = 40
        let sourceURL = try await makeFlatColorVideo(seconds: 1.0, r: sourceR, g: 210, b: 40)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)

        let flattenGrade = ColorGrade(brightness: 0, contrast: 0, saturation: 1, warmth: 0)
        // `mapping` は必ずクリップ付きで渡す（`test_watermarkUnaffectedByColorGrade` の
        // doc 参照。空のままだと `colorGrades` が一切参照されず grade が効かない）。
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1.0)
        let mapping = TimelineMapping(clips: [clip])
        let spy = SpyBrightnessLandmarker()
        let exporter = try makeExporter(landmarker: spy)
        // ⚠️ `applyRanges` を渡さないと **モザイク適用区間ゲートが全区間 OFF** になり
        //（既定の空は「適用なし」。`VideoMosaicExporter.export` の doc 参照）、
        // `refreshDetection` 自体が 1 度も呼ばれない = スパイが何も記録できない。
        // クリップ付きの `mapping` を渡した時点でゲートはフェイルオープンしないので、
        // 全区間カバーを明示すること。
        let applyRanges = MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [])
        let outURL = try await exporter.export(
            asset: asset, mapping: mapping, applyRanges: applyRanges,
            colorGrades: [clip.id: flattenGrade]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        // テスト前提: 補正が**実際に効いている**こと。効いていなければ「検出が補正前を
        // 見ている」は自明に成立してしまい、このテストは何も守らない。
        // contrast=0 は `ColorGrade.apply` の定義上どの入力も厳密に 0.5 へ潰す。
        let outFrame = try rawFramePixels(url: outURL, at: 0.5)
        let outAvg = averageRGB(outFrame, xRange: 0..<outFrame.width, yRange: 0..<outFrame.height)
        print("[COLORGRADE] detection outAvg=\(outAvg)")
        for channel in [outAvg.r, outAvg.g, outAvg.b] {
            // 127.5 ±20 は H.264 往復のずれ（実測で 10 前後）を見込んだ幅。
            XCTAssertEqual(channel, 127.5, accuracy: 20.0,
                           "テスト前提: contrast=0 の補正が書き出しに効いていない"
                               + "（出力が中間グレーへ潰れていない）: \(outAvg)")
        }

        let observed = try XCTUnwrap(spy.meanBrightness,
                                     "検出が一度も呼ばれていない（テストの前提が崩れている）")
        // 期待輝度（sRGB エンコード済みの単純平均。B チャンネルの寄与は無視できないほど
        // 大きくないので R チャンネルの生値に近い値になる）は元素材の R=40 に近いはず。
        // 補正後（contrast=0）を見ていれば 127 付近に張り付く。
        print("[COLORGRADE] detection observed meanBrightness(R)=\(observed) source R=\(sourceR)")
        XCTAssertLessThan(observed, 100,
                          "検出へ渡された画像の輝度が中間グレー(127)付近に寄っている。"
                              + "検出が色調補正**後**のバッファを見ている疑い"
                              + "（観測値=\(observed)）。これは顔検出が壊れる致命的な欠陥。")
    }

    // MARK: - 6) ツールバーの項目数

    /// クリップ選択時のツールバー項目（ズームを除く）が 7 個以下であること。
    /// 「分割 / 複製 / フィルター / 速度 / 変形 / 音量 / 削除」の 7 個に収まっている
    /// はずで、8 個目を足していないことをここで固定する。
    @MainActor
    func test_toolbarShowsAtMostSevenItemsWhenClipSelected() throws {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1.0)
        model.timeline = TimelineState(clips: [clip])
        model.timelineSelection.selectClip(clip.id)

        let view = VideoTimelineView(model: model)
        let items = view.selectionToolItems
        print("[COLORGRADE] toolbar items=\(items.map(\.title))")
        XCTAssertLessThanOrEqual(items.count, 7,
                                 "クリップ選択時のツールバー項目が 7 個を超えている: "
                                     + "\(items.map(\.title))")
    }

    /// **プレビューと書き出しが同じ実装で色を決めていることの番人。**
    ///
    /// 書き出し（`VideoMosaicExporter`）は `TimelineState` を持たず
    /// `[clipID: ColorGrade]` だけを持つため、あちらの
    /// `TimelineState.colorGrade(atComposition:)` をそのままは呼べない。**そこで
    /// 手順を書き写すと、片方だけ変わって黙ってずれる**——この案件が繰り返してきた
    /// 事故の形（音程アルゴリズム／逆写像の向き）そのものになる。
    ///
    /// いまは `ColorGradeResolver.resolve` を両者が通る形にしてあるので、
    /// **同じ入力に対して同じ値**が出るはずである。トランジションの重なり
    /// （`progress` による補間）を含む時刻で突き合わせる。ここが落ちたら、
    /// どちらかが独自実装へ戻った合図。
    @MainActor
    func test_プレビューと書き出しが同じ色調補正を返す() throws {
        let sourceA = UUID()
        let sourceB = UUID()
        var gradeA = ColorGrade()
        gradeA.brightness = 0.6
        gradeA.warmth = 0.4
        var gradeB = ColorGrade()
        gradeB.contrast = 1.8
        gradeB.saturation = 0.2

        var clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        clipA.colorGrade = gradeA
        var clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        clipB.colorGrade = gradeB

        // 境界にトランジションを置き、重なり（progress 補間）を必ず通す。
        let state = TimelineState(clips: [clipA, clipB])
            .settingTransition(afterClipID: clipA.id, kind: .crossfade, duration: 1)
        XCTAssertFalse(state.mapping.overlaps.isEmpty, "テスト前提: 重なりが作られていること")

        // 書き出し側と同じ保持形（辞書）で、同じ解決器を呼ぶ。
        var grades: [UUID: ColorGrade] = [:]
        for clip in state.clips { grades[clip.id] = clip.colorGrade }

        let total = state.mapping.totalDuration
        for step in 0...40 {
            let t = total * Double(step) / 40
            let previewSide = state.colorGrade(atComposition: t)
            let exportSide = ColorGradeResolver.resolve(mapping: state.mapping, at: t) { id in
                grades[id] ?? .identity
            }
            XCTAssertEqual(previewSide, exportSide,
                           "合成時刻 \(t) でプレビューと書き出しの色調補正が違う"
                           + "（どちらかが独自実装へ戻った疑い）")
        }
    }
}
#endif
