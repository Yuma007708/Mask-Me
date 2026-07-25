import XCTest
import AVFoundation
import Accelerate
import MosaicCore
import UIKit
@testable import MaskMe

#if canImport(Metal)
import Metal

/// S4: マルチクリップ実行系のエクスポート検証。
///
/// 分割・並べ替え・rate 変更したタイムラインの Composition を
/// `VideoMosaicExporter`（素材スコープの検出キャッシュ + 写像）で書き出し、
/// 完走することと出力尺が合成尺に一致することを実測で固定する。
final class MultiClipExportTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    // MARK: - テスト素材生成（外部ファイルに依存しない）

    /// 映像（H.264・単色）＋ 任意で音声（440Hz サイン波）を持つ動画を生成する。
    ///
    /// `audioAmplitude` は素材時刻 → 振幅（0...1）の関数。時刻ごとに音量を変えた素材を
    /// 作ることで、トリム書き出し後の RMS 解析で「どの素材区間の音が・出力のどこに
    /// 載ったか」を検証できる（音声全損・位置ずれの回帰ガード）。
    ///
    /// `audioChannels` に 6 を指定すると音声を 5.1ch（6ch・チャンネルレイアウト付き
    /// AAC）で書く。>2ch 素材（5.1ch 撮影動画等）の書き出し経路を再現するために使う。
    ///
    /// `audioSampleRate` はサンプルレート混在（48kHz 素材 + 44.1kHz 素材の連結）を
    /// 再現するために使う。
    private func makeTestVideo(
        seconds: Double, withAudio: Bool,
        audioAmplitude: @escaping (Double) -> Double = { _ in 1.0 },
        audioChannels: Int? = nil,
        audioSampleRate: Double = 44100.0
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let aIn: AVAssetWriterInput
            if let channels = audioChannels, channels > 2 {
                // >2ch は AVChannelLayoutKey が必須（無いと AVAssetWriterInput init が
                // ObjC 例外でクラッシュする — まさに本テストが exporter 側で防ぐ事故）。
                var layout = AudioChannelLayout()
                // AAC エンコーダが受け付ける 5.1 レイアウト（MPEG_5_1_A は
                // 「Channel layout is not valid for Format ID 'aac'」で拒否される）。
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
                let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVChannelLayoutKey: layoutData,
                    AVEncoderBitRateKey: 256_000
                ])
            } else {
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ])
            }
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            audioInput = aIn
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        if let audioInput {
            try appendSineAudio(to: audioInput, seconds: seconds,
                                channels: audioChannels ?? 1, sampleRate: audioSampleRate,
                                amplitude: audioAmplitude)
            audioInput.markAsFinished()
        }

        for i in 0..<Int(seconds * Double(fps)) {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 16bit 整数・インターリーブの LinearPCM フォーマット記述を作る
    /// （>2ch は 5.1ch のチャンネルレイアウトを付ける。6ch 前提）。
    private func makePCMFormat(channels: Int, sampleRate: Double = 44100.0) -> CMFormatDescription? {
        let bytesPerFrame = UInt32(2 * channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMFormatDescription?
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                           asbd: &asbd,
                                           layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                           layout: &layout,
                                           magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &format)
        } else {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                           asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        return format
    }

    /// 440Hz のサイン波を 1024 サンプルずつ書き込む（CompositionFidelityTests と同パターン）。
    /// `amplitude` で素材時刻ごとの音量（0...1）を変調する。
    /// `channels` > 1 のときは全チャンネルに同一波形をインターリーブで書く。
    private func appendSineAudio(to input: AVAssetWriterInput, seconds: Double,
                                 channels: Int = 1,
                                 sampleRate: Double = 44100.0,
                                 amplitude: (Double) -> Double = { _ in 1.0 }) throws {
        guard let format = makePCMFormat(channels: channels, sampleRate: sampleRate)
        else { return }

        let chunk = 1024
        let totalFrames = Int(seconds * sampleRate)
        var written = 0
        while written < totalFrames {
            let count = min(chunk, totalFrames - written)
            var samples = [Int16](repeating: 0, count: count * channels)
            for i in 0..<count {
                let t = Double(written + i) / sampleRate
                let value = Int16(sin(2 * .pi * 440 * t) * 12000 * amplitude(t))
                for channel in 0..<channels { samples[i * channels + channel] = value }
            }
            var block: CMBlockBuffer?
            let byteCount = count * 2 * channels
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
            guard let block else { break }
            _ = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: byteCount)
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(written),
                                              timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid)
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard let sample else { break }
            while !input.isReadyForMoreMediaData { usleep(1000) }
            input.append(sample)
            written += count
        }
    }

    private func fakeFace(cx: Double, cy: Double, size: Double = 0.2) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// 出力音声を PCM デコードし、指定時刻窓（出力タイムライン秒）の RMS を
    /// フルスケール比（0...1）で返す。窓内にサンプルが無ければ 0。
    ///
    /// 素材のサイン波（振幅 12000/32768 ≈ 0.366）が載っていれば RMS ≈ 0.26、
    /// 無音区間なら ≈ 0。閾値は AAC 境界のスミア（数 ms）を避けるため窓に
    /// 0.05s 以上のマージンを取って使うこと。
    private func audioRMS(url: URL, window: ClosedRange<Double>) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(out)
        reader.startReading()
        var sumSquares = 0.0
        var sampleCount = 0
        while let sample = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { continue }
            let sampleRate = asbd.mSampleRate
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0,
                                        lengthAtOffsetOut: &lengthAtOffset,
                                        totalLengthOut: &totalLength,
                                        dataPointerOut: &dataPointer)
            guard let dataPointer, lengthAtOffset == totalLength else { continue }
            let frameCount = totalLength / (2 * channels)
            dataPointer.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) { ptr in
                for frame in 0..<frameCount {
                    let t = start + Double(frame) / sampleRate
                    guard window.contains(t) else { continue }
                    let value = Double(ptr[frame * channels]) / 32768.0
                    sumSquares += value * value
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }

    // MARK: - S8 のテスト補助（縦動画・ピクセル検証）

    /// 4 象限を別色（TL 赤・TR 緑・BL 青・BR 白）で塗った映像を、
    /// `preferredTransform` に 90 度回転を持たせて書く（= 縦動画の再現）。
    ///
    /// 二重回転（writer と instruction の両方で回転を掛ける事故）は、出力の
    /// **表示サイズが横向きに戻る / 象限の色が入れ替わる**として現れるので、
    /// この素材の出力を「素材を正しく表示したときの絵」と突き合わせれば検出できる。
    private func makePortraitQuadrantVideo(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        // 縦動画（ポートレート撮影）の preferredTransform。
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
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
                // BGRA 順。TL 赤 / TR 緑 / BL 青 / BR 白。
                let colors: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255],
                                         [255, 0, 0, 255], [255, 255, 255, 255]]
                for y in 0..<height {
                    for x in 0..<width {
                        let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                        let color = colors[quadrant]
                        let offset = y * bytesPerRow + x * 4
                        base[offset] = color[0]
                        base[offset + 1] = color[1]
                        base[offset + 2] = color[2]
                        base[offset + 3] = color[3]
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

    /// `AVAssetImageGenerator`（`appliesPreferredTrackTransform = true` = 実際の見え方）で
    /// 1 フレーム取り出し、表示サイズと 4 象限の平均色（R,G,B）を返す。
    private func displayedQuadrants(url: URL, at seconds: Double) throws
    -> (size: CGSize, colors: [(r: Double, g: Double, b: Double)]) {
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
        var colors: [(r: Double, g: Double, b: Double)] = []
        for quadrant in 0..<4 {
            // 象限の中央 1/4 領域だけを平均する（境界のにじみを避ける）。
            let xRange = quadrant % 2 == 0 ? (w / 8)..<(3 * w / 8) : (5 * w / 8)..<(7 * w / 8)
            let yRange = quadrant / 2 == 0 ? (h / 8)..<(3 * h / 8) : (5 * h / 8)..<(7 * h / 8)
            var sum = (r: 0.0, g: 0.0, b: 0.0)
            var count = 0.0
            for y in yRange {
                for x in xRange {
                    let offset = (y * w + x) * 4
                    sum.r += Double(pixels[offset])
                    sum.g += Double(pixels[offset + 1])
                    sum.b += Double(pixels[offset + 2])
                    count += 1
                }
            }
            colors.append((sum.r / count, sum.g / count, sum.b / count))
        }
        return (CGSize(width: w, height: h), colors)
    }

    private func makeExporter() throws -> VideoMosaicExporter {
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        return VideoMosaicExporter(renderer: renderer, landmarker: NullFaceLandmarker())
    }

    // MARK: - テスト

    /// 分割して並べ替えた 2 クリップ（素材の後半 → 前半）のエクスポートが完走し、
    /// 出力尺が合成尺（2 クリップの合計）になること。素材スコープの検出キャッシュと
    /// 写像を渡し、キャッシュ参照経路込みで完走することを確認する。
    func test_splitReorderedTwoClips_exportCompletesWithCompositionDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 3.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        // 素材の [2,3) → [0,1) の順に並べ替え（合成尺 2s）
        let clips = [
            TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3),
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        ]
        let sources: [UUID: AVAsset] = [sourceID: AVURLAsset(url: url)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition

        // 素材時刻キーのキャッシュ（各クリップの使用区間に 1 バケットずつ）
        let caches: [UUID: [Double: [FaceLandmarkSet]]] = [
            sourceID: [2.5: [fakeFace(cx: 0.7, cy: 0.3)], 0.5: [fakeFace(cx: 0.3, cy: 0.6)]]
        ]

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            detectionCaches: caches,
            mapping: TimelineMapping(clips: clips)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.2,
                       "並べ替え 2 クリップの出力尺が合成尺と一致しない")
        let videoTracks = try await out.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    /// rate 2（倍速）クリップのエクスポート出力尺が素材長の半分になること
    /// （scaleTimeRange 済みの Composition を reader/writer が正しく通す）。
    func test_rateTwoClip_exportHalvesDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.15,
                       "rate 2 クリップの出力尺が合成尺（素材長の半分）と一致しない")
    }

    /// trimRange（writer の PTS シフト）と写像が二重適用されないこと、および
    /// クリップ境界に整列したトリム（0.5...1.0）で音声が正しく載ること:
    /// 2 クリップ（各 1s）の後半 50% をトリム書き出しして出力尺が 1s になり、
    /// 音声トラックが存在し、RMS 解析で「後半クリップ（素材 [2,3) の有音区間）の音」
    /// だけが出力全体に載ることを固定する（旧方式は音声全損を素通しした）。
    func test_trimRangeWithMapping_exportsTrimmedDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 素材 [0,2) は無音・[2,3) のみ有音 → 合成は [0,1) 無音・[1,2) 有音。
        let url = try await makeTestVideo(seconds: 3.0, withAudio: true,
                                          audioAmplitude: { $0 >= 2.0 ? 1.0 : 0.0 })
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)
        ]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let caches: [UUID: [Double: [FaceLandmarkSet]]] = [
            sourceID: [2.5: [fakeFace(cx: 0.5, cy: 0.5)]]
        ]
        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            detectionCaches: caches,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.5...1.0
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.05,
                       "トリム書き出しの出力尺が選択範囲（後半 1s）と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "トリム書き出しで音声トラックが消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.05,
                           "音声トラックの尺が映像とずれている")
        }
        // 出力は全区間が有音区間（合成 [1,2) = 素材 [2,3)）のはず。
        let headRMS = try await audioRMS(url: outURL, window: 0.05...0.45)
        let tailRMS = try await audioRMS(url: outURL, window: 0.55...0.95)
        XCTAssertGreaterThan(headRMS, 0.1, "トリム先頭に有音区間の音が載っていない（無音側が混入）")
        XCTAssertGreaterThan(tailRMS, 0.1, "トリム後半に有音区間の音が載っていない")
    }

    /// クリップ境界を跨ぐトリム（0.25...0.75）で音声の実音位置が正しいこと:
    /// 合成 [0.5,1.5)（前半クリップの無音 0.5s + 後半クリップの有音 0.5s）を書き出し、
    /// 出力の前半が無音・後半が有音になることを RMS 解析で固定する
    /// （レビューで音声トラックごと消えていた組み合わせ）。
    func test_trimAcrossClipBoundary_audioPositionIsCorrect() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 素材 [0,2) は無音・[2,3) のみ有音 → 合成は [0,1) 無音・[1,2) 有音。
        let url = try await makeTestVideo(seconds: 3.0, withAudio: true,
                                          audioAmplitude: { $0 >= 2.0 ? 1.0 : 0.0 })
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)
        ]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.25...0.75
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.05)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "境界跨ぎトリムで音声トラックが消えている")
        let headRMS = try await audioRMS(url: outURL, window: 0.05...0.4)
        let tailRMS = try await audioRMS(url: outURL, window: 0.6...0.95)
        XCTAssertLessThan(headRMS, 0.03, "出力前半（無音のはずの区間）に音が載っている（位置ずれ）")
        XCTAssertGreaterThan(tailRMS, 0.1, "出力後半（有音のはずの区間）が無音（音声全損 or 位置ずれ）")
    }

    /// >2ch（5.1ch = 6ch）音声素材のトリム書き出しがクラッシュせず完走し、
    /// 音声（ステレオへダウンミックス）が載ること。
    /// AAC 出力設定に AVChannelLayoutKey 無しで 3ch 以上を指定すると
    /// AVAssetWriterInput の init が NSInvalidArgumentException（Swift で catch 不能・
    /// テストランナーごと落ちる）を投げる回帰の実測ガード
    /// （`aacAudioSettings(matching:)` が 2ch へクランプする）。
    func test_sixChannelAudioTrim_exportsDownmixedAudioWithoutCrash() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 3.0, withAudio: true, audioChannels: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)
        ]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.25...0.75
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.05)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "6ch 素材のトリム書き出しで音声トラックが消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.05)
        }
        let rms = try await audioRMS(url: outURL, window: 0.1...0.9)
        XCTAssertGreaterThan(rms, 0.1, "6ch 素材のダウンミックス音声が載っていない")
    }

    /// 単一クリップ＋トリム＋音声あり（フェーズ1から存在する経路）の回帰ガード。
    /// 3s 素材の 0.5〜2.5s は旧方式（圧縮パススルー + 自前ゲート）が -11800/-16364 で
    /// 落ちた組み合わせ。PCM 再エンコード経路で完走・音声維持・実音位置まで固定する。
    func test_singleClipTrimWithAudio_exportsTrimmedDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 素材 [0,1) は無音・[1,3) が有音 → トリム後の出力は [0,0.5) 無音・[0.5,2.0) 有音。
        let url = try await makeTestVideo(seconds: 3.0, withAudio: true,
                                          audioAmplitude: { $0 >= 1.0 ? 1.0 : 0.0 })
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 3)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: (0.5 / 3.0)...(2.5 / 3.0)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.05)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "トリム書き出しで音声が消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 2.0, accuracy: 0.05,
                           "音声トラックの尺が映像とずれている")
        }
        let headRMS = try await audioRMS(url: outURL, window: 0.05...0.4)
        let tailRMS = try await audioRMS(url: outURL, window: 0.6...1.9)
        XCTAssertLessThan(headRMS, 0.03, "出力前半（無音のはずの区間）に音が載っている（位置ずれ）")
        XCTAssertGreaterThan(tailRMS, 0.1, "出力後半（有音のはずの区間）が無音（音声全損 or 位置ずれ）")
    }

    /// rate ≠ 1 のスケールが音声トラックにも適用されること（映像だけスケールすると
    /// 音ズレ・尺超過になる）。Composition の音声トラック尺を直接確認する。
    func test_rateScale_appliesToAudioTrackToo() async throws {
        let url = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first, "合成に音声トラックが無い")
        let range = try await audio.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.15,
                       "音声トラックが scaleTimeRange されていない（映像と尺がずれる）")
    }

    // MARK: - 写真クリップ（S6）

    /// テスト用の写真クリップ mp4（320x240 = makeTestVideo と同解像度。
    /// S6 時点の builder は解像度混在を明示エラーにするため揃える）。
    private func makePhotoClip(seconds: Double) async throws -> PhotoClipEncoder.EncodedPhotoClip {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                            format: format).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try await PhotoClipEncoder().encode(image: image, seconds: seconds)
    }

    /// 音声なしの写真クリップを先頭に置いた「写真 + 動画」結合エクスポートが完走し、
    /// 出力尺が合成尺（3s + 2s）になり、**後続クリップの音声が正しい位置**
    /// （写真区間は無音・動画区間 [3,5) に有音）に載ること。
    /// 音声トラックを持たない素材を挟んだときの音声 cursor 同期
    /// （builder の empty range 挿入）の回帰ガード。
    func test_photoLeaderPlusVideo_exportKeepsAudioInSync() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let videoURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let photo = try await makePhotoClip(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }

        let photoID = UUID()
        let videoID = UUID()
        let clips = [
            TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration),
            TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2)
        ]
        let sources: [UUID: AVAsset] = [photoID: AVURLAsset(url: photo.url),
                                        videoID: AVURLAsset(url: videoURL)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition
        let compositionDuration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(compositionDuration), 5.0, accuracy: 0.1,
                       "写真クリップ入り composition の尺が合成尺と一致しない")

        let caches: [UUID: [Double: [FaceLandmarkSet]]] = [
            photoID: [0.0: [fakeFace(cx: 0.5, cy: 0.5)]]
        ]
        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            detectionCaches: caches,
            mapping: TimelineMapping(clips: clips),
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5.0, accuracy: 0.2,
                       "写真 + 動画結合の出力尺が合成尺と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "写真クリップを挟むと音声トラックが消える")
        // 写真区間（[0,3)）は無音・動画区間（[3,5)）に素材の音がそのまま載ること。
        let photoRMS = try await audioRMS(url: outURL, window: 0.5...2.5)
        let videoRMS = try await audioRMS(url: outURL, window: 3.3...4.7)
        XCTAssertLessThan(photoRMS, 0.03, "写真区間（無音のはず）に音が載っている（cursor ずれ）")
        XCTAssertGreaterThan(videoRMS, 0.1, "動画区間の音が無音（音声全損 or 位置ずれ）")
    }

    // MARK: - S8: トランジション（合成の装着・二重回転・音声クロスフェード）

    /// **二重回転の回帰ガード（S8 最大の落とし穴）**。
    ///
    /// 縦動画（`preferredTransform` が 90 度回転）にトランジションを付けて書き出し、
    /// 出力の**実際の見え方**（`appliesPreferredTrackTransform` 付きで取り出したフレーム）が
    /// 素材の見え方と一致することを、表示サイズと 4 象限の平均色で確かめる。
    ///
    /// `preferredTransform` は videoComposition の layer instruction に畳み込まれ、
    /// writer 側は identity・出力サイズは renderSize になる。writer 側にも回転を残すと
    /// 表示サイズが横向きに戻る（240x320 → 320x240）か、象限の色が 180 度入れ替わる。
    func test_portraitVideoWithTransition_isNotDoubleRotated() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makePortraitQuadrantVideo(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        let transitions = [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        let built = try await TimelineCompositionBuilder().build(
            clips: [first, second], transitions: transitions,
            sources: [sourceID: AVURLAsset(url: url)])
        let videoComposition = try XCTUnwrap(built.videoComposition,
                                             "トランジションがあるのに videoComposition が無い")
        // 縦動画なので renderSize は 240x320（naturalSize 320x240 の 90 度回転後）。
        XCTAssertEqual(videoComposition.renderSize, CGSize(width: 240, height: 320),
                       "renderSize が preferredTransform 適用後の表示サイズになっていない")

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: built.composition,
            mapping: TimelineMapping(clips: [first, second], transitions: transitions),
            videoComposition: built.videoComposition,
            audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 書き出しトラックの素の状態: サイズは renderSize、向きは identity。
        let outTracks = try await AVURLAsset(url: outURL).loadTracks(withMediaType: .video)
        let outTrack = try XCTUnwrap(outTracks.first)
        let outNaturalSize = try await outTrack.load(.naturalSize)
        let outTransform = try await outTrack.load(.preferredTransform)
        XCTAssertEqual(outNaturalSize, CGSize(width: 240, height: 320),
                       "出力の格納解像度が renderSize と違う")
        XCTAssertEqual(outTransform, .identity,
                       "writer 側にも回転が残っている（instruction と合わせて二重回転になる）")

        // 実際の見え方の突き合わせ（素材 = 正解）。
        let reference = try displayedQuadrants(url: url, at: 0.5)
        let output = try displayedQuadrants(url: outURL, at: 0.5)
        XCTAssertEqual(output.size, reference.size,
                       "出力の表示サイズが素材と違う（二重回転で縦横が入れ替わっている）")
        for quadrant in 0..<4 {
            let (out, ref) = (output.colors[quadrant], reference.colors[quadrant])
            XCTAssertEqual(out.r, ref.r, accuracy: 40, "象限 \(quadrant) の R が素材と違う（回転ずれ）")
            XCTAssertEqual(out.g, ref.g, accuracy: 40, "象限 \(quadrant) の G が素材と違う（回転ずれ）")
            XCTAssertEqual(out.b, ref.b, accuracy: 40, "象限 \(quadrant) の B が素材と違う（回転ずれ）")
        }
        // 4 象限が実際に互いに別色であること（全部同色なら上の比較は無意味になる）。
        for lhs in 0..<4 {
            for rhs in (lhs + 1)..<4 {
                let (a, b) = (output.colors[lhs], output.colors[rhs])
                let distance = max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
                XCTAssertGreaterThan(distance, 60,
                                     "象限 \(lhs) と \(rhs) が同色（回転ずれを検出できない素材）")
            }
        }

        // トランジションぶん尺が縮むこと（重なりモデルと一致）。
        let duration = try await AVURLAsset(url: outURL).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.5, accuracy: 0.2,
                       "トランジションの重なりぶん尺が縮んでいない")
    }

    /// rate≠1 でも videoComposition が装着され（`VideoCompositionPlan.decide`）、
    /// 合成済みフレーム経路（`AVAssetReaderVideoCompositionOutput`）で書き出せること。
    /// 出力フレームレートは素材の公称値どまり（実効 fps の跳ね上がりを頭打ちにする）。
    func test_rateClipWithVideoCompositionExportsHalvedDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        let built = try await TimelineCompositionBuilder().build(
            clips: clips, sources: [sourceID: AVURLAsset(url: url)])
        let videoComposition = try XCTUnwrap(built.videoComposition,
                                             "rate≠1 なのに videoComposition が装着されていない")
        XCTAssertLessThanOrEqual(
            1.0 / CMTimeGetSeconds(videoComposition.frameDuration),
            VideoCompositionFactory.maxFrameRate + 0.001,
            "frameDuration に上限が掛かっていない（rate=10 で実効 300fps になる）")

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: built.composition,
            mapping: TimelineMapping(clips: clips),
            videoComposition: built.videoComposition,
            audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let duration = try await AVURLAsset(url: outURL).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.15,
                       "合成済みフレーム経路で rate=2 の出力尺が半分になっていない")
    }

    /// トランジション区間で音声がクロスフェードすること（audioMix の実効検証）。
    ///
    /// 素材は前半 2s が有音・後半 2s が無音。クリップ A=[0,2) / B=[2,4) を 0.5s の
    /// クロスフェードで繋ぐと、出力は「[0,1.5) 有音 → [1.5,2.0) A が減衰 → [2.0,3.5) 無音」。
    /// audioMix が効いていないと重なり区間で A の音が減衰せずそのまま鳴る。
    func test_transitionCrossfadesAudio() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 4.0, withAudio: true,
                                          audioAmplitude: { $0 < 2.0 ? 1.0 : 0.0 })
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        let transitions = [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        let built = try await TimelineCompositionBuilder().build(
            clips: [first, second], transitions: transitions,
            sources: [sourceID: AVURLAsset(url: url)])
        XCTAssertNotNil(built.audioMix, "音声付きトランジションなのに audioMix が無い")

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: built.composition,
            mapping: TimelineMapping(clips: [first, second], transitions: transitions),
            videoComposition: built.videoComposition,
            audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let bodyRMS = try await audioRMS(url: outURL, window: 0.3...1.2)
        let overlapRMS = try await audioRMS(url: outURL, window: 1.6...1.95)
        let tailRMS = try await audioRMS(url: outURL, window: 2.3...3.4)
        print("[S8AUDIO] body=\(bodyRMS) overlap=\(overlapRMS) tail=\(tailRMS)")
        XCTAssertGreaterThan(bodyRMS, 0.1, "クリップ本体の音が載っていない")
        XCTAssertLessThan(tailRMS, 0.05, "無音のはずの後続クリップ区間に音が残っている")
        XCTAssertLessThan(overlapRMS, bodyRMS * 0.9,
                          "重なり区間で音量が落ちていない（audioMix のランプが効いていない）")
        XCTAssertGreaterThan(overlapRMS, 0.01, "重なり区間の音が完全に消えている（フェードが急すぎる）")
    }

    /// **トラック B 側クリップの音声全損の回帰ガード（S8 の穴）**。
    ///
    /// `test_transitionCrossfadesAudio` は素材の後半 2s を無音にしているため、
    /// 「後続クリップ（= 音声トラック B）の音が丸ごと落ちる」バグを**構造的に検出できない**
    /// （落ちても後半は無音のままで期待どおりに見える）。ここでは**両クリップとも有音**の
    /// 素材を使い、重なりを抜けた後続クリップ区間に音が載っていることを RMS で固定する。
    ///
    /// 症状: 重なり（トランジション）があると builder が音声も A/B 2 トラックへ交互配置する
    /// （`TimelineCompositionBuilder`）のに、exporter が合成結果の音声トラックを 1 本しか
    /// 読まないと、奇数インデックスのクリップ（B 側）の音声が出力に一切入らない。
    /// プレビュー（`AVPlayerItem` に composition 丸ごと）では両トラックが鳴るため、
    /// 書き出すまで気づけない食い違いになる。
    func test_transitionKeepsAudioOfFollowingClip() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 全区間有音（振幅一定）。どちらのクリップが落ちても RMS で分かる。
        let url = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        let transitions = [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        let built = try await TimelineCompositionBuilder().build(
            clips: [first, second], transitions: transitions,
            sources: [sourceID: AVURLAsset(url: url)])
        XCTAssertNotNil(built.audioMix, "音声付きトランジションなのに audioMix が無い")

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: built.composition,
            mapping: TimelineMapping(clips: [first, second], transitions: transitions),
            videoComposition: built.videoComposition,
            audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 合成尺は 2 + 2 - 0.5 = 3.5s。重なりは [1.5, 2.0)。
        // 先行クリップ本体 [0.3,1.2) と、後続クリップの重なりを抜けた本体 [2.3,3.4)。
        let headRMS = try await audioRMS(url: outURL, window: 0.3...1.2)
        let tailRMS = try await audioRMS(url: outURL, window: 2.3...3.4)
        print("[S8AUDIO-B] head=\(headRMS) tail=\(tailRMS)")
        XCTAssertGreaterThan(headRMS, 0.1, "先行クリップ（音声トラック A）の音が載っていない")
        XCTAssertGreaterThan(tailRMS, 0.1,
                             "後続クリップ（音声トラック B）の音が出力に入っていない"
                             + "（exporter が音声トラックを 1 本しか読んでいない）")
        // 2 トラックをミックスしても出力尺は合成尺のまま（音声側が伸びない）。
        let duration = try await AVURLAsset(url: outURL).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.5, accuracy: 0.2,
                       "2 トラックのミックスで出力尺がずれている")
    }

    /// `AudioExportPipeline.decide` の純ロジック契約（真理値表を全 64 通り固定）:
    /// パススルー（bit 同一の無変換コピー）は**立っている条件が 0 個のときだけ**で、
    /// 1 個以上あれば再エンコード。
    ///
    /// 期待値を `decide` と同じ OR 式で書くと実装の写経になり、条件が増えたときの
    /// 「OR に足し忘れ」を検出できない。ここでは期待値を**立っているビットの個数**
    /// （`bits == 0` か否か）だけから決め、条件の列挙に依存させない。
    func test_audioPipelineDecision_passthroughOnlyWhenNoTransform() {
        for bits in 0..<64 {
            let trimming = bits & 1 != 0
            let hasAudioMix = bits & 16 != 0
            let conditions = AudioTrackConditions(hasEmptySegments: bits & 2 != 0,
                                                  hasScaledSegments: bits & 4 != 0,
                                                  hasMixedFormats: bits & 8 != 0,
                                                  hasMultipleTracks: bits & 32 != 0)
            let expected: AudioExportPipeline = bits == 0 ? .passthrough : .reencode
            XCTAssertEqual(
                AudioExportPipeline.decide(isTrimming: trimming, hasAudioMix: hasAudioMix,
                                           conditions: conditions),
                expected,
                "decide(trim: \(trimming), mix: \(hasAudioMix), conditions: \(conditions)) が期待と違う")
        }
    }

    /// 「条件が 5 個目に増えたのに `decide` の OR へ足し忘れ」を捕まえる契約テスト。
    ///
    /// `AudioTrackConditions` の各条件を**単独で**立てて全て `.reencode` になることを
    /// 確かめ、あわせて条件の個数そのものを固定する。新しい条件が増えると個数の
    /// アサートが落ちるので、`decide` とこのテスト両方の更新が強制される
    /// （足し忘れたまま増やすと、その条件は無言で `.passthrough` に落ちる）。
    func test_everyAudioTrackConditionAloneForcesReencode() {
        let fields: [(String, WritableKeyPath<AudioTrackConditions, Bool>)] = [
            ("hasEmptySegments", \.hasEmptySegments),
            ("hasScaledSegments", \.hasScaledSegments),
            ("hasMixedFormats", \.hasMixedFormats),
            ("hasMultipleTracks", \.hasMultipleTracks)
        ]
        XCTAssertEqual(Mirror(reflecting: AudioTrackConditions()).children.count, fields.count,
                       "AudioTrackConditions の条件が増減した。decide の OR とこのテストの "
                       + "fields を更新すること（足し忘れると無言で passthrough に落ちる）")
        for (name, keyPath) in fields {
            var conditions = AudioTrackConditions()
            conditions[keyPath: keyPath] = true
            XCTAssertEqual(AudioExportPipeline.decide(isTrimming: false, hasAudioMix: false,
                                                      conditions: conditions),
                           .reencode, "\(name) が単独で再エンコードを選ばせていない")
        }
        XCTAssertEqual(
            AudioExportPipeline.decide(isTrimming: true, hasAudioMix: false,
                                       conditions: AudioTrackConditions()),
            .reencode, "isTrimming が単独で再エンコードを選ばせていない")
        // audioMix（S8）単独でも再エンコード。パススルーは元パケットのコピーなので
        // 音量ランプ・クロスフェードが一切反映されない。
        XCTAssertEqual(
            AudioExportPipeline.decide(isTrimming: false, hasAudioMix: true,
                                       conditions: AudioTrackConditions()),
            .reencode, "hasAudioMix が単独で再エンコードを選ばせていない")
        XCTAssertEqual(
            AudioExportPipeline.decide(isTrimming: false, hasAudioMix: false,
                                       conditions: AudioTrackConditions()),
            .passthrough, "全条件が偽なのにパススルーにならない")
    }

    /// `decide` の**入力**（合成結果の音声トラックから読む実データ）が
    /// 想定どおり立つこと。純ロジックだけ固定しても入口がズレたら意味が無いので、
    /// 実際の composition から `AudioTrackConditions` を組んで確かめる。
    func test_audioTrackConditions_fromRealComposition() async throws {
        let url = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let url48 = try await makeTestVideo(seconds: 2.0, withAudio: true, audioSampleRate: 48000.0)
        defer { try? FileManager.default.removeItem(at: url48) }
        let photo = try await makePhotoClip(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }

        let aID = UUID(), bID = UUID(), photoID = UUID()
        let sources: [UUID: AVAsset] = [aID: AVURLAsset(url: url),
                                        bID: AVURLAsset(url: url48),
                                        photoID: AVURLAsset(url: photo.url)]

        func conditions(_ clips: [TimelineClip]) async throws -> AudioTrackConditions {
            let composition = try await TimelineCompositionBuilder()
                .build(clips: clips, sources: sources).composition
            let tracks = try await composition.loadTracks(withMediaType: .audio)
            XCTAssertFalse(tracks.isEmpty, "合成に音声トラックが無い")
            return AudioTrackConditions.from(tracks: await AudioTrackData.load(from: tracks))
        }

        // 無変換（等速・単一素材）: すべて偽 = パススルー相当。
        let plain = try await conditions([TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2)])
        XCTAssertEqual(plain, AudioTrackConditions(), "無変換タイムラインで変換条件が立っている")

        // rate=2: スケール編集だけが立つ。
        let scaled = try await conditions(
            [TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2, rate: 2.0)])
        XCTAssertTrue(scaled.hasScaledSegments, "rate=2 のスケール編集を検出できていない")
        XCTAssertFalse(scaled.hasEmptySegments)
        XCTAssertFalse(scaled.hasMixedFormats)

        // 写真（音声なし素材）を挟む: empty edit だけが立つ。
        let withPhoto = try await conditions([
            TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration),
            TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2)
        ])
        XCTAssertTrue(withPhoto.hasEmptySegments, "音声なし素材の empty edit を検出できていない")
        XCTAssertFalse(withPhoto.hasScaledSegments)

        // 44.1kHz + 48kHz の連結: フォーマット混在だけが立つ。
        let mixed = try await conditions([
            TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceID: bID, sourceStart: 0, sourceEnd: 2)
        ])
        XCTAssertTrue(mixed.hasMixedFormats, "48k/44.1k 混在を検出できていない")
        XCTAssertFalse(mixed.hasScaledSegments)
        XCTAssertFalse(mixed.hasEmptySegments)
    }

    // MARK: - M-1: スケール判定の許容差（微小 rate を取りこぼさない）

    /// 合成結果の音声トラックを全部取り出す（スケール判定系のテストで共有）。
    private func audioTracks(_ clips: [TimelineClip],
                             sources: [UUID: AVAsset]) async throws -> [AVAssetTrack] {
        let composition = try await TimelineCompositionBuilder().build(clips: clips,
                                                                      sources: sources).composition
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty, "合成に音声トラックが無い")
        return tracks
    }

    /// 先頭の音声トラック（1 本しか見ないセグメント検査用）。
    private func audioTrack(_ clips: [TimelineClip],
                            sources: [UUID: AVAsset]) async throws -> AVAssetTrack {
        let tracks = try await audioTracks(clips, sources: sources)
        return try XCTUnwrap(tracks.first, "合成に音声トラックが無い")
    }

    /// `AudioTrackConditions.from(tracks:)` の契約どおり**全トラック**を渡す
    /// （1 本だけ渡すと A/B 交互配置で B 側の判定材料を取りこぼす）。
    private func audioConditions(_ clips: [TimelineClip],
                                 sources: [UUID: AVAsset]) async throws -> AudioTrackConditions {
        let tracks = try await audioTracks(clips, sources: sources)
        return AudioTrackConditions.from(tracks: await AudioTrackData.load(from: tracks))
    }

    /// 各セグメントの source − target 秒（スケール判定が見ている実量）。
    private func scaleDiffsSeconds(_ clips: [TimelineClip],
                                   sources: [UUID: AVAsset]) async throws -> [Double] {
        let segments = try await audioTrack(clips, sources: sources).load(.segments)
        return segments.map { segment in
            CMTimeGetSeconds(segment.timeMapping.source.duration)
                - CMTimeGetSeconds(segment.timeMapping.target.duration)
        }
    }

    /// **微小な rate 変更**（|rate − 1| < 1%）がスケール編集として検出されること。
    ///
    /// 許容差をクリップ長に比例させていた頃（`max(source * 0.005, 0.005)`）は
    /// rate=1.001〜1.004 が「スケールなし」と判定され、音声だけ `.passthrough` に
    /// 落ちて **速度変更が音声に反映されない**（映像だけ速くなる）状態だった。
    /// `TimelineClip.rateRange` は連続値なので「rate 変更は必ず 1 割以上動く」は
    /// 成り立たない。許容差は timescale 600 の丸め由来の**固定値**であること。
    /// 実測の diff は 1/600s の整数倍（= 差 1 目盛が最小のスケール）で、
    /// 等速タイムラインの diff は厳密に 0
    /// （`test_audioTrackConditions_noFalsePositiveOnUnscaledTimelines` が固定）。
    func test_audioTrackConditions_detectsMicroRateChange() async throws {
        let url2 = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url2) }
        let url4 = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url4) }

        let id2 = UUID(), id4 = UUID()
        let sources: [UUID: AVAsset] = [id2: AVURLAsset(url: url2), id4: AVURLAsset(url: url4)]

        for (sourceID, seconds) in [(id2, 2.0), (id4, 4.0)] {
            for rate in [1.001, 1.002, 1.004, 1.01, 0.999, 0.996] {
                let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0,
                                          sourceEnd: seconds, rate: rate)]
                let conditions = try await audioConditions(clips, sources: sources)
                let diffs = try await scaleDiffsSeconds(clips, sources: sources)
                print("[S7] microRate seconds=\(seconds) rate=\(rate) "
                      + "scaled=\(conditions.hasScaledSegments) diffs=\(diffs)")
                XCTAssertTrue(conditions.hasScaledSegments,
                              "rate=\(rate)（素材 \(seconds)s）のスケール編集を取りこぼした。"
                              + "音声だけ速度変更が反映されない経路に落ちる。")
            }
        }
    }

    /// 逆方向のガード: **無変換構成でスケール扱いされない**こと（パススルー契約の維持）。
    /// 許容差を締めた副作用で等速タイムラインが再エンコードへ落ちると、
    /// フェーズ1 からの bit 同一忠実度が黙って壊れる。
    func test_audioTrackConditions_noFalsePositiveOnUnscaledTimelines() async throws {
        let url2 = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url2) }
        let url4 = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url4) }

        let idA = UUID(), idB = UUID()
        let sources: [UUID: AVAsset] = [idA: AVURLAsset(url: url2), idB: AVURLAsset(url: url4)]

        let cases: [(String, [TimelineClip])] = [
            ("単一・全長", [TimelineClip(sourceID: idA, sourceStart: 0, sourceEnd: 2)]),
            ("同一素材 2 クリップ", [
                TimelineClip(sourceID: idA, sourceStart: 0, sourceEnd: 1),
                TimelineClip(sourceID: idA, sourceStart: 1, sourceEnd: 2)
            ]),
            ("別素材 2 クリップ", [
                TimelineClip(sourceID: idA, sourceStart: 0, sourceEnd: 2),
                TimelineClip(sourceID: idB, sourceStart: 0, sourceEnd: 2)
            ]),
            ("端数境界", [
                TimelineClip(sourceID: idB, sourceStart: 0.3333, sourceEnd: 1.6667),
                TimelineClip(sourceID: idB, sourceStart: 0.7777, sourceEnd: 2.1111)
            ]),
            ("極小クリップ", [TimelineClip(sourceID: idA, sourceStart: 0, sourceEnd: 0.04)]),
            ("rate=1.0 明示", [TimelineClip(sourceID: idA, sourceStart: 0,
                                            sourceEnd: 2, rate: 1.0)])
        ]

        for (name, clips) in cases {
            let conditions = try await audioConditions(clips, sources: sources)
            let diffs = try await scaleDiffsSeconds(clips, sources: sources)
            print("[S7] noScale \(name) scaled=\(conditions.hasScaledSegments) diffs=\(diffs)")
            XCTAssertFalse(conditions.hasScaledSegments,
                           "\(name): 等速なのにスケール扱いされた（パススルー契約が壊れる）")
        }
    }

    // MARK: - clampAudioSample の単体契約

    /// 16bit モノラル PCM の `CMSampleBuffer` を合成する。
    /// リーダー経由では踏めない分岐（範囲外・境界・切り詰め失敗）を単体で固定するために使う。
    ///
    /// `withSampleSizes: false` にするとサンプルサイズを持たないバッファになり、
    /// `CMSampleBufferCopySampleBufferForRange` が
    /// `kCMSampleBufferError_BufferHasNoSampleSizes`（-12735）で失敗する
    /// ＝ 切り詰め失敗のフォールバック経路を再現できる。
    private func makePCMSampleBuffer(numSamples: Int,
                                     startSeconds: Double,
                                     sampleRate: Double = 44_100,
                                     withSampleSizes: Bool = true) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format), noErr)

        let byteCount = numSamples * 2
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer), noErr)
        let block = try XCTUnwrap(blockBuffer)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                                                  offsetIntoDestination: 0,
                                                  dataLength: byteCount), noErr)

        let scale = CMTimeScale(sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: scale),
            presentationTimeStamp: CMTime(seconds: startSeconds, preferredTimescale: scale),
            decodeTimeStamp: .invalid)
        let sizeStorage = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        sizeStorage.initialize(to: 2)
        defer { sizeStorage.deallocate() }
        let sizeArray: UnsafePointer<Int>? = withSampleSizes
            ? UnsafePointer(sizeStorage) : nil

        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: numSamples,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: withSampleSizes ? 1 : 0,
            sampleSizeArray: sizeArray,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    /// `clampAudioSample` の分岐契約。実リーダー経由では 1 バッファ 8192 フレーム・
    /// 余剰 ≈0.116s（< 1 バッファ）なので「バッファ丸ごと範囲外」に到達せず、
    /// 統合テストでは切り詰め経路しか通らない（フルスイートのログに
    /// `audio tail clamp` が 1 件も出ないことを実測で確認済み）。
    /// 全分岐をここで単体固定する。
    func test_clampAudioSample_branches() throws {
        // (a) 完全に範囲内: そのまま append（切り詰めない）。
        let inside = try makePCMSampleBuffer(numSamples: 4410, startSeconds: 0.0)
        switch VideoMosaicExporter.clampAudioSample(inside, toEndSeconds: 1.0) {
        case .append(let out):
            XCTAssertEqual(CMSampleBufferGetNumSamples(out), 4410,
                           "範囲内のバッファが切り詰められた（音が欠ける）")
        case .finished(let pts):
            XCTFail("範囲内のバッファが打ち切られた pts=\(pts)")
        }

        // (b) 範囲を跨ぐ: 収まるサンプル数だけに切り詰められる。
        // pts=0.05s / 0.1s ぶん（4410 サンプル）→ limit=0.1s には 2205 サンプルだけ収まる。
        let straddling = try makePCMSampleBuffer(numSamples: 4410, startSeconds: 0.05)
        switch VideoMosaicExporter.clampAudioSample(straddling, toEndSeconds: 0.1) {
        case .append(let out):
            XCTAssertEqual(CMSampleBufferGetNumSamples(out), 2205,
                           "範囲跨ぎのバッファが正しく切り詰められていない（末尾に余剰が残る）")
        case .finished(let pts):
            XCTFail("範囲跨ぎのバッファが打ち切られた pts=\(pts)")
        }

        // (c) 完全に範囲外: finished（音声を打ち切ってよい）。
        let outside = try makePCMSampleBuffer(numSamples: 4410, startSeconds: 1.5)
        switch VideoMosaicExporter.clampAudioSample(outside, toEndSeconds: 1.0) {
        case .append(let out):
            XCTFail("範囲外のバッファを append した samples=\(CMSampleBufferGetNumSamples(out))")
        case .finished(let pts):
            XCTAssertEqual(pts, 1.5, accuracy: 0.001, "打ち切り位置の pts が違う")
        }

        // (d) 境界: 1 サンプルも収まらない（fitting=0）が pts は範囲内。
        // 下限 1 にクランプして append する（0 サンプルのバッファを writer に渡さない）。
        let hairline = try makePCMSampleBuffer(numSamples: 4410, startSeconds: 0.1)
        switch VideoMosaicExporter.clampAudioSample(hairline, toEndSeconds: 0.100005) {
        case .append(let out):
            XCTAssertEqual(CMSampleBufferGetNumSamples(out), 1,
                           "fitting=0 の境界で 1 サンプルにクランプされていない")
        case .finished(let pts):
            XCTFail("pts が範囲内なのに打ち切られた pts=\(pts)")
        }

        // (e) 切り詰め失敗（サンプルサイズを持たないバッファ）: 欠落より余剰を選んで
        // 元バッファを append する。ただし `[MMEXPORT] audio tail clamp FAILED` を
        // 出すこと（無言で余剰が復活する経路を残さない）。
        let unsized = try makePCMSampleBuffer(numSamples: 4410, startSeconds: 0.05,
                                              withSampleSizes: false)
        switch VideoMosaicExporter.clampAudioSample(unsized, toEndSeconds: 0.1) {
        case .append(let out):
            XCTAssertEqual(CMSampleBufferGetNumSamples(out), 4410,
                           "切り詰めに失敗したのに元バッファを返していない（音が欠ける）")
        case .finished(let pts):
            XCTFail("切り詰め失敗で打ち切ってしまった pts=\(pts)")
        }
    }

    /// rate=2 クリップの書き出しで、**音声も**半分の尺になり AAC で載っていること。
    /// 圧縮パススルーだと `scaleTimeRange`（edit）が反映されず音声だけ等速のまま
    /// 残る（映像 1s に対し音声 2s）ので、経路選択の実測ガードになる。
    func test_rateTwoClipWithAudio_audioIsHalvedAndReencoded() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition, mapping: TimelineMapping(clips: clips)) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.05,
                       "rate=2 の出力尺が素材長の半分になっていない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "rate=2 の書き出しで音声が消えている")
        let audio = try XCTUnwrap(audioTracks.first)
        let range = try await audio.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.05,
                       "音声トラックがスケールされていない（パススルーに落ちている可能性）")
        let formats = try await audio.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC, "音声が AAC で書かれていない")
        let rms = try await audioRMS(url: outURL, window: 0.1...0.9)
        XCTAssertGreaterThan(rms, 0.1, "rate=2 の書き出しで音が載っていない")
    }

    /// トリム × rate（S6 からの繰り越し課題）: 音声トラックの尺が映像と揃うこと。
    /// リーダーは `timeRange` 末尾を跨ぐデコード単位まで返し、`scaleTimeRange` 下では
    /// その余剰が合成時間で rate 倍に膨らむ（実測で音声だけ約 0.11s 長かった）。
    /// `clampAudioSample` が末尾を切ることを、締めた許容値（0.05）で固定する。
    func test_trimWithRate_audioDurationMatchesVideo() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 素材 4s を rate=2 → 合成 2s。その中央 50%（合成 [0.5,1.5)）を書き出す。
        let url = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4, rate: 2.0)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.25...0.75
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let videoTracks = try await out.loadTracks(withMediaType: .video)
        let videoRange = try await XCTUnwrap(videoTracks.first).load(.timeRange)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "trim × rate で音声トラックが消えている")
        let audioRange = try await XCTUnwrap(audioTracks.first).load(.timeRange)
        let videoSec = CMTimeGetSeconds(videoRange.duration)
        let audioSec = CMTimeGetSeconds(audioRange.duration)
        let totalSec = CMTimeGetSeconds(try await out.load(.duration))
        print("[S7] trim×rate video=\(videoSec)s audio=\(audioSec)s total=\(totalSec)s")
        XCTAssertEqual(videoSec, 1.0, accuracy: 0.05, "trim × rate の映像尺がずれている")
        XCTAssertEqual(audioSec, 1.0, accuracy: 0.05,
                       "trim × rate の音声尺がずれている（末尾余剰が残っている）")
        XCTAssertEqual(audioSec, videoSec, accuracy: 0.05,
                       "音声だけ映像より長い（末尾余剰）")
        let rms = try await audioRMS(url: outURL, window: 0.1...0.9)
        XCTAssertGreaterThan(rms, 0.1, "trim × rate の書き出しで音が載っていない")
    }

    /// 48kHz 素材 + 44.1kHz 素材の連結（トリム・rate なし）が完走し、
    /// **両方の区間**に音が載ること。パススルーだと writer 入力の `sourceFormatHint`
    /// が 1 フォーマットしか表せず、途中でフォーマットが変わった時点で破綻する。
    func test_mixedSampleRateClips_exportKeepsAudioInBothClips() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url44 = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url44) }
        let url48 = try await makeTestVideo(seconds: 2.0, withAudio: true,
                                            audioSampleRate: 48000.0)
        defer { try? FileManager.default.removeItem(at: url48) }

        let aID = UUID(), bID = UUID()
        let clips = [
            TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceID: bID, sourceStart: 0, sourceEnd: 2)
        ]
        let composition = try await TimelineCompositionBuilder().build(
            clips: clips,
            sources: [aID: AVURLAsset(url: url44), bID: AVURLAsset(url: url48)]).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition, mapping: TimelineMapping(clips: clips)) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let totalSec = CMTimeGetSeconds(try await out.load(.duration))
        XCTAssertEqual(totalSec, 4.0, accuracy: 0.1,
                       "混在素材の出力尺が合成尺と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "混在素材の書き出しで音声トラックが消えている")
        let firstRMS = try await audioRMS(url: outURL, window: 0.1...1.9)
        let secondRMS = try await audioRMS(url: outURL, window: 2.1...3.9)
        XCTAssertGreaterThan(firstRMS, 0.1, "44.1kHz クリップ区間の音が無い")
        XCTAssertGreaterThan(secondRMS, 0.1, "48kHz クリップ区間の音が無い（フォーマット切替で破綻）")
    }

    /// Major-1 回帰: 写真クリップを**中間**に挟んだ「動画A + 写真 + 動画B」で、
    /// B の音声が合成 [4,6) の正しい位置に載り、写真区間 [2,4) が無音であること。
    /// 修正前はパススルー音声読み（AVAssetReaderTrackOutput）が empty edit を尊重せず、
    /// B の音声が [2,4) へ前ズレして末尾 [4,6) が無音になった（実測。プレビューの
    /// AVPlayer は正しいため、プレビューと書き出しで音位置が食い違っていた）。
    func test_photoBetweenVideos_keepsFollowingAudioPosition() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let videoAURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoAURL) }
        let videoBURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoBURL) }
        let photo = try await makePhotoClip(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }

        let aID = UUID()
        let photoID = UUID()
        let bID = UUID()
        let clips = [
            TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration),
            TimelineClip(sourceID: bID, sourceStart: 0, sourceEnd: 2)
        ]
        let sources: [UUID: AVAsset] = [aID: AVURLAsset(url: videoAURL),
                                        photoID: AVURLAsset(url: photo.url),
                                        bID: AVURLAsset(url: videoBURL)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 6.0, accuracy: 0.2,
                       "動画+写真+動画の出力尺が合成尺と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "写真を中間に挟むと音声トラックが消える")
        let headRMS = try await audioRMS(url: outURL, window: 0.3...1.7)
        let photoRMS = try await audioRMS(url: outURL, window: 2.3...3.7)
        let tailRMS = try await audioRMS(url: outURL, window: 4.3...5.7)
        XCTAssertGreaterThan(headRMS, 0.1, "先頭動画 A の音が載っていない")
        XCTAssertLessThan(photoRMS, 0.03,
                          "写真区間（無音のはず）に音が載っている（B の音声が前ズレ）")
        XCTAssertGreaterThan(tailRMS, 0.1,
                             "後続動画 B の音が [4,6) に載っていない（末尾無音 = 前ズレ）")
    }

    /// Major-1 回帰（rate≠1 併用）: 先頭動画を 2 倍速にした「動画A(2x) + 写真 + 動画B」
    /// でも B の音声が合成 [3,5) の正しい位置に載ること（前ズレの同型バグの固定）。
    func test_photoBetweenVideosWithRate_keepsFollowingAudioPosition() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let videoAURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoAURL) }
        let videoBURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoBURL) }
        let photo = try await makePhotoClip(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }

        let aID = UUID()
        let photoID = UUID()
        let bID = UUID()
        // 合成: A(2s→1s) [0,1) 有音・写真 [1,3) 無音・B [3,5) 有音
        let clips = [
            TimelineClip(sourceID: aID, sourceStart: 0, sourceEnd: 2, rate: 2.0),
            TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration),
            TimelineClip(sourceID: bID, sourceStart: 0, sourceEnd: 2)
        ]
        let sources: [UUID: AVAsset] = [aID: AVURLAsset(url: videoAURL),
                                        photoID: AVURLAsset(url: photo.url),
                                        bID: AVURLAsset(url: videoBURL)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5.0, accuracy: 0.1,
                       "rate 併用の出力尺が合成尺と一致しない")
        let headRMS = try await audioRMS(url: outURL, window: 0.1...0.9)
        let photoRMS = try await audioRMS(url: outURL, window: 1.3...2.7)
        let tailRMS = try await audioRMS(url: outURL, window: 3.3...4.7)
        XCTAssertGreaterThan(headRMS, 0.1, "2 倍速動画 A の音が載っていない")
        XCTAssertLessThan(photoRMS, 0.03,
                          "写真区間（無音のはず）に音が載っている（rate 併用で前ズレ）")
        XCTAssertGreaterThan(tailRMS, 0.1,
                             "後続動画 B の音が [3,5) に載っていない（rate 併用で前ズレ）")
    }

    /// 写真クリップを**末尾**に置いた「動画 + 写真」で、動画の音声位置が保たれ
    /// 写真区間が無音のままであること（現状 pass の挙動を固定。empty edit が末尾に
    /// あるケースも再エンコード経路へ回るため、退行しないことを実測で担保する）。
    func test_photoTrailerAfterVideo_keepsAudioPosition() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let videoURL = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let photo = try await makePhotoClip(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }

        let videoID = UUID()
        let photoID = UUID()
        let clips = [
            TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration)
        ]
        let sources: [UUID: AVAsset] = [videoID: AVURLAsset(url: videoURL),
                                        photoID: AVURLAsset(url: photo.url)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 4.0, accuracy: 0.2,
                       "動画+写真（末尾）の出力尺が合成尺と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "写真を末尾に置くと音声トラックが消える")
        let headRMS = try await audioRMS(url: outURL, window: 0.3...1.7)
        let tailRMS = try await audioRMS(url: outURL, window: 2.3...3.7)
        XCTAssertGreaterThan(headRMS, 0.1, "動画区間の音が載っていない")
        XCTAssertLessThan(tailRMS, 0.03, "末尾の写真区間（無音のはず）に音が載っている")
    }

    /// FaceLandmarking の検出呼び出し回数を数える注入用フェイク
    /// （export の検出は videoQueue 上で走るためロックで保護する）。
    private final class CountingLandmarker: FaceLandmarking, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }
        private func record() {
            lock.lock()
            callCount += 1
            lock.unlock()
        }
        func landmarks(in image: UIImage) -> FaceLandmarkSet? {
            record()
            return nil
        }
        func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? {
            record()
            return nil
        }
        func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] {
            record()
            return []
        }
        func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
            record()
            return []
        }
    }

    private func makeCountingExporter() throws -> (VideoMosaicExporter, CountingLandmarker) {
        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        let landmarker = CountingLandmarker()
        return (VideoMosaicExporter(renderer: renderer, landmarker: landmarker), landmarker)
    }

    /// 写真クリップ区間では t=0 の seed だけが使われ、エクスポート中に
    /// **実検出が一度も走らない**こと（素材時刻 clamp によるキャッシュヒット）。
    /// seed が「顔なし」の空エントリでも実検出には落ちないこと、および
    /// clamp なし（photoSourceIDs 未指定）では実検出が走ること（計測フックの実証）も固定する。
    func test_photoClipExport_neverRunsRealDetection() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let photo = try await makePhotoClip(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: photo.url) }
        let photoID = UUID()
        let clips = [TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: photo.duration)]
        let sources: [UUID: AVAsset] = [photoID: AVURLAsset(url: photo.url)]
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources).composition
        let mapping = TimelineMapping(clips: clips)

        // S11: `applyRanges: []` は「適用なし（全区間 OFF）」なので、そのままだと
        // 全ケースが「ゲートで止まっただけ」の空振りになる。clamp の効果を見るため
        // 全ケースでクリップ全体を覆う区間を渡す。
        let allCovered = MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs: [])

        // 1) seed あり + clamp あり: 実検出ゼロ
        let (exporter, counter) = try makeCountingExporter()
        let outURL = try await exporter.export(
            asset: composition,
            detectionCaches: [photoID: [0.0: [fakeFace(cx: 0.5, cy: 0.5)]]],
            mapping: mapping,
            photoSourceIDs: [photoID],
            applyRanges: allCovered
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(counter.count, 0,
                       "seed 済み写真クリップのエクスポートで実検出が走った（clamp が効いていない）")

        // 2) seed が空エントリ（スキャン済みで顔なし）でも実検出に落ちない
        let (emptySeedExporter, emptySeedCounter) = try makeCountingExporter()
        let emptySeedURL = try await emptySeedExporter.export(
            asset: composition,
            detectionCaches: [photoID: [0.0: []]],
            mapping: mapping,
            photoSourceIDs: [photoID],
            applyRanges: allCovered
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: emptySeedURL) }
        XCTAssertEqual(emptySeedCounter.count, 0,
                       "顔なし seed の写真クリップで毎フレーム実検出が走っている")

        // 3) 対照実験: clamp なし・キャッシュなしなら実検出が走る（計測フックの実証）
        let (controlExporter, controlCounter) = try makeCountingExporter()
        let controlURL = try await controlExporter.export(
            asset: composition,
            mapping: mapping,
            applyRanges: allCovered
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: controlURL) }
        XCTAssertGreaterThan(controlCounter.count, 0,
                             "対照実験で実検出が観測できない（検出カウントのフックが壊れている）")
    }

    /// 出力動画の映像フレームの pts 列（秒）。フレーム数と時刻の同一性検証に使う。
    private func videoPresentationTimes(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            // セグメント境界のマーカーバッファは pts が不定（NaN）で届くことがあるので落とす。
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if pts.isFinite { times.append(pts) }
        }
        return times
    }

    /// S10: モザイク適用区間がエクスポート経路に効いていること。
    ///
    /// 1. 区間外のフレームでは**実検出が一度も走らない**（ゲートが描画経路に届いている証拠。
    ///    素材が単色でモザイクの有無を画素で判別できないため、検出回数を代理指標にする）
    /// 2. それでも**出力フレーム数・pts・尺は区間の有無で一切変わらない**
    ///    （区間外は入力フレームをそのまま書くだけで、落としも縮めもしない）
    func test_applyRange_gatesExportWithoutChangingFrameCountOrDuration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition
        let mapping = TimelineMapping(clips: clips)

        // 1) 全区間を覆う区間（新規プロジェクトの既定状態）: 全編で検出が走る。
        //
        // ⚠️ S11 で `applyRanges: []` の意味が「全区間適用」→「適用なし（全区間 OFF）」へ
        // 反転したため、ベースラインは `fullCoverRanges(for:)` を明示的に渡す。
        let (base, baseCounter) = try makeCountingExporter()
        let baseURL = try await base.export(
            asset: composition, mapping: mapping,
            applyRanges: MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs: [])) { _ in }
        defer { try? FileManager.default.removeItem(at: baseURL) }
        XCTAssertGreaterThan(baseCounter.count, 0)
        let basePTS = try await videoPresentationTimes(of: baseURL)
        XCTAssertGreaterThan(basePTS.count, 0)

        // 2) どのフレームも区間外: 実検出ゼロ。
        //
        // 区間はクリップ使用範囲 [0,2) と**交差させる**こと。交差しない区間（例 [5,6)）は
        // 孤児区間として `MosaicApplyGate.effectiveRanges` に落とされるので、
        // 「帯に 1 本出ているのに全フレーム区間外」という状況を作れない。
        // 代わりに、30fps のフレーム時刻（k/30 秒）の**隙間**に収まる極小区間を使う。
        let (off, offCounter) = try makeCountingExporter()
        let offURL = try await off.export(
            asset: composition, mapping: mapping,
            applyRanges: [MosaicApplyRange(clipID: clips[0].id, sourceID: sourceID,
                                           sourceStart: 1.001, sourceEnd: 1.002)]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: offURL) }
        XCTAssertEqual(offCounter.count, 0, "区間外のフレームで実検出が走っている（ゲート未配線）")
        let offPTS = try await videoPresentationTimes(of: offURL)
        XCTAssertEqual(offPTS.count, basePTS.count, "区間の有無で出力フレーム数が変わっている")
        for (index, pts) in offPTS.enumerated() {
            XCTAssertEqual(pts, basePTS[index], accuracy: 1e-6, "frame \(index) の pts がずれている")
        }

        // 3) 部分区間: 区間内のフレームだけ検出が走る（0 < n < 全体）。
        let (partial, partialCounter) = try makeCountingExporter()
        let partialURL = try await partial.export(
            asset: composition, mapping: mapping,
            applyRanges: [MosaicApplyRange(clipID: clips[0].id, sourceID: sourceID,
                                           sourceStart: 0.5, sourceEnd: 1.0)]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: partialURL) }
        XCTAssertGreaterThan(partialCounter.count, 0, "区間内でも検出が走っていない")
        XCTAssertLessThan(partialCounter.count, baseCounter.count,
                          "部分区間なのに全フレームで検出している")
        let partialPTS = try await videoPresentationTimes(of: partialURL)
        XCTAssertEqual(partialPTS.count, basePTS.count)

        let baseDuration = CMTimeGetSeconds(try await AVURLAsset(url: baseURL).load(.duration))
        let offDuration = CMTimeGetSeconds(try await AVURLAsset(url: offURL).load(.duration))
        XCTAssertEqual(offDuration, baseDuration, accuracy: 0.02, "区間の有無で出力尺が変わっている")
    }

    // MARK: - S10: 重なり区間の素材別ゲート（画素検証）

    /// 8px 市松（黒/白）の動画を作る。**単色素材ではモザイクの有無が画素に出ない**ため、
    /// ブロックモザイクが平均化で必ず灰色へ潰す高周波パターンを素材にする
    /// （素の映像 std ≈ 126.5 / モザイク後 std ≈ 16.4）。
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
                        let value: UInt8 = ((x / 8) + (y / 8)) % 2 == 0 ? 0 : 255
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

    /// 円周に並べた 477 点の合成顔（正規化座標）。
    ///
    /// **477 点**なのはフルメッシュ（478 点）**未満**でコンタマスク経路を確定させるため
    /// （478 点ちょうどだと 3D メッシュ warp 経路に入り、実素材の顔でないと結果が読みにくい）。
    private func makeSyntheticFace(cx: Double, cy: Double, radius: Double) -> FaceLandmarkSet {
        let points = (0..<477).map { index -> FaceLandmark in
            let angle = 2 * Double.pi * Double(index) / 477
            return FaceLandmark(x: Float(cx + radius * cos(angle)),
                                y: Float(cy + radius * sin(angle)))
        }
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// 素材時刻 1/30 秒刻みで同じ顔を詰めた検出キャッシュ（補間・ホールドの穴を排除する）。
    private func denseCache(face: FaceLandmarkSet, seconds: Double) -> [Double: [FaceLandmarkSet]] {
        var cache: [Double: [FaceLandmarkSet]] = [:]
        for index in 0...Int(seconds * Double(fps)) {
            cache[Double(index) / Double(fps)] = [face]
        }
        return cache
    }

    /// 出力動画の各フレームについて、左右 2 つの顔領域の画素を切り出して返す。
    private func facePatches(of url: URL) async throws
    -> [(pts: Double, left: [UInt8], right: [UInt8])] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()
        var result: [(pts: Double, left: [UInt8], right: [UInt8])] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?
                .assumingMemoryBound(to: UInt8.self) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let bufferWidth = CVPixelBufferGetWidth(buffer)
            let bufferHeight = CVPixelBufferGetHeight(buffer)
            // 顔（正規化半径 0.09 の円）の**内側**だけを見る。輪郭の外を混ぜると
            // 素の市松が入って指標が鈍る。
            func patch(centerX: Double) -> [UInt8] {
                var pixels: [UInt8] = []
                let xRange = Int(Double(bufferWidth) * (centerX - 0.05))
                    ..< Int(Double(bufferWidth) * (centerX + 0.05))
                let yRange = Int(Double(bufferHeight) * 0.45)..<Int(Double(bufferHeight) * 0.55)
                for y in yRange {
                    for x in xRange {
                        pixels.append(base[y * bytesPerRow + x * 4])
                    }
                }
                return pixels
            }
            result.append((pts, patch(centerX: 0.25), patch(centerX: 0.75)))
        }
        return result
    }

    /// パッチの輝度標準偏差。素の 8px 市松は高く（≈126）、ブロックモザイクが
    /// 乗ると平均化されて低くなる（≈16）。
    ///
    /// 「モザイク無し書き出しとの画素差」ではなくこの指標を使う理由: H.264 は
    /// フレーム間予測なので、画面の一部にモザイクが乗るだけで**乗っていない領域の
    /// 復号結果まで数値が動く**（実測: 完全に同一内容のはずの領域で MAD 6.875）。
    /// 標準偏差なら「高周波が残っているか」だけを見るので、符号化ノイズに鈍い。
    private func luminanceStdDev(_ pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return .nan }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
            / Double(pixels.count)
        return variance.squareRoot()
    }

    /// **S10 レビュー修正: 重なり区間で、適用区間ゼロの素材の顔にモザイクが乗らないこと。**
    ///
    /// 素材 A（顔は画面左）だけを適用区間にして A→B のクロスフェードを書き出す。
    /// 修正前は重なり区間で `transitionFaces` が両素材の顔を無条件に union していたため、
    /// **素材 B（区間ゼロ）の顔（画面右）にもモザイクが焼き込まれていた**
    /// （実測: 重なり 15 フレーム中 12 フレームで右側 MAD が 25.8 → 95.9〜105.7 へ跳ねた）。
    /// プレビューは同条件で B の顔を出さないので、プレビューと書き出しが食い違い、
    /// ユーザーは書き出すまで気づけない。
    ///
    /// 判定は顔領域内の輝度標準偏差で行う（`luminanceStdDev` の doc 参照）。
    /// 区間指定なし（＝両素材にモザイク）の書き出しを対照に置き、
    /// **右側にモザイクが乗れば検出できる計測系である**ことも同時に固定する。
    func test_applyRange_doesNotMosaicOutOfRangeSourceInsideTransitionOverlap() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let clipSeconds = 2.0
        let urlA = try await makeCheckerboardVideo(seconds: clipSeconds)
        let urlB = try await makeCheckerboardVideo(seconds: clipSeconds)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let sourceA = UUID()
        let sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: clipSeconds)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: clipSeconds)
        let transitions = [clipA.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        let built = try await TimelineCompositionBuilder()
            .build(clips: [clipA, clipB], transitions: transitions,
                   sources: [sourceA: AVURLAsset(url: urlA), sourceB: AVURLAsset(url: urlB)])
        let mapping = TimelineMapping(clips: [clipA, clipB], transitions: transitions)
        let overlap = try XCTUnwrap(mapping.overlaps.first, "クロスフェードの重なりが作られていない")
        let caches = [
            sourceA: denseCache(face: makeSyntheticFace(cx: 0.25, cy: 0.5, radius: 0.09),
                                seconds: clipSeconds),
            sourceB: denseCache(face: makeSyntheticFace(cx: 0.75, cy: 0.5, radius: 0.09),
                                seconds: clipSeconds)
        ]

        func export(applyRanges: [MosaicApplyRange], faceEnabled: Bool) async throws -> URL {
            try await makeExporter().export(
                asset: built.composition, detectionCaches: caches, mapping: mapping,
                applyRanges: applyRanges, videoComposition: built.videoComposition,
                faceEnabled: faceEnabled) { _ in }
        }

        // 対照（両方にモザイク）は「全クリップを覆う区間」で作る。S11 で `[]` の意味が
        // 「全区間適用」→「適用なし」へ反転したため、空配列ではベースラインにならない。
        let bothURL = try await export(
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: []), faceEnabled: true)
        let gatedURL = try await export(
            applyRanges: [MosaicApplyRange(clipID: clipA.id, sourceID: sourceA,
                                           sourceStart: 0, sourceEnd: clipSeconds)],
            faceEnabled: true)
        defer {
            for url in [bothURL, gatedURL] { try? FileManager.default.removeItem(at: url) }
        }

        let both = try await facePatches(of: bothURL)
        let gated = try await facePatches(of: gatedURL)
        XCTAssertEqual(both.count, gated.count)

        // モザイクの有無を分ける閾値。実測は「乗っている ≈ 16 / 乗っていない ≈ 126」なので
        // どちらからも十分離れた値を採る。
        let mosaicMax = 60.0
        let rawMin = 90.0
        // 重なりの先頭数フレームは、対照（区間指定なし）でも右側にモザイクが乗らない:
        // incoming 側は progress=0 で不透明度 0 のため `visibleLandmarks` が空を返し、
        // 次の検出更新（検出間引き）まで union に入らないからである。レビューの実測でも
        // 重なり 15 フレームのうち先頭 3 フレームは両条件で off だった。
        // したがって「**対照で右にモザイクが乗るフレーム**でのみ」区間外側を検証する。
        var comparableFrames = 0
        for index in gated.indices where
            gated[index].pts >= overlap.start && gated[index].pts < overlap.end {
            let pts = gated[index].pts
            // 区間内の素材（A）には重なり中も必ずモザイクが乗る。
            XCTAssertLessThan(luminanceStdDev(gated[index].left), mosaicMax,
                              "区間内の素材（A）にモザイクが乗っていない pts=\(pts)")
            guard luminanceStdDev(both[index].right) < mosaicMax else { continue }
            comparableFrames += 1
            XCTAssertGreaterThan(luminanceStdDev(gated[index].right), rawMin,
                                 "区間外の素材（B）の顔にモザイクが焼き込まれている "
                                 + "pts=\(pts) std=\(luminanceStdDev(gated[index].right))")
        }
        XCTAssertGreaterThanOrEqual(comparableFrames, 10,
                                    "対照実験で右側にモザイクが乗るフレームが取れていない"
                                    + "（計測系が壊れている）")

        // 重なり**外**（素材 B 単独区間）も従来どおり OFF のままであること。
        for index in gated.indices where gated[index].pts >= overlap.end {
            XCTAssertGreaterThan(luminanceStdDev(gated[index].right), rawMin,
                                 "重なり外の区間外フレームにモザイクが乗っている pts=\(gated[index].pts)")
        }
    }

    // MARK: - 書き出しのキャンセル

    /// `temporaryDirectory` にある書き出し中間ファイル（`mosaic-*.mp4`）の一覧。
    private func mosaicTempFiles() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(names.filter { $0.hasPrefix("mosaic-") })
    }

    /// 書き出し中に `cancel()` を呼ぶと `CancellationError` が throw され、
    /// 打ち切られた部分ファイル（`mosaic-*.mp4`）が tmp に残らないこと。
    ///
    /// 中断フラグと `cancelReading()` は**両方**必要:
    /// フラグだけでは `copyNextSampleBuffer()` がブロックしたまま戻らず、
    /// `cancelReading()` だけでは `group.notify` が `.cancelled` を `.failed` と
    /// 区別できずに部分ファイルが「成功」として返る（＝ Photos に保存される）。
    func test_cancelDuringExport_throwsCancellationErrorAndLeavesNoPartialFile() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // 4.0s より長くしないこと: `appendSineAudio` は映像より先に音声を全部
        // 積むため、writer のバッファ上限を超えると `isReadyForMoreMediaData` が
        // 戻らなくなり**素材生成の時点でハングする**（6.0s で実測）。
        let url = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // 同じ素材を 3 本並べて合成尺 12s（= 360 フレーム）にする。素材そのものを
        // 長くすると上記のハングに当たるので、クリップ数で書き出し時間を稼ぐ。
        // 中断までの実測レイテンシ（≈0.12s）に対して書き出し全体（≈1s）が十分長くないと
        // 「キャンセルより先に完走してしまう」競合でテストが不安定になる。
        let sourceID = UUID()
        let clips = (0..<3).map { _ in
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        }
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let before = mosaicTempFiles()
        let exporter = try makeExporter()
        // 最初の進捗通知（＝ 1 フレーム目を書いた時点）でキャンセルする。
        let started = expectation(description: "書き出しが始まった")
        started.assertForOverFulfill = false

        let task = Task { () -> URL in
            try await exporter.export(asset: composition, mapping: TimelineMapping(clips: clips)) { _ in
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 60)
        let cancelledAt = CFAbsoluteTimeGetCurrent()
        exporter.cancel()

        do {
            let outURL = try await task.value
            try? FileManager.default.removeItem(at: outURL)
            XCTFail("キャンセルしたのに書き出しが成功として返った: \(outURL.lastPathComponent)")
        } catch is CancellationError {
            print(String(format: "[TEST] cancel latency = %.3fs",
                         CFAbsoluteTimeGetCurrent() - cancelledAt))
        } catch {
            XCTFail("CancellationError 以外が throw された: \(error)")
        }

        let leftovers = mosaicTempFiles().subtracting(before)
        XCTAssertTrue(leftovers.isEmpty,
                      "中断された部分ファイルが tmp に残っている: \(leftovers.sorted())")
    }

    /// 同一インスタンスを再利用しても、前回のキャンセル要求が次の書き出しに
    /// 持ち越されないこと（`export` 冒頭で中断状態をリセットしている）。
    func test_exporterReuseAfterCancel_completesNextExport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)]).composition

        let exporter = try makeExporter()
        // 書き出し前に cancel を撃っておく（フラグが残っていれば次も落ちる）。
        exporter.cancel()
        let outURL = try await exporter.export(
            asset: composition, mapping: TimelineMapping(clips: clips)) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let duration = try await AVURLAsset(url: outURL).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.2,
                       "再利用した exporter の書き出しが完走していない")
    }

    // MARK: - S11: 全機能結合の E2E / 性能 / 音声ピッチ

    /// 8px 市松 + 440Hz サイン波の動画。E2E で「画素（モザイクの有無）」と
    /// 「音声（トラック存続・位置）」を同じ素材で同時に見るために使う。
    private func makeCheckerboardVideoWithSine(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(videoInput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        try appendSineAudio(to: audioInput, seconds: seconds)
        audioInput.markAsFinished()

        for i in 0..<Int(seconds * Double(fps)) {
            while !videoInput.isReadyForMoreMediaData {
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
                        let value: UInt8 = ((x / 8) + (y / 8)) % 2 == 0 ? 0 : 255
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
        videoInput.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 8px 市松の写真クリップ（単色だとモザイクの有無が画素に出ないため）。
    private func makeCheckerboardPhotoClip(seconds: Double) async throws
    -> PhotoClipEncoder.EncodedPhotoClip {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                            format: format).image { ctx in
            for y in 0..<(height / 8) {
                for x in 0..<(width / 8) {
                    let dark = (x + y) % 2 == 0
                    (dark ? UIColor.black : UIColor.white).setFill()
                    ctx.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
                }
            }
        }
        return try await PhotoClipEncoder().encode(image: image, seconds: seconds)
    }

    /// **A. 全機能結合の E2E（S11 最終検証項目）**。
    ///
    /// 動画 2 本 + 写真 1 枚を、分割・並べ替え・速度変更（0.5x / 2x）・
    /// トランジション 2 種（クロスフェード + ワイプ）・モザイク適用区間指定
    /// の全部盛りで書き出し、次を実測で固定する:
    ///
    /// 1. 合成尺が「速度スケール後の各クリップ尺の総和 − トランジションの重なり」と一致
    /// 2. 出力の pts 列が単調増加で、フレーム間隔に破綻（脱落・重複）が無い
    /// 3. **モザイクが適用区間を指定したクリップにだけ乗る**（顔領域の輝度 std で判定）
    /// 4. 音声トラックが 1 本残り、尺が映像と揃う
    func test_S11_e2e_twoVideosPlusPhoto_reorderRateTransitionApplyRange() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let urlA = try await makeCheckerboardVideoWithSine(seconds: 4.0)
        let urlB = try await makeCheckerboardVideoWithSine(seconds: 4.0)
        let photo = try await makeCheckerboardPhotoClip(seconds: 3.0)
        defer {
            for url in [urlA, urlB, photo.url] { try? FileManager.default.removeItem(at: url) }
        }

        let sourceA = UUID(), sourceB = UUID(), sourcePhoto = UUID()
        // 「A を [0,2)/[2,4) に分割して後半だけ残し、B と写真を後ろに並べた」状態。
        // clip0: A[2,4) を 0.5x → 4.0s / clip1: B[0,4) を 2x → 2.0s / clip2: 写真 3.0s
        let clip0 = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4, rate: 0.5)
        let clip1 = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4, rate: 2.0)
        let clip2 = TimelineClip(sourceID: sourcePhoto, sourceStart: 0, sourceEnd: photo.duration)
        let clips = [clip0, clip1, clip2]
        let transitions = [
            clip0.id: TransitionSpec(kind: .crossfade, duration: 0.5),
            clip1.id: TransitionSpec(kind: .wipeLeft, duration: 0.5)
        ]
        let sources: [UUID: AVAsset] = [
            sourceA: AVURLAsset(url: urlA), sourceB: AVURLAsset(url: urlB),
            sourcePhoto: AVURLAsset(url: photo.url)
        ]
        let built = try await TimelineCompositionBuilder()
            .build(clips: clips, transitions: transitions, sources: sources)
        let mapping = TimelineMapping(clips: clips, transitions: transitions)

        // 1) 合成尺: 4.0 + 2.0 + 3.0 − 0.5 − 0.5 = 8.0s
        XCTAssertEqual(clip0.duration, 4.0, accuracy: 1e-9)
        XCTAssertEqual(clip1.duration, 2.0, accuracy: 1e-9)
        XCTAssertEqual(mapping.totalDuration, 8.0, accuracy: 1e-6,
                       "写像の合成尺が「速度スケール後の総和 − 重なり」になっていない")
        let compositionDuration = CMTimeGetSeconds(try await built.composition.load(.duration))
        XCTAssertEqual(compositionDuration, 8.0, accuracy: 0.1,
                       "AVComposition の実尺が写像の合成尺と食い違っている")
        XCTAssertEqual(mapping.overlaps.count, 2, "トランジション 2 本ぶんの重なりが作られていない")

        // 適用区間: clip1（B・顔は画面右）と clip2（写真・顔は画面左）だけ ON。
        // clip0（A・顔は画面左）は帯を一切置かない = OFF。
        let applyRanges = [
            MosaicApplyRange(clipID: clip1.id, sourceID: sourceB, sourceStart: 0, sourceEnd: 4),
            MosaicApplyRange(clipID: clip2.id, sourceID: sourcePhoto,
                             sourceStart: 0, sourceEnd: photo.duration)
        ]
        let caches = [
            sourceA: denseCache(face: makeSyntheticFace(cx: 0.25, cy: 0.5, radius: 0.09),
                                seconds: 4.0),
            sourceB: denseCache(face: makeSyntheticFace(cx: 0.75, cy: 0.5, radius: 0.09),
                                seconds: 4.0),
            sourcePhoto: [0.0: [makeSyntheticFace(cx: 0.25, cy: 0.5, radius: 0.09)]]
        ]

        let started = CFAbsoluteTimeGetCurrent()
        let outURL = try await makeExporter().export(
            asset: built.composition, detectionCaches: caches, mapping: mapping,
            photoSourceIDs: [sourcePhoto], applyRanges: applyRanges,
            videoComposition: built.videoComposition, audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let out = AVURLAsset(url: outURL)
        let outDuration = CMTimeGetSeconds(try await out.load(.duration))
        XCTAssertEqual(outDuration, 8.0, accuracy: 0.2, "出力尺が合成尺と一致しない")

        // 2) pts 列の連続性
        // ⚠️ pts は**デコード済みフレーム**（`facePatches`）で採ること。
        // `videoPresentationTimes`（無変換パススルー読み）には非画フレームの
        // マーカーバッファが混ざり、pts=0 の重複と末尾 1 枚の水増しが必ず出る
        // （`test_S11_diag_duplicatePTSByConfiguration` で全構成に共通と実測済み）。
        let patches = try await facePatches(of: outURL)
        let pts = patches.map(\.pts).sorted()
        XCTAssertGreaterThan(pts.count, 100, "出力フレームが極端に少ない")
        var deltas: [Double] = []
        var duplicates = 0
        for index in 1..<pts.count {
            let delta = pts[index] - pts[index - 1]
            if delta <= 1e-9 { duplicates += 1 }
            deltas.append(delta)
        }
        let sortedDeltas = deltas.sorted()
        let median = sortedDeltas[sortedDeltas.count / 2]
        let maxDelta = sortedDeltas.last ?? 0
        var histogram: [Int: Int] = [:]
        for delta in deltas { histogram[Int((delta * 600).rounded()), default: 0] += 1 }
        print(String(format:
            "[S11-E2E] frames=%d duration=%.3f 先頭pts=%.4f 末尾pts=%.4f "
            + "medianΔ=%.5f maxΔ=%.5f 重複pts=%d export=%.2fs",
            pts.count, outDuration, pts.first ?? -1, pts.last ?? -1,
            median, maxDelta, duplicates, elapsed))
        print("[S11-E2E] Δヒストグラム(1/600秒単位)=\(histogram.sorted { $0.key < $1.key })")
        XCTAssertEqual(duplicates, 0, "同じ pts のフレームが重複して書かれている")
        XCTAssertLessThan(maxDelta, median * 2.5,
                          "pts に飛び（フレーム脱落）がある max=\(maxDelta) median=\(median)")
        XCTAssertLessThan(pts.first ?? 1, 0.05, "先頭フレームの pts が 0 付近から始まっていない")
        XCTAssertGreaterThan(pts.last ?? 0, outDuration - 3 * median,
                             "末尾フレームが合成尺の手前で途切れている")

        // 3) 画素検証: 適用区間の有無どおりにモザイクが乗ること
        let mosaicMax = 60.0
        let rawMin = 90.0
        func stats(_ window: Range<Double>, left: Bool) -> [Double] {
            patches.filter { window.contains($0.pts) }
                .map { luminanceStdDev(left ? $0.left : $0.right) }
        }
        // clip0 単独区間 [0, 3.5) → 顔は左。適用区間ゼロなので素のまま。
        let clip0Left = stats(0.2..<3.3, left: true)
        XCTAssertGreaterThanOrEqual(clip0Left.count, 30, "clip0 単独区間のフレームが取れていない")
        // clip1 単独区間 [4.0, 5.0) → 顔は右。適用区間 ON なのでモザイク。
        let clip1Right = stats(4.1..<4.9, left: false)
        XCTAssertGreaterThanOrEqual(clip1Right.count, 10, "clip1 単独区間のフレームが取れていない")
        // clip2（写真）単独区間 [5.5, 8.0) → 顔は左。適用区間 ON なのでモザイク。
        let photoLeft = stats(5.7..<7.8, left: true)
        XCTAssertGreaterThanOrEqual(photoLeft.count, 20, "写真クリップ区間のフレームが取れていない")

        print(String(format: "[S11-E2E] std clip0(OFF,左)=%.1f clip1(ON,右)=%.1f photo(ON,左)=%.1f",
                     clip0Left.reduce(0, +) / Double(clip0Left.count),
                     clip1Right.reduce(0, +) / Double(clip1Right.count),
                     photoLeft.reduce(0, +) / Double(photoLeft.count)))

        for value in clip0Left {
            XCTAssertGreaterThan(value, rawMin,
                                 "適用区間を置いていない clip0 の顔にモザイクが乗っている std=\(value)")
        }
        for value in clip1Right {
            XCTAssertLessThan(value, mosaicMax,
                              "適用区間 ON の clip1 の顔にモザイクが乗っていない std=\(value)")
        }
        for value in photoLeft {
            XCTAssertLessThan(value, mosaicMax,
                              "適用区間 ON の写真クリップにモザイクが乗っていない std=\(value)")
        }

        // 4) 音声
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "全部盛り構成で音声トラックが消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            let audioEnd = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
            print(String(format: "[S11-E2E] 出力 audio start=%.4f dur=%.4f",
                         CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.duration)))
            // 末尾クリップ（写真）は音声を持たないので、音声トラックは最後の
            // 有音クリップの終端（合成 5.5s）までしか伸びない。映像側 8.0s との差は
            // 無音であり、AVFoundation の合成でも同じ（composition の音声トラックも 5.5s）。
            XCTAssertGreaterThan(audioEnd, 5.4,
                                 "最後の有音クリップ（B）の終端まで音声が届いていない")
            XCTAssertLessThanOrEqual(audioEnd, 8.1, "音声が映像より長い（尺超過）")
        }
        // clip0（A）本体と clip1（B）本体の両方に音が載っていること。
        let clip0RMS = try await audioRMS(url: outURL, window: 0.3...3.0)
        let clip1RMS = try await audioRMS(url: outURL, window: 4.1...4.9)
        let photoRMS = try await audioRMS(url: outURL, window: 5.8...7.8)
        print(String(format: "[S11-E2E] rms clip0=%.3f clip1=%.3f photo=%.3f",
                     clip0RMS, clip1RMS, photoRMS))
        XCTAssertGreaterThan(clip0RMS, 0.1, "先行クリップの音が載っていない")
        XCTAssertGreaterThan(clip1RMS, 0.1,
                             "後続クリップ（トランジション越しの B 側）の音が載っていない")
        XCTAssertLessThan(photoRMS, 0.03, "無音のはずの写真区間に音が載っている")
    }

    /// 構成別の**デコード済み出力フレーム数**と pts の健全性を固定する。
    ///
    /// ⚠️ 計測の落とし穴（S11 で実測）: `videoPresentationTimes`（`outputSettings: nil` の
    /// パススルー読み）は非画フレームのマーカーバッファまで拾うため、**どの構成でも
    /// 必ず pts=0 の重複 1 件と末尾 1 枚の水増しが出る**（＝出力ファイルの欠陥ではない）。
    /// フレーム数・連続性を検証するときは必ずデコードして読むこと。
    func test_S11_decodedFrameCountAndPTSByConfiguration() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let urlA = try await makeTestVideo(seconds: 2.0, withAudio: false)
        let urlB = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let sourceA = UUID(), sourceB = UUID()
        let assets: [UUID: AVAsset] = [sourceA: AVURLAsset(url: urlA), sourceB: AVURLAsset(url: urlB)]

        func report(_ label: String, clips: [TimelineClip],
                    transitions: [UUID: TransitionSpec],
                    expectedFrames: Int) async throws -> Int {
            let built = try await TimelineCompositionBuilder()
                .build(clips: clips, transitions: transitions, sources: assets)
            let outURL = try await makeExporter().export(
                asset: built.composition,
                mapping: TimelineMapping(clips: clips, transitions: transitions),
                videoComposition: built.videoComposition, audioMix: built.audioMix,
                renderLayout: built.layout) { _ in }
            defer { try? FileManager.default.removeItem(at: outURL) }
            let pts = try await videoPresentationTimes(of: outURL).sorted()
            let dups = (1..<max(pts.count, 2)).filter { pts[$0] - pts[$0 - 1] <= 1e-9 }
            // デコードして読む経路（マーカーバッファが混ざらない）と突き合わせる。
            let decoded = try await facePatches(of: outURL).map(\.pts).sorted()
            let decodedDups = (1..<max(decoded.count, 2))
                .filter { decoded[$0] - decoded[$0 - 1] <= 1e-9 }
            print(String(format: "[S11-DIAG]   ↳ デコード読み frames=%d 重複=%d",
                         decoded.count, decodedDups.count))
            let frameDuration = built.videoComposition
                .map { CMTimeGetSeconds($0.frameDuration) } ?? -1
            print(String(format:
                "[S11-DIAG] %@ vc=%@ frameDur=%.5f 生frames=%d 生重複=%d 末尾=%.4f",
                label, built.videoComposition == nil ? "nil" : "attach",
                frameDuration, pts.count, dups.count, pts.last ?? -1))
            XCTAssertEqual(decodedDups.count, 0,
                           "\(label): デコード済み出力に同一 pts のフレームがある")
            XCTAssertEqual(decoded.count, expectedFrames,
                           "\(label): デコード済み出力フレーム数が想定と違う")
            // パススルー読みの水増しは「マーカーバッファ由来」であることの実証。
            // デコード読みと必ず一致しないが、その差は毎回 2 枚（重複 1 + 末尾 1）。
            XCTAssertEqual(pts.count - decoded.count, 2,
                           "\(label): パススルー読みとデコード読みの差が想定（2枚）と違う")
            return dups.count
        }

        let single = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)]
        _ = try await report("単一クリップ・無変換", clips: single, transitions: [:],
                             expectedFrames: 60)

        let two = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2),
                   TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 2)]
        _ = try await report("2クリップ・トランジション無し", clips: two, transitions: [:],
                             expectedFrames: 120)
        _ = try await report("2クリップ・クロスフェード", clips: two,
                             transitions: [two[0].id: TransitionSpec(kind: .crossfade,
                                                                     duration: 0.5)],
                             expectedFrames: 105)

        let rated = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2, rate: 0.5)]
        _ = try await report("単一クリップ・rate 0.5", clips: rated, transitions: [:],
                             expectedFrames: 60)

        let mixed = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2, rate: 0.5),
                     TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        _ = try await report("rate 混在 0.5x+2x・トランジション無し", clips: mixed,
                             transitions: [:], expectedFrames: 90)
        _ = try await report("rate 混在 0.5x+2x・クロスフェード", clips: mixed,
                             transitions: [mixed[0].id: TransitionSpec(kind: .crossfade,
                                                                       duration: 0.5)],
                             expectedFrames: 83)
    }

    // MARK: - C. 音声のピッチ保持（440Hz サイン波の FFT）

    /// 出力音声の指定窓を PCM（モノラル Float）で取り出す。
    private func audioSamples(url: URL, window: ClosedRange<Double>) async throws
    -> (samples: [Float], sampleRate: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return ([], 0)
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        var rate = 0.0
        while let sample = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { continue }
            rate = asbd.mSampleRate
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            var lengthAtOffset = 0, totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0,
                                        lengthAtOffsetOut: &lengthAtOffset,
                                        totalLengthOut: &totalLength,
                                        dataPointerOut: &dataPointer)
            guard let dataPointer, lengthAtOffset == totalLength else { continue }
            let frameCount = totalLength / (2 * channels)
            dataPointer.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) { ptr in
                for frame in 0..<frameCount {
                    let t = start + Double(frame) / rate
                    guard window.contains(t) else { continue }
                    samples.append(Float(ptr[frame * channels]) / 32768.0)
                }
            }
        }
        return (samples, rate)
    }

    /// Hann 窓 + 実数 FFT でスペクトルのピーク周波数（Hz）を返す。
    private func dominantFrequency(samples: [Float], sampleRate: Double) -> Double {
        let count = 1 << Int(floor(log2(Double(samples.count))))
        guard count >= 4096, sampleRate > 0 else { return .nan }
        let log2n = vDSP_Length(log2(Double(count)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return .nan }
        defer { vDSP_destroy_fftsetup(setup) }

        var input = Array(samples.prefix(count))
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(count))

        let half = count / 2
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: half)
        defer { realp.deallocate(); imagp.deallocate() }
        realp.initialize(repeating: 0, count: half)
        imagp.initialize(repeating: 0, count: half)
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        input.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        var magnitudes = [Float](repeating: 0, count: half)
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))

        var peakIndex = 1
        var peak: Float = 0
        // DC 近傍（index 0,1）は窓のリークで大きくなるので除く。
        for index in 2..<half where magnitudes[index] > peak {
            peak = magnitudes[index]
            peakIndex = index
        }
        return Double(peakIndex) * sampleRate / Double(count)
    }

    /// **C. 速度変更でピッチが保たれること**（`.spectral` の実効検証）。
    ///
    /// 440Hz のサイン波素材を rate=2 / rate=0.5 で書き出し、FFT のピークが
    /// **440Hz のまま**であることを確認する。ピッチシフト（`.varispeed` 相当）なら
    /// rate=2 で 880Hz、rate=0.5 で 220Hz に出る。
    func test_S11_rateChangePreservesPitch_440HzStaysAt440Hz() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 4.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()

        func exportAt(rate: Double) async throws -> URL {
            let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4, rate: rate)]
            let built = try await TimelineCompositionBuilder()
                .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])
            return try await makeExporter().export(
                asset: built.composition, mapping: TimelineMapping(clips: clips),
                videoComposition: built.videoComposition, audioMix: built.audioMix,
                renderLayout: built.layout) { _ in }
        }

        // 対照: 等倍書き出しの計測系が 440Hz を返すこと。
        let baseURL = try await exportAt(rate: 1.0)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let base = try await audioSamples(url: baseURL, window: 0.3...3.7)
        let baseFreq = dominantFrequency(samples: base.samples, sampleRate: base.sampleRate)
        print(String(format: "[S11-PITCH] rate=1.0 sr=%.0f n=%d peak=%.1fHz",
                     base.sampleRate, base.samples.count, baseFreq))
        XCTAssertEqual(baseFreq, 440, accuracy: 15, "計測系が素材の 440Hz を検出できていない")

        // rate=2: 尺が半分、ピッチは 440Hz のまま。
        let fastURL = try await exportAt(rate: 2.0)
        defer { try? FileManager.default.removeItem(at: fastURL) }
        let fastDuration = CMTimeGetSeconds(try await AVURLAsset(url: fastURL).load(.duration))
        XCTAssertEqual(fastDuration, 2.0, accuracy: 0.15, "rate=2 で尺が半分になっていない")
        let fast = try await audioSamples(url: fastURL, window: 0.2...1.8)
        let fastFreq = dominantFrequency(samples: fast.samples, sampleRate: fast.sampleRate)
        print(String(format: "[S11-PITCH] rate=2.0 dur=%.3f n=%d peak=%.1fHz",
                     fastDuration, fast.samples.count, fastFreq))
        XCTAssertEqual(fastFreq, 440, accuracy: 20,
                       "rate=2 で基本周波数がずれた（ピッチシフトしている。880Hz なら varispeed）")

        // rate=0.5: 尺が倍、ピッチは 440Hz のまま。
        let slowURL = try await exportAt(rate: 0.5)
        defer { try? FileManager.default.removeItem(at: slowURL) }
        let slowDuration = CMTimeGetSeconds(try await AVURLAsset(url: slowURL).load(.duration))
        XCTAssertEqual(slowDuration, 8.0, accuracy: 0.2, "rate=0.5 で尺が倍になっていない")
        let slow = try await audioSamples(url: slowURL, window: 0.5...7.5)
        let slowFreq = dominantFrequency(samples: slow.samples, sampleRate: slow.sampleRate)
        print(String(format: "[S11-PITCH] rate=0.5 dur=%.3f n=%d peak=%.1fHz",
                     slowDuration, slow.samples.count, slowFreq))
        XCTAssertEqual(slowFreq, 440, accuracy: 20,
                       "rate=0.5 で基本周波数がずれた（220Hz なら varispeed）")
    }

    // MARK: - B. 性能計測

    /// **B-1. 速度変更の両端（0.1x / 10x）の書き出し**。
    ///
    /// 0.1x はフレーム洪水（合成尺 10 倍 = 書くフレームが 10 倍）、
    /// 10x は間延び（素材を 10 倍の速さで読み飛ばす）の両端。
    /// 所要時間・出力尺・出力フレーム数を実測値として残す。
    func test_S11_perf_extremeRates_010x_and_10x() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 2.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()

        func measure(rate: Double, expected: Double) async throws {
            let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: rate)]
            let built = try await TimelineCompositionBuilder()
                .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])
            let started = CFAbsoluteTimeGetCurrent()
            let outURL = try await makeExporter().export(
                asset: built.composition, mapping: TimelineMapping(clips: clips),
                applyRanges: MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs: []),
                videoComposition: built.videoComposition, audioMix: built.audioMix,
                renderLayout: built.layout) { _ in }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            defer { try? FileManager.default.removeItem(at: outURL) }

            let duration = CMTimeGetSeconds(try await AVURLAsset(url: outURL).load(.duration))
            let pts = try await videoPresentationTimes(of: outURL)
            let audioTracks = try await AVURLAsset(url: outURL).loadTracks(withMediaType: .audio)
            print(String(format:
                "[S11-PERF] rate=%.2f wall=%.2fs 出力尺=%.3fs frames=%d 実効fps=%.1f audio=%d",
                rate, elapsed, duration, pts.count,
                Double(pts.count) / max(duration, 0.001), audioTracks.count))
            XCTAssertEqual(duration, expected, accuracy: max(0.2, expected * 0.05),
                           "rate=\(rate) の出力尺が想定と違う")
            XCTAssertGreaterThan(pts.count, 0, "rate=\(rate) で出力フレームが 0")
            XCTAssertEqual(audioTracks.count, 1, "rate=\(rate) で音声トラックが消えている")
            XCTAssertLessThan(elapsed, 180,
                              "rate=\(rate) の書き出しが 3 分を超えた（実用外）")
        }

        try await measure(rate: 0.1, expected: 20.0)
        try await measure(rate: 10.0, expected: 0.2)
    }

    /// 指定解像度の単色動画（4K 計測用）。
    private func makeSolidVideo(pixelWidth: Int, pixelHeight: Int,
                                seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, pixelWidth, pixelHeight,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(0x30 + (i % 2) * 0x50),
                   CVPixelBufferGetBytesPerRow(buffer) * pixelHeight)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// **B-2. 4K 素材どうしのトランジション書き出し**。
    ///
    /// トランジション区間は 2 系統のデコードが同時に走る（A/B トラック）。
    /// 4K で完走するか・どれくらい掛かるかを実測する。
    func test_S11_perf_4KTransitionExport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let urlA = try await makeSolidVideo(pixelWidth: 3840, pixelHeight: 2160, seconds: 1.5)
        let urlB = try await makeSolidVideo(pixelWidth: 3840, pixelHeight: 2160, seconds: 1.5)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let sourceA = UUID(), sourceB = UUID()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 1.5)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 1.5)
        let transitions = [clipA.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        let built = try await TimelineCompositionBuilder().build(
            clips: [clipA, clipB], transitions: transitions,
            sources: [sourceA: AVURLAsset(url: urlA), sourceB: AVURLAsset(url: urlB)])
        XCTAssertEqual(built.outputSize, CGSize(width: 3840, height: 2160),
                       "4K 素材なのに出力解像度が 4K でない")

        let caches = [
            sourceA: denseCache(face: makeSyntheticFace(cx: 0.3, cy: 0.5, radius: 0.09),
                                seconds: 1.5),
            sourceB: denseCache(face: makeSyntheticFace(cx: 0.7, cy: 0.5, radius: 0.09),
                                seconds: 1.5)
        ]
        // 対照: 同じ 4K 素材 2 本を**トランジション無し**で連結した書き出し
        // （2 系統デコードが同時に走らない構成）。所要時間の差がトランジションのコスト。
        let plainBuilt = try await TimelineCompositionBuilder().build(
            clips: [clipA, clipB],
            sources: [sourceA: AVURLAsset(url: urlA), sourceB: AVURLAsset(url: urlB)])
        let plainStarted = CFAbsoluteTimeGetCurrent()
        let plainURL = try await makeExporter().export(
            asset: plainBuilt.composition,
            mapping: TimelineMapping(clips: [clipA, clipB]),
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: []),
            videoComposition: plainBuilt.videoComposition, audioMix: plainBuilt.audioMix,
            renderLayout: plainBuilt.layout) { _ in }
        let plainElapsed = CFAbsoluteTimeGetCurrent() - plainStarted
        defer { try? FileManager.default.removeItem(at: plainURL) }
        let plainDuration = CMTimeGetSeconds(try await AVURLAsset(url: plainURL).load(.duration))
        let plainFrames = try await videoPresentationTimes(of: plainURL).count
        print(String(format:
            "[S11-PERF-4K] 対照(トランジション無し) wall=%.2fs 尺=%.3fs frames=%d 実時間比=%.2fx",
            plainElapsed, plainDuration, plainFrames,
            plainElapsed / max(plainDuration, 0.001)))

        let started = CFAbsoluteTimeGetCurrent()
        let outURL = try await makeExporter().export(
            asset: built.composition, detectionCaches: caches,
            mapping: TimelineMapping(clips: [clipA, clipB], transitions: transitions),
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clipA, clipB], photoSourceIDs: []),
            videoComposition: built.videoComposition, audioMix: built.audioMix,
            renderLayout: built.layout) { _ in }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        defer { try? FileManager.default.removeItem(at: outURL) }

        let duration = CMTimeGetSeconds(try await AVURLAsset(url: outURL).load(.duration))
        let pts = try await videoPresentationTimes(of: outURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        print(String(format:
            "[S11-PERF-4K] wall=%.2fs 尺=%.3fs frames=%d 実時間比=%.2fx bytes=%d",
            elapsed, duration, pts.count, elapsed / max(duration, 0.001), bytes))
        XCTAssertEqual(duration, 2.5, accuracy: 0.2,
                       "4K トランジションの出力尺が合成尺（1.5+1.5−0.5）と違う")
        XCTAssertGreaterThan(pts.count, 30, "4K トランジション書き出しのフレームが少なすぎる")

        let outTracks = try await AVURLAsset(url: outURL).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(outTracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 3840, height: 2160),
                       "4K で書き出したのに出力解像度が落ちている")
    }
}

/// S10b: 出力解像度の可視化（`Built.outputSize` / `hasDownscaledClips`）の回帰ガード。
///
/// 出力解像度は**先頭クリップ基準**で決まるため、並べ替えという日常操作で
/// 無言のうちに変わる。とくに写真クリップは長辺 1920px 上限
/// （`PhotoClipEncoder.maxLongSidePixels`）なので、写真を先頭にすると
/// 高解像度の動画があっても 1920 枠へ落ちる。UI がそれを出せるように、
/// 「builder が出す値」と「モデルの `@Published` が並べ替えに追随すること」を実測で固定する。
@MainActor
final class OutputResolutionTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    /// 指定解像度の単色動画（音声なし・30fps）。
    private func makeSizedVideo(width: Int, height: Int, seconds: Double) async throws -> URL {
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
        for i in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func waitUntilLoaded(_ model: MosaicEditorModel,
                                 timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoading {
            if Date() > deadline {
                XCTFail("動画の読み込みが \(timeout)s 以内に完了しない")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// builder が返す出力解像度は先頭クリップ基準で、並べ替えると入れ替わること。
    /// 縮小されるクリップ（出力枠より大きいクリップ）の id も同時に入れ替わる。
    func test_builtOutputSize_followsFirstClipOnReorder() async throws {
        let small = try await makeSizedVideo(width: 320, height: 240, seconds: 0.5)
        let large = try await makeSizedVideo(width: 640, height: 480, seconds: 0.5)
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: large)
        }
        let smallID = UUID(), largeID = UUID()
        let sources: [UUID: AVAsset] = [smallID: AVURLAsset(url: small),
                                        largeID: AVURLAsset(url: large)]
        let smallClip = TimelineClip(sourceID: smallID, sourceStart: 0, sourceEnd: 0.5)
        let largeClip = TimelineClip(sourceID: largeID, sourceStart: 0, sourceEnd: 0.5)

        let largeFirst = try await TimelineCompositionBuilder()
            .build(clips: [largeClip, smallClip], sources: sources)
        XCTAssertEqual(largeFirst.outputSize, CGSize(width: 640, height: 480),
                       "先頭 640x480 のとき出力解像度が先頭基準になっていない")
        XCTAssertTrue(largeFirst.downscaledClipIDs.isEmpty,
                      "出力枠より小さいクリップ（拡大される側）が縮小扱いになっている")

        let smallFirst = try await TimelineCompositionBuilder()
            .build(clips: [smallClip, largeClip], sources: sources)
        XCTAssertEqual(smallFirst.outputSize, CGSize(width: 320, height: 240),
                       "並べ替えで先頭が 320x240 になっても出力解像度が変わっていない")
        XCTAssertEqual(smallFirst.downscaledClipIDs, [largeClip.id],
                       "出力枠より大きいクリップが縮小対象として報告されていない")
    }

    /// モデルの `@Published`（UI が読む唯一の経路）が並べ替えに追随すること:
    /// 640x480 + 320x240 のタイムラインで、先頭を入れ替えると
    /// `outputRenderSize` と `hasDownscaledClips` が同時に反転する。
    func test_moveClip_updatesOutputRenderSizeAndDownscaleFlag() async throws {
        let large = try await makeSizedVideo(width: 640, height: 480, seconds: 0.5)
        let small = try await makeSizedVideo(width: 320, height: 240, seconds: 0.5)
        defer {
            try? FileManager.default.removeItem(at: large)
            try? FileManager.default.removeItem(at: small)
        }
        let model = makeModel()
        model.load(videoURL: large)
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()

        await model.appendVideoClip(url: small)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.clips.count, 2, "2 本目のクリップが追加されていない")
        XCTAssertEqual(model.outputRenderSize, CGSize(width: 640, height: 480),
                       "先頭（640x480）基準の出力解像度が publish されていない")
        XCTAssertFalse(model.hasDownscaledClips,
                       "縮小されるクリップが無いのに注意フラグが立っている")

        // 320x240 のクリップを先頭へ動かす（＝出力解像度が落ちる並べ替え）。
        let secondClipID = try XCTUnwrap(model.clips.last?.id)
        model.moveClip(id: secondClipID, toIndex: 0)
        await model.awaitPendingTimelineRebuild()

        XCTAssertEqual(model.outputRenderSize, CGSize(width: 320, height: 240),
                       "並べ替えで先頭が変わったのに outputRenderSize が更新されていない")
        XCTAssertTrue(model.hasDownscaledClips,
                      "640x480 のクリップが 320x240 枠へ縮小されるのに注意フラグが立たない")
    }

    /// 写真クリップを先頭にすると出力解像度が写真の枠（長辺 1920px 上限）まで落ち、
    /// 高解像度の動画クリップが縮小対象になること（無言の画質低下の回帰ガード）。
    func test_photoClipFirst_dropsOutputResolutionToPhotoFrame() async throws {
        // 長辺 1920px を超える動画（写真クリップの上限より大きい素材）。
        let video = try await makeSizedVideo(width: 2560, height: 1440, seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: video) }
        let model = makeModel()
        model.load(videoURL: video)
        try await waitUntilLoaded(model)
        await model.awaitPendingTimelineRebuild()
        XCTAssertEqual(model.outputRenderSize, CGSize(width: 2560, height: 1440),
                       "単一クリップの出力解像度が素材解像度になっていない")

        await model.appendPhotoClip(image: solidImage(width: 2560, height: 1440), seconds: 1.0)
        await model.awaitPendingTimelineRebuild()
        XCTAssertNil(model.errorMessage, "写真クリップの追加に失敗した")
        XCTAssertEqual(model.clips.count, 2)
        // 写真は末尾なので出力解像度は動画のまま。写真側が縮小される（拡大なので false）。
        XCTAssertEqual(model.outputRenderSize, CGSize(width: 2560, height: 1440),
                       "写真を末尾に足しただけで出力解像度が変わった")
        XCTAssertFalse(model.hasDownscaledClips,
                       "出力枠より小さい写真クリップが縮小扱いになっている")

        // 写真を先頭へ並べ替える＝出力が写真の枠（長辺 1920px）へ落ちる。
        let photoClipID = try XCTUnwrap(model.clips.last?.id)
        model.moveClip(id: photoClipID, toIndex: 0)
        await model.awaitPendingTimelineRebuild()

        let size = try XCTUnwrap(model.outputRenderSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080),
                       "写真クリップを先頭にしたのに出力解像度が写真の枠へ落ちていない")
        XCTAssertTrue(model.hasDownscaledClips,
                      "2560x1440 の動画が 1920x1080 枠へ縮小されるのに注意フラグが立たない")
    }
}

#endif
