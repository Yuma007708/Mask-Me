import XCTest
import AVFoundation
import CoreVideo
import VideoToolbox

/// 動画エクスポートの支配的コストである **HEVC エンコードのスループット（fps）** を、
/// **この Mac の HW メディアエンジン**で実測する。
///
/// Simulator 実測（`App/MaskMeTests/ExportSpeedMeasurementTests`）では
/// キャッシュヒット経路のコストの **97% が HEVC ソフトウェアエンコード待ち**（decode/detect/render は 3%）。
/// Simulator に HW ビデオエンコーダが無いためソフト実行になり 10fps に落ちる。
///
/// 実機（Apple Silicon iPhone）と同世代の HW HEVC エンコーダはこの Mac（Apple Silicon）にもある。
/// AVFoundation の HEVC エンコードは Apple Silicon Mac 上で HW メディアエンジンを使うため、
/// ここで測る fps は**実機のエンコード段のオーダーを代表する**（Metal 不要・`swift test` で走る）。
/// 自作ピクセル（良性）を 1080p で N フレーム流し込み、5分（9000f）へ線形外挿する。
final class EncodeThroughputTests: XCTestCase {
    private let fps: Int32 = 30
    private let width = 1920
    private let height = 1080
    private let measured = 300         // 実測フレーム数（10秒相当）
    private let projectFrames = 9000   // 外挿先（5分 @30fps）

    func testHEVCEncodeThroughputAndFiveMinuteProjection() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = Int(Double(width) * Double(height) * 0.15 * 30)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw XCTSkip("HEVC エンコード非対応環境ではスキップ")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw XCTSkip("writer に input を追加できない") }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // 数枚のパターンを使い回す（毎フレーム生成のコストを計測から除く）。
        var patterns: [CVPixelBuffer] = []
        for p in 0..<8 {
            if let b = makePatternBuffer(pool: adaptor.pixelBufferPool, seed: p) { patterns.append(b) }
        }
        guard !patterns.isEmpty else { throw XCTSkip("パターンバッファ生成に失敗") }

        let queue = DispatchQueue(label: "enc")
        let done = XCTestExpectation(description: "encode-write")
        var frame = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if frame >= self.measured { input.markAsFinished(); done.fulfill(); return }
                let pts = CMTime(value: CMTimeValue(frame), timescale: self.fps)
                adaptor.append(patterns[frame % patterns.count], withPresentationTime: pts)
                frame += 1
            }
        }
        wait(for: [done], timeout: 120)
        let finish = XCTestExpectation(description: "encode-finish")
        writer.finishWriting { finish.fulfill() }
        wait(for: [finish], timeout: 60)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        let encFps = elapsed > 0 ? Double(measured) / elapsed : 0
        let projected = encFps > 0 ? Double(projectFrames) / encFps : .infinity

        print(String(format:
            "[MMENC] %dx%d HEVC frames=%d elapsed=%.2fs bytes=%d(%.1fMB) → HWエンコード=%.0f fps",
            width, height, measured, elapsed, bytes, Double(bytes) / 1_048_576, encFps))
        print(String(format:
            "[MMENC] 5分(9000f)エンコードの外挿=%.1f秒（この Mac の HW メディアエンジン＝実機同世代）",
            projected))
        print(String(format:
            "[MMENC] 判定: 目標30-60秒。エンコード外挿=%.1f秒。%@",
            projected, projected <= 60 ? "→ エンコード単体は目標圏内" : "→ エンコードだけで目標超過"))

        XCTAssertEqual(writer.status, .completed, "HEVC エンコードが完了していない")
        XCTAssertGreaterThan(bytes, 0, "出力が空＝エンコード未実行")
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
}
