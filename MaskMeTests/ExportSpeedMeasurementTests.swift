import XCTest
import AVFoundation
import CoreVideo
import MosaicCore
@testable import MaskMe

#if canImport(Metal)

/// Simulator 上で「キャッシュヒット経路の実効エクスポート fps」を **出力検証付き** で実測する。
///
/// 実機で目標が最も達成しやすい経路＝「プレビュー済み → 検出キャッシュ満杯 → エクスポート」を
/// 再現する。合成 1080p 動画（自作ピクセル・良性）に密な detectionCache（合成ランドマーク）を
/// 与えて `VideoMosaicExporter.export(speed: .fast)` を回す。全時刻キャッシュヒットで MediaPipe は
/// 走らないため、測るのは「デコード＋Metalモザイク描画＋HEVC再エンコード」の実効 fps。
///
/// 合成尺は短く（15秒＝450フレーム）してマシン負荷の影響を抑え、fail-fast タイムアウトで
/// ハングを避ける。export はフレーム数に対して線形なので fps から 5分（9000フレーム）を外挿する。
/// 出力フレーム数を実デコードして検証し、encode が実際に走ったことを保証する。
///
/// ## ⚠️ Simulator の数字で最適化の当否を決めないこと
///
/// 2026-07-29 に同一条件を Simulator と実機（iPhone 17）で測ったところ、**律速が真逆**だった。
///
/// | | Simulator | 実機 |
/// |---|---|---|
/// | 実効 fps | 4 | 148 |
/// | render（モザイク描画） | 2% | 51% |
/// | other/encode | 98% | 37% |
///
/// Simulator は VideoToolbox がソフトウェア実行なので encode が全体を覆い隠す。
///
/// さらに実機で「毎フレームの GPU 完了待ちを 1 フレーム遅延パイプラインで隠す」改修を試したが、
/// render は 51% → 14% に落ちたのに **wall は 2.9s のまま 1 秒も変わらなかった**。
/// 待ち場所が `adaptor.append` へ移っただけで、真の律速は **HW エンコーダのスループット**。
/// 1080p で 148 fps は HW エンコーダとして妥当な水準で、ここを速くするには解像度か
/// エンコード設定を変えるしかない。**同じ改修を再度作らないこと。**
final class ExportSpeedMeasurementTests: XCTestCase {
    private let fps: Int32 = 30
    private let width = 1920
    private let height = 1080
    private let synthSeconds = 15          // 合成尺（短く・負荷影響を抑える）
    private let projectFrames = 9000       // 外挿先（5分 @30fps）

    func testCacheHitExportThroughputAndFiveMinuteProjection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        let videoURL = try makeSyntheticVideo(seconds: synthSeconds)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let asset = AVURLAsset(url: videoURL)
        let cache = makeDenseDetectionCache(seconds: synthSeconds)
        // S4 で exporter は「素材IDごとのキャッシュ辞書＋写像」を受け取る。素の
        // AVAsset を書き出す本テストでは「素材全体 1 クリップ」の恒等写像を渡す
        // （全時刻キャッシュヒットの前提を維持する）。
        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: Double(synthSeconds))]
        let mapping = TimelineMapping(clips: clips)
        // ⚠️ `applyRanges` の既定の空は「適用なし（全区間 OFF）」。クリップを持つ写像を渡すと
        // ゲートはフェイルオープンしないので、ここを省くと**モザイクを 1 フレームも掛けずに**
        // 速度を測ることになる（実際そうなっていた）。全区間適用を明示する。
        let applyRanges = MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs: [])

        let exporter = VideoMosaicExporter(renderer: renderer, landmarker: NullFaceLandmarker())
        let exp = expectation(description: "export")
        var exportSec = 0.0
        var outURL: URL?
        Task {
            let t0 = CFAbsoluteTimeGetCurrent()
            outURL = try? await exporter.export(
                asset: asset, selectedFaceTargets: [], manualRegions: [],
                detectionCaches: [sourceID: cache], mapping: mapping,
                applyRanges: applyRanges, faceEnabled: true,
                backgroundEnabled: false, backgroundBlock: 28, speed: .fast
            ) { _ in }
            exportSec = CFAbsoluteTimeGetCurrent() - t0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 180)

        // 出力検証（encode が実際に走った証明）。
        var outFrames = 0
        var outBytes = 0
        var faceRoughness: Double?
        var plainRoughness: Double?
        if let outURL {
            outBytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? Int) ?? 0
            outFrames = (try? countFrames(in: AVURLAsset(url: outURL))) ?? 0
            // **モザイクが実際に焼き込まれたかを測る。** ここを見ていなかったため、
            // `applyRanges` の渡し忘れで全区間 OFF になっていても速度テストが通っていた。
            let measured = try? measureRoughness(in: AVURLAsset(url: outURL))
            faceRoughness = measured?.face
            plainRoughness = measured?.plain
            try? FileManager.default.removeItem(at: outURL)
        }

        let inFrames = synthSeconds * Int(fps)
        let expFps = exportSec > 0 ? Double(outFrames) / exportSec : 0
        let projected = expFps > 0 ? Double(projectFrames) / expFps : .infinity

        print(String(format:
            "[MMSPEED] synth=%ds inFrames=%d exportSec=%.2f outFrames=%d bytes=%d(%.1fMB)",
            synthSeconds, inFrames, exportSec, outFrames, outBytes, Double(outBytes) / 1_048_576))
        print(String(format:
            "[MMSPEED] 実効fps=%.0f → 5分(9000f)加工の外挿=%.1f秒（キャッシュヒット経路・検出ゼロ）",
            expFps, projected))
        print(String(format:
            "[MMSPEED] 判定: 目標30-60秒。外挿=%.1f秒。%@",
            projected, projected <= 60 ? "→ 目標圏内" : "→ 目標超過"))

        // encode が走ったこと（出力が入力の9割以上）を保証。
        XCTAssertGreaterThan(outFrames, inFrames * 9 / 10, "出力フレーム不足=encode未実行の疑い")

        // モザイクが焼き込まれたことを保証。合成動画は一様なグラデーションなので、
        // 顔領域だけブロック化されれば隣接画素差（粗さ）がはっきり下がる。
        let face = try XCTUnwrap(faceRoughness, "出力からフレームを取り出せなかった")
        let plain = try XCTUnwrap(plainRoughness)
        print(String(format: "[MMSPEED] 粗さ 顔領域=%.2f 顔外=%.2f", face, plain))
        XCTAssertLessThan(face, plain * 0.5,
                          "顔領域にモザイクが焼き込まれていない（applyRanges の渡し忘れを疑う）")
    }

    /// 出力の中盤フレームから、顔領域と顔外領域の「隣接画素差の平均」を返す。
    /// モザイクが掛かった領域はブロック内が平坦になるのでこの値が下がる。
    private func measureRoughness(in asset: AVAsset) throws -> (face: Double, plain: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try generator.copyCGImage(
            at: CMTime(seconds: Double(synthSeconds) / 2, preferredTimescale: 600), actualTime: nil)

        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "roughness", code: 1)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 合成顔メッシュは正規化 x 0.35〜0.65 / y 0.30〜0.65 に置いてある（makeSyntheticFace）。
        // 顔外は右下の余白から取る。
        func roughness(x0: Double, y0: Double, x1: Double, y1: Double) -> Double {
            let xs = Int(x0 * Double(w)), xe = Int(x1 * Double(w))
            let ys = Int(y0 * Double(h)), ye = Int(y1 * Double(h))
            var total = 0.0
            var count = 0
            for y in ys..<ye where y + 1 < h {
                for x in xs..<xe where x + 1 < w {
                    let i = (y * w + x) * 4
                    let right = (y * w + x + 1) * 4
                    let down = ((y + 1) * w + x) * 4
                    total += abs(Double(pixels[i]) - Double(pixels[right]))
                    total += abs(Double(pixels[i]) - Double(pixels[down]))
                    count += 2
                }
            }
            return count > 0 ? total / Double(count) : 0
        }
        return (face: roughness(x0: 0.42, y0: 0.38, x1: 0.58, y1: 0.58),
                plain: roughness(x0: 0.75, y0: 0.75, x1: 0.95, y1: 0.95))
    }

    // MARK: - 出力フレーム計数

    private func countFrames(in asset: AVAsset) throws -> Int {
        guard let track = awaitTrack(asset) else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        reader.startReading()
        var count = 0
        while reader.status == .reading, output.copyNextSampleBuffer() != nil { count += 1 }
        return count
    }

    private func awaitTrack(_ asset: AVAsset) -> AVAssetTrack? {
        let sem = DispatchSemaphore(value: 0)
        var result: AVAssetTrack?
        Task {
            result = try? await asset.loadTracks(withMediaType: .video).first
            sem.signal()
        }
        sem.wait()
        return result
    }

    // MARK: - 合成動画（自作ピクセル・良性）

    private func makeSyntheticVideo(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synth-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw NSError(domain: "synth", code: 1) }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var patterns: [CVPixelBuffer] = []
        for p in 0..<8 {
            if let b = makePatternBuffer(pool: adaptor.pixelBufferPool, seed: p) { patterns.append(b) }
        }
        guard !patterns.isEmpty else { throw NSError(domain: "synth", code: 2) }

        let total = seconds * Int(fps)
        let queue = DispatchQueue(label: "synth")
        let done = XCTestExpectation(description: "synth-write")
        var frame = 0
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if frame >= total { input.markAsFinished(); done.fulfill(); return }
                let pts = CMTime(value: CMTimeValue(frame), timescale: self.fps)
                adaptor.append(patterns[frame % patterns.count], withPresentationTime: pts)
                frame += 1
            }
        }
        wait(for: [done], timeout: 120)
        let finish = XCTestExpectation(description: "synth-finish")
        writer.finishWriting { finish.fulfill() }
        wait(for: [finish], timeout: 60)
        return url
    }

    private func makePatternBuffer(pool: CVPixelBufferPool?, seed: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = ptr + y * bpr
            for x in 0..<width {
                let i = x * 4
                let v = UInt8((x + y + seed * 37) & 0xFF)
                row[i] = v
                row[i + 1] = UInt8(v &+ 85)
                row[i + 2] = UInt8(v &+ 170)
                row[i + 3] = 255
            }
        }
        return buffer
    }

    // MARK: - 合成キャッシュ（密・全時刻ヒット）

    private func makeDenseDetectionCache(seconds: Int) -> [Double: [FaceLandmarkSet]] {
        let face = makeSyntheticFace()
        var cache: [Double: [FaceLandmarkSet]] = [:]
        let bucketFPS = 15.0
        for b in 0...Int(Double(seconds) * bucketFPS) {
            cache[Double(b) / bucketFPS] = [face]
        }
        return cache
    }

    private func makeSyntheticFace() -> FaceLandmarkSet {
        var pts: [FaceLandmark] = []
        pts.reserveCapacity(FaceLandmarkSet.fullMeshCount)
        let side = 22
        for i in 0..<FaceLandmarkSet.fullMeshCount {
            let gx = i % side, gy = i / side
            let nx = 0.35 + 0.30 * Float(gx) / Float(side - 1)
            let ny = 0.30 + 0.35 * Float(gy) / Float(side - 1)
            pts.append(FaceLandmark(x: nx, y: ny, z: 0))
        }
        return FaceLandmarkSet(points: pts, confidence: 0.99)
    }
}

#endif
