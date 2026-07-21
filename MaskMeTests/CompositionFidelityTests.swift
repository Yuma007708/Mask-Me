import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(Metal)
import Metal

/// Composition 経由に切り替えたことで「元素材と見分けがつく差」が出ていないことを固定する。
///
/// フェーズ1の合格条件は「着手前と見分けがつかないこと」なので、
/// 合成トラックから読む値（ビットレート・音声フォーマット）が
/// 元素材のトラックと一致することを実測で担保する。
final class CompositionFidelityTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    // MARK: - テスト素材生成（外部ファイルに一切依存しない）

    /// 映像（H.264・ランダムノイズ）＋ 任意で音声（AAC・440Hz サイン波）を持つ mp4 を生成する。
    /// ノイズを載せるのは、単色だと圧縮後のデータレートがほぼ 0 になり
    /// ビットレート比較の意味が無くなるため。
    private func makeTestVideo(seconds: Double, withAudio: Bool) async throws -> URL {
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
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            audioInput = aIn
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        if let audioInput {
            try appendSineAudio(to: audioInput, seconds: seconds)
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
            if let base = CVPixelBufferGetBaseAddress(buffer)?
                .assumingMemoryBound(to: UInt8.self) {
                let bytes = CVPixelBufferGetBytesPerRow(buffer) * height
                for b in 0..<bytes { base[b] = UInt8.random(in: 0...255) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 440Hz のサイン波を 1024 サンプルずつ書き込む。
    private func appendSineAudio(to input: AVAssetWriterInput, seconds: Double) throws {
        let sampleRate = 44100.0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        guard let format else { return }

        let chunk = 1024
        let totalFrames = Int(seconds * sampleRate)
        var written = 0
        while written < totalFrames {
            let count = min(chunk, totalFrames - written)
            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(written + i) / sampleRate
                samples[i] = Int16(sin(2 * .pi * 440 * t) * 12000)
            }
            var block: CMBlockBuffer?
            let byteCount = count * 2
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

    private func buildComposition(from asset: AVAsset,
                                  seconds: Double) async throws -> AVMutableComposition {
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: seconds)
        return try await TimelineCompositionBuilder()
            .build(clips: [clip], sources: [sourceID: asset])
    }

    // MARK: - Critical 1: ビットレートが合成で変わらないこと

    /// `VideoMosaicExporter` は映像トラックの `estimatedDataRate` を出力の
    /// `AVVideoAverageBitRateKey` に使う。合成トラックがこれを 0 で返すと
    /// フォールバック式に落ちて、エラーもログも無いまま出力の画質だけが変わる。
    ///
    /// 実測では合成トラックは元素材と同じ値を返す（= 退行は起きていない）。
    /// この一致が将来崩れたら気付けるよう固定する。
    func test_compositionTrackReportsSameDataRateAsSource() async throws {
        let url = try await makeTestVideo(seconds: 2.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let sourceRate = try await asset.loadTracks(withMediaType: .video)[0]
            .load(.estimatedDataRate)
        let composition = try await buildComposition(from: asset, seconds: 2.0)
        let compRate = try await composition.loadTracks(withMediaType: .video)[0]
            .load(.estimatedDataRate)

        print("[FIDELITY] sourceDataRate=\(sourceRate) compositionDataRate=\(compRate)")
        // そもそも 0 の素材だと比較が無意味なので、元が非 0 であることを先に確かめる。
        XCTAssertGreaterThan(sourceRate, 0, "テスト素材のデータレートが 0 で比較にならない")
        XCTAssertEqual(compRate, sourceRate, accuracy: sourceRate * 0.01,
                       "合成トラックのデータレートが元素材と一致しない。"
                       + "書き出しビットレートが無言で変わる退行の可能性がある。")
    }

    /// 複数クリップになっても合成トラックのデータレートが 0 に落ちないこと。
    /// フェーズ2で連結が入った瞬間に静かにフォールバックへ落ちる、を防ぐ。
    func test_multiClipCompositionStillReportsNonZeroDataRate() async throws {
        let url = try await makeTestVideo(seconds: 3.0, withAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let sourceID = UUID()
        let composition = try await TimelineCompositionBuilder().build(
            clips: [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1),
                    TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)],
            sources: [sourceID: asset])
        let rate = try await composition.loadTracks(withMediaType: .video)[0]
            .load(.estimatedDataRate)
        print("[FIDELITY] multiClipDataRate=\(rate)")
        XCTAssertGreaterThan(rate, 0, "複数クリップの合成トラックがデータレート 0 を返した")
    }

    // MARK: - Important 4: 音声パススルー

    /// 合成トラックから音声フォーマットを読めること（writer のヒントに使う値）。
    func test_compositionAudioTrackKeepsSourceFormat() async throws {
        let url = try await makeTestVideo(seconds: 1.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let srcFormats = try await sourceAudio?.load(.formatDescriptions)
        let srcFormat = try XCTUnwrap(srcFormats?.first, "テスト素材に音声トラックが無い")

        let composition = try await buildComposition(from: asset, seconds: 1.0)
        let compAudioTracks = try await composition.loadTracks(withMediaType: .audio)
        let compAudio = try XCTUnwrap(compAudioTracks.first, "合成に音声トラックが無い")
        let compFormats = try await compAudio.load(.formatDescriptions)
        let compFormat = try XCTUnwrap(compFormats.first,
                                       "合成の音声トラックに formatDescription が無い")

        let src = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(srcFormat)?.pointee)
        let dst = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(compFormat)?.pointee)
        print("[FIDELITY] audio src=\(src.mFormatID)/\(src.mSampleRate)/\(src.mChannelsPerFrame) "
              + "comp=\(dst.mFormatID)/\(dst.mSampleRate)/\(dst.mChannelsPerFrame)")
        XCTAssertEqual(dst.mFormatID, src.mFormatID, "合成で音声コーデックが変わっている")
        XCTAssertEqual(dst.mSampleRate, src.mSampleRate, "合成でサンプルレートが変わっている")
        XCTAssertEqual(dst.mChannelsPerFrame, src.mChannelsPerFrame,
                       "合成でチャンネル数が変わっている")
    }

    /// Composition を実際に書き出して、音声が消えず・再エンコードもされないこと。
    /// 「例外は出ないが音が無い」という表面化のしかたを直接踏みにいく。
    func test_exportFromCompositionPreservesAudio() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        let url = try await makeTestVideo(seconds: 1.0, withAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let composition = try await buildComposition(from: asset, seconds: 1.0)
        let compAudioTrack = try await composition.loadTracks(withMediaType: .audio).first
        let compAudioFormats = try await compAudioTrack?.load(.formatDescriptions)
        let srcFormat = try XCTUnwrap(compAudioFormats?.first)
        let srcASBD = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(srcFormat)?.pointee)

        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        let exporter = VideoMosaicExporter(renderer: renderer,
                                           landmarker: NullFaceLandmarker())
        let outURL = try await exporter.export(
            asset: composition, selectedFaceTargets: [], manualRegions: [],
            detectionCache: [:], faceEnabled: true, backgroundEnabled: false,
            backgroundBlock: 28, speed: .fast) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        let out = AVURLAsset(url: outURL)
        let outAudio = try await out.loadTracks(withMediaType: .audio)
        XCTAssertEqual(outAudio.count, 1, "書き出し結果に音声トラックが無い（音が消えている）")

        let outFormats = try await outAudio[0].load(.formatDescriptions)
        let outFormat = try XCTUnwrap(outFormats.first)
        let outASBD = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(outFormat)?.pointee)
        print("[FIDELITY] exportAudio src=\(srcASBD.mFormatID)/\(srcASBD.mSampleRate)"
              + "/\(srcASBD.mChannelsPerFrame) out=\(outASBD.mFormatID)/\(outASBD.mSampleRate)"
              + "/\(outASBD.mChannelsPerFrame)")
        // パススルーなのでコーデック・サンプルレート・チャンネル数が完全一致するはず。
        // ずれたら再エンコードが起きている。
        XCTAssertEqual(outASBD.mFormatID, srcASBD.mFormatID,
                       "音声が再エンコードされている（コーデック不一致）")
        XCTAssertEqual(outASBD.mSampleRate, srcASBD.mSampleRate)
        XCTAssertEqual(outASBD.mChannelsPerFrame, srcASBD.mChannelsPerFrame)

        // 尺がほぼ保たれていること（音声が途中で切れていない）。
        let outDuration = try await outAudio[0].load(.timeRange).duration
        XCTAssertEqual(CMTimeGetSeconds(outDuration), 1.0, accuracy: 0.2,
                       "書き出しの音声尺が元と大きく違う")
    }
}

#endif
