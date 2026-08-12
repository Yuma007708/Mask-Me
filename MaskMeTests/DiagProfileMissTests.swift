import AVFoundation
import Metal
import MosaicCore
import UIKit
import XCTest
@testable import MaskMe

/// **診断**（合否の門番ではない）: `profile.mov` で検出が落ちる 4/24 フレームが
/// 「何の条件で」落ちているかを特定する。
///
/// `RealFaceMosaicTests` が `scanned=24 detected=20` を出しているが、どのフレームが
/// 落ちたのか・何をすれば拾えるのかは分からない。ここは**打ち手を決めるための計測**で、
/// 数字を print するだけで基本的に落ちない（素材が無ければ skip）。
///
/// 落ちたフレームに対して、既存の梯子（補助検出器・拡大・逆光補正・低 confidence
/// 全画面再走査）が通った**後**で、さらに次の変換を掛けて拾えるかを見る:
///
/// - **面内回転**（±20°/±40°）— MediaPipe の顔検出器は面内回転（roll）に弱い。
///   横向きで頭が傾くと、正面顔でも落ちる。既存の梯子に回転は入っていない。
/// - **全画面 2 倍拡大** — `upscaledIfSmall` は ROI crop に掛かるもので、
///   ROI が取れない（＝bbox が出ない）フレームには効かない。
///
/// どの変換が効くかで打ち手が決まる: 回転が効くなら回転リトライを梯子へ足す価値があり、
/// どれも効かないならフレーム自体に顔の手がかりが無い（＝検出器の限界）ので、
/// 検出を厚くするのではなく前後フレームからの橋渡し（`DetectionBridge`）で埋める話になる。
final class DiagProfileMissTests: XCTestCase {
    func test_Diag_profileMissFrameCauses() async throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let src = FixtureLoader.videoURL(named: "profile") else {
            throw XCTSkip("Fixtures/profile.mov がありません")
        }

        let asset = AVURLAsset(url: src)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // 素の走査（`RealFaceMosaicTests` と同じ条件・同じ既定設定）。
        let scanner = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)

        var missTimes: [Double] = []
        var scanned = 0
        var detected = 0
        var time = 0.0
        while time < duration {
            defer { time += 0.25 }
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600),
                                                      actualTime: nil) else { continue }
            scanned += 1
            let image = UIImage(cgImage: cg)
            if scanner.landmarks(in: image, timestampMs: Int(time * 1000)) != nil {
                detected += 1
            } else {
                missTimes.append(time)
            }
        }
        print("[DIAG-MISS] scanned=\(scanned) detected=\(detected) miss=\(missTimes.count) "
              + "times=\(missTimes.map { String(format: "%.2f", $0) }.joined(separator: ","))")

        guard !missTimes.isEmpty else {
            print("[DIAG-MISS] 落ちるフレームが無い（素材か環境が変わった可能性）")
            return
        }

        // **落ちたフレームだけ**を対象に、変換を掛けて拾えるかを見る。
        // 走査本体（VIDEO モード）は時刻の連続性を仮定するので、ここは IMAGE モードの
        // 別インスタンスを使う（同じ時刻へ戻ると VIDEO モードは無視することがある）。
        let prober = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .image)
        for missTime in missTimes {
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: missTime,
                                                                preferredTimescale: 600),
                                                      actualTime: nil) else { continue }
            let image = UIImage(cgImage: cg)
            var rescued: [String] = []
            if prober.landmarks(in: image) != nil { rescued.append("IMAGEモードのみ") }
            for degrees in [-40.0, -20.0, 20.0, 40.0] {
                guard let rotated = Self.rotated(image, degrees: degrees) else { continue }
                if prober.landmarks(in: rotated) != nil {
                    rescued.append(String(format: "回転%+.0f°", degrees))
                }
            }
            if let scaled = Self.scaled(image, factor: 2), prober.landmarks(in: scaled) != nil {
                rescued.append("2倍拡大")
            }
            print(String(format: "[DIAG-MISS] t=%.2f size=%.0fx%.0f 救済=%@",
                         missTime, image.size.width, image.size.height,
                         rescued.isEmpty ? "どれも効かない" : rescued.joined(separator: "/")))
            dump(image, name: String(format: "miss-%.2f", missTime))
        }

        // **比較用に、直前の「検出できたフレーム」も出す。** 落ちたフレームだけを見ても
        // 「顔が写っているのに落ちた」のか「そもそも顔が居ない」のか判断できない。
        if let first = missTimes.first, first >= 0.25,
           let cg = try? generator.copyCGImage(at: CMTime(seconds: first - 0.25,
                                                          preferredTimescale: 600),
                                               actualTime: nil) {
            dump(UIImage(cgImage: cg), name: String(format: "hit-%.2f", first - 0.25))
        }
    }

    /// **診断**: 検出が落ちる末尾区間が、書き出しで実際に素通しになっているか。
    ///
    /// コードを読む限り `DetectionBridge` は片側にしか検出が無いと空を返すので
    /// （`guard let before, let after else { return [] }`）、動画の末尾の抜けは
    /// 埋まらないはずである。だが**モザイクの有無はコードの読みではなく書き出しの
    /// 実測で決める**（この案件の規則: プレビューで隠れて見えることを書き出しの
    /// 安全の根拠にしてはならない）ので、実際に書き出して顔の場所の平坦さを測る。
    ///
    /// 指標は全変動（TV）。モザイクが掛かっていれば平坦（小さい）、素通しなら
    /// 元の絵の細かさがそのまま残る（大きい）。
    func test_Diag_tailGapIsActuallyExposedInExport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let src = FixtureLoader.videoURL(named: "profile") else {
            throw XCTSkip("Fixtures/profile.mov がありません")
        }

        let asset = AVURLAsset(url: src)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: duration)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: asset], isPro: true).composition
        let mapping = TimelineMapping(clips: clips)

        // **全区間にモザイクを掛けて書き出す。** 区間の外だから掛からない、という
        // 説明が成り立たない条件にしておく。
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        let exporter = VideoMosaicExporter(
            renderer: renderer,
            landmarker: try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video))
        let outURL = try await exporter.export(
            asset: composition, mapping: mapping,
            applyRanges: [MosaicApplyRange(clipID: clips[0].id, sourceID: sourceID,
                                           sourceStart: 0, sourceEnd: duration)]) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 顔の位置は「検出できた最後のフレーム」のものを使う。
        // 落ちた区間でも顔はほぼ同じ場所に居る（書き出したフレームで確認済み）。
        //
        // **VIDEO モードで頭から走らせて取る。** この素材の 4.75s は時間的追従
        // （直前フレームの ROI）があって初めて取れる顔で、IMAGE モード単体では
        // 落ちる（`test_Diag_profileMissFrameCauses` の「IMAGEモードのみ」が
        // 一度も救済に出てこないのがその証拠）。時刻を飛ばして 1 枚だけ渡すと
        // 基準が取れない。
        let scanner = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var lastRect: CGRect?
        var scanTime = 0.0
        while scanTime < duration {
            defer { scanTime += 0.25 }
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: scanTime,
                                                                 preferredTimescale: 600),
                                                      actualTime: nil),
                  let set = scanner.landmarks(in: UIImage(cgImage: cg),
                                              timestampMs: Int(scanTime * 1000))
            else { continue }
            let xs = set.points.map { CGFloat($0.x) }
            let ys = set.points.map { CGFloat($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }
            lastRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let rect = try XCTUnwrap(lastRect, "走査で 1 フレームも顔が取れない")
        // 輪郭の外を混ぜると背景の平坦さで指標が鈍るので、中心 60% だけ見る。
        let core = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)

        var buckets: [(label: String, values: [Double])] = []
        var detectedSide: [Double] = []
        var gapSide: [Double] = []
        for frame in try await luminanceFrames(of: outURL) {
            let (pixels, width) = patch(frame, rect: core)
            let variation = totalVariation(pixels, width: width)
            guard variation.isFinite else { continue }
            if frame.pts >= 3.0, frame.pts <= 4.75 { detectedSide.append(variation) }
            if frame.pts >= 5.05 { gapSide.append(variation) }
        }
        // **対照（素の素材）。** 書き出し後の数字だけでは「小さい＝モザイク」と
        // 言い切れない（背景が平坦な壁なので、顔から外れた場所を測っても小さく出る）。
        // 同じ矩形を素の素材で測り、モザイク前後の差として読む。
        var rawDetectedSide: [Double] = []
        var rawGapSide: [Double] = []
        for frame in try await luminanceFrames(of: src) {
            let (pixels, width) = patch(frame, rect: core)
            let variation = totalVariation(pixels, width: width)
            guard variation.isFinite else { continue }
            if frame.pts >= 3.0, frame.pts <= 4.75 { rawDetectedSide.append(variation) }
            if frame.pts >= 5.05 { rawGapSide.append(variation) }
        }
        buckets.append(("素材(素) 3.0-4.75s", rawDetectedSide))
        buckets.append(("素材(素) 5.05s-末尾", rawGapSide))
        buckets.append(("書き出し 3.0-4.75s", detectedSide))
        buckets.append(("書き出し 5.05s-末尾", gapSide))
        for bucket in buckets where !bucket.values.isEmpty {
            let mean = bucket.values.reduce(0, +) / Double(bucket.values.count)
            print(String(format: "[DIAG-TAIL] %@ frames=%d TV平均=%.3f 最大=%.3f",
                         bucket.label, bucket.values.count, mean,
                         bucket.values.max() ?? .nan))
        }
    }

    // MARK: - 計測の道具（`RealFaceMosaicTests` の private と同じ計算）

    private func totalVariation(_ pixels: [UInt8], width: Int) -> Double {
        guard width > 1, pixels.count >= width * 2 else { return .nan }
        let height = pixels.count / width
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            for x in 1..<width {
                sum += abs(Double(pixels[y * width + x]) - Double(pixels[y * width + x - 1]))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : .nan
    }

    private func luminanceFrames(of url: URL) async throws
    -> [(pts: Double, plane: [UInt8], width: Int, height: Int)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()

        var frames: [(pts: Double, plane: [UInt8], width: Int, height: Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            var plane = [UInt8](repeating: 0, count: width * height)
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<height {
                    for x in 0..<width {
                        plane[y * width + x] = base[y * bytesPerRow + x * 4]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append((pts, plane, width, height))
        }
        return frames
    }

    private func patch(_ frame: (pts: Double, plane: [UInt8], width: Int, height: Int),
                       rect: CGRect) -> (pixels: [UInt8], width: Int) {
        let x0 = max(0, Int(rect.minX * CGFloat(frame.width)))
        let x1 = min(frame.width, Int(rect.maxX * CGFloat(frame.width)))
        let y0 = max(0, Int(rect.minY * CGFloat(frame.height)))
        let y1 = min(frame.height, Int(rect.maxY * CGFloat(frame.height)))
        guard x1 > x0, y1 > y0 else { return ([], 0) }
        var pixels: [UInt8] = []
        pixels.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 { pixels.append(frame.plane[y * frame.width + x]) }
        }
        return (pixels, x1 - x0)
    }

    /// 目で確かめるためにフレームを書き出す。パスを print するので host 側から開ける。
    private func dump(_ image: UIImage, name: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jpg")
        try? data.write(to: url)
        print("[DIAG-MISS] dumped \(url.path)")
    }

    /// 面内回転。回転で画が切れないよう、外接矩形いっぱいに描く。
    private static func rotated(_ image: UIImage, degrees: Double) -> UIImage? {
        let radians = CGFloat(degrees * .pi / 180)
        let size = image.size
        let bounds = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: bounds, format: format).image { context in
            context.cgContext.translateBy(x: bounds.width / 2, y: bounds.height / 2)
            context.cgContext.rotate(by: radians)
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2,
                                  width: size.width, height: size.height))
        }
    }

    private static func scaled(_ image: UIImage, factor: CGFloat) -> UIImage? {
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
