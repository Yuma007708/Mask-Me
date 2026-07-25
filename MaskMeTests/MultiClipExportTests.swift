import XCTest
import AVFoundation
import MosaicCore
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
    private func makeTestVideo(
        seconds: Double, withAudio: Bool,
        audioAmplitude: @escaping (Double) -> Double = { _ in 1.0 },
        audioChannels: Int? = nil
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
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: channels,
                    AVChannelLayoutKey: layoutData,
                    AVEncoderBitRateKey: 256_000
                ])
            } else {
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100.0,
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
                                channels: audioChannels ?? 1, amplitude: audioAmplitude)
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
    private func makePCMFormat(channels: Int) -> CMFormatDescription? {
        let bytesPerFrame = UInt32(2 * channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
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
                                 amplitude: (Double) -> Double = { _ in 1.0 }) throws {
        let sampleRate = 44100.0
        guard let format = makePCMFormat(channels: channels) else { return }

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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)

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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

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
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.2,
                       "トリム書き出しの出力尺が選択範囲（後半 1s）と一致しない")
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "トリム書き出しで音声トラックが消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.2,
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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.25...0.75
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.2)
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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: 0.25...0.75
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.2)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "6ch 素材のトリム書き出しで音声トラックが消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 1.0, accuracy: 0.2)
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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            trimRange: (0.5 / 3.0)...(2.5 / 3.0)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.2)
        let audioTracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "トリム書き出しで音声が消えている")
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(CMTimeGetSeconds(range.duration), 2.0, accuracy: 0.2,
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
            .build(clips: clips, sources: [sourceID: AVURLAsset(url: url)])

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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)
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

    /// `AudioExportPipeline.decide` の純ロジック契約: パススルー（bit 同一の無変換
    /// コピー）は「トリムなし かつ 音声 empty edit なし」のときだけ。それ以外は
    /// すべて再エンコード（empty edit を無音として尊重する PCM デコード経路）。
    func test_audioPipelineDecision_passthroughOnlyWithoutTrimAndEmptyEdits() {
        XCTAssertEqual(AudioExportPipeline.decide(isTrimming: false, hasEmptyAudioSegments: false),
                       .passthrough)
        XCTAssertEqual(AudioExportPipeline.decide(isTrimming: true, hasEmptyAudioSegments: false),
                       .reencode)
        XCTAssertEqual(AudioExportPipeline.decide(isTrimming: false, hasEmptyAudioSegments: true),
                       .reencode)
        XCTAssertEqual(AudioExportPipeline.decide(isTrimming: true, hasEmptyAudioSegments: true),
                       .reencode)
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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)

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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)

        let exporter = try makeExporter()
        let outURL = try await exporter.export(
            asset: composition,
            mapping: TimelineMapping(clips: clips),
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let duration = try await out.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5.0, accuracy: 0.2,
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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)

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
        let composition = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)
        let mapping = TimelineMapping(clips: clips)

        // 1) seed あり + clamp あり: 実検出ゼロ
        let (exporter, counter) = try makeCountingExporter()
        let outURL = try await exporter.export(
            asset: composition,
            detectionCaches: [photoID: [0.0: [fakeFace(cx: 0.5, cy: 0.5)]]],
            mapping: mapping,
            photoSourceIDs: [photoID]
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
            photoSourceIDs: [photoID]
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: emptySeedURL) }
        XCTAssertEqual(emptySeedCounter.count, 0,
                       "顔なし seed の写真クリップで毎フレーム実検出が走っている")

        // 3) 対照実験: clamp なし・キャッシュなしなら実検出が走る（計測フックの実証）
        let (controlExporter, controlCounter) = try makeCountingExporter()
        let controlURL = try await controlExporter.export(
            asset: composition,
            mapping: mapping
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: controlURL) }
        XCTAssertGreaterThan(controlCounter.count, 0,
                             "対照実験で実検出が観測できない（検出カウントのフックが壊れている）")
    }
}

#endif
