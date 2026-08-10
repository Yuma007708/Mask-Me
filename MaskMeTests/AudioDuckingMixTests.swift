import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// BGM ダッキング（E2-3）が `AudioMixFactory` の音量キーフレームへ正しく変換されることを検証する。
///
/// `ClipAudioMuteAudioMixTests` / `TimelineCompositionBuilderTests` と同じ流儀:
/// 実素材は使わず自前生成した単色動画（映像のみ・無音）と BGM 用の m4a（音声のみ）を
/// `TimelineCompositionBuilder.build` へ渡す。BGM の音源は音声のみなので、クリップ側の
/// 音声トラックはビルダーが除去し、`built.audioMix?.inputParameters.first` が
/// **BGM のパラメータそのもの**になる（`TimelineCompositionBuilderTests` と同じ前提）。
final class AudioDuckingMixTests: XCTestCase {
    // MARK: - 素材生成

    /// 映像のみ・無音の単色動画（クリップ側の素材）。
    private func makeSilentVideo(seconds: Double, width: Int = 320, height: Int = 240) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
        let fps = 30
        let total = Int(seconds * Double(fps))
        for index in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40, CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// BGM 用の音源（映像なし・音声だけの m4a）。
    private func makeTestAudio(seconds: Double, sampleRate: Double = 44100) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 1024
        let totalSamples = Int(seconds * sampleRate)
        var written = 0
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw NSError(domain: "test", code: -1) }
        while written < totalSamples {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let count = min(frames, totalSamples - written)
            var samples = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                let time = Double(written + index) / sampleRate
                samples[index] = Int16(sin(2 * .pi * 440 * time) * 12000)
            }
            var block: CMBlockBuffer?
            let byteCount = count * 2
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: 0, blockBufferOut: &block)
            guard let block else { break }
            _ = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: byteCount)
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid)
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                      formatDescription: format, sampleCount: count,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: [2],
                                      sampleBufferOut: &sample)
            if let sample { input.append(sample) }
            written += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// `getVolumeRamp` の読み出しラッパ。
    private static func volumeRamp(in params: AVAudioMixInputParameters, at time: CMTime)
        -> (start: Float, end: Float, range: CMTimeRange)? {
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        guard params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
        return (start, end, range)
    }

    // MARK: - 基本: ダック区間の中は volume * gain、外は volume

    func test_duckRange_lowersBackgroundVolume_byGain() async throws {
        let videoURL = try await makeSilentVideo(seconds: 6)
        let audioURL = try await makeTestAudio(seconds: 6)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let videoSource = UUID()
        let audioSource = UUID()
        let clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)
        var item = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 6, compositionStart: 0)
        item.volume = 0.8
        item.duckingGain = 0.25
        let duckRange = ClipDuckRange(clipID: clip.id, sourceID: videoSource, sourceStart: 2, sourceEnd: 4)

        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], audioItems: [item],
            sources: [videoSource: AVURLAsset(url: videoURL), audioSource: AVURLAsset(url: audioURL)],
            clipDuckRanges: [duckRange], isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first, "BGM の音量パラメータが無い")

        // 声区間の内側（attack/release の外）: item.volume * duckingGain。
        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 3, preferredTimescale: 600)))
        XCTAssertEqual(inside.start, 0.8 * 0.25, accuracy: 1e-3,
                       "ダック区間の中で BGM が volume * gain に下がっていない")

        // 声区間より十分手前・十分後ろ: item.volume のまま。
        let before = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.5, preferredTimescale: 600)))
        XCTAssertEqual(before.start, 0.8, accuracy: 1e-3, "ダック区間の手前で BGM が下がっている")
        let after = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 5.5, preferredTimescale: 600)))
        XCTAssertEqual(after.start, 0.8, accuracy: 1e-3, "ダック区間の後ろで BGM が下がったまま戻っていない")
    }

    // MARK: - フェードとダックの同居

    func test_duckRange_coexistsWithFade() async throws {
        let videoURL = try await makeSilentVideo(seconds: 6)
        let audioURL = try await makeTestAudio(seconds: 6)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let videoSource = UUID()
        let audioSource = UUID()
        let clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)
        var item = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 6, compositionStart: 0)
        item.volume = 1
        item.fadeInDuration = 1
        item.fadeOutDuration = 1
        item.duckingGain = 0.25
        // フェードインの途中（0...1 秒）に声区間を置く。
        let duckRange = ClipDuckRange(clipID: clip.id, sourceID: videoSource, sourceStart: 0.3, sourceEnd: 0.6)

        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], audioItems: [item],
            sources: [videoSource: AVURLAsset(url: videoURL), audioSource: AVURLAsset(url: audioURL)],
            clipDuckRanges: [duckRange], isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        // フェードイン開始（曲の先頭）は 0。
        let start = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.05, preferredTimescale: 600)))
        XCTAssertEqual(start.start, 0, accuracy: 1e-3, "フェードイン開始が 0 になっていない")

        // ダック区間の中は volume * duckingGain（= 0.25）を超えない。
        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.45, preferredTimescale: 600)))
        XCTAssertLessThanOrEqual(inside.start, 0.25 + 1e-3,
                                 "フェードと重なるダック区間で volume * gain を超えている")
        XCTAssertLessThanOrEqual(inside.end, 0.25 + 1e-3,
                                 "フェードと重なるダック区間で volume * gain を超えている")

        // フェードアウト終端（曲の終わり）は 0。
        let end = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 5.5, preferredTimescale: 600)))
        XCTAssertEqual(end.end, 0, accuracy: 1e-3, "フェードアウト終端が 0 になっていない")
    }

    // MARK: - rate ≠ 1 の写像

    /// `rate = 2` のクリップで、素材時刻のダック区間が正しい合成時刻（半分の位置）に現れること。
    /// 写像の取り違え（`sourceTime` をそのまま使ってしまう等）を検出する番人。
    func test_duckRange_rateNotOne_mapsToCorrectCompositionTime() async throws {
        let videoURL = try await makeSilentVideo(seconds: 6)
        let audioURL = try await makeTestAudio(seconds: 3)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let videoSource = UUID()
        let audioSource = UUID()
        var clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)
        clip.rate = 2  // 合成尺は素材の半分（6 秒 → 3 秒）。
        var item = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 3, compositionStart: 0)
        item.volume = 1
        item.duckingGain = 0.25
        // 素材時刻 2...4 秒（rate=2 なので合成時刻では 1...2 秒）を指定する。
        let duckRange = ClipDuckRange(clipID: clip.id, sourceID: videoSource, sourceStart: 2, sourceEnd: 4)

        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], audioItems: [item],
            sources: [videoSource: AVURLAsset(url: videoURL), audioSource: AVURLAsset(url: audioURL)],
            clipDuckRanges: [duckRange], isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        // 合成時刻 1.5 秒（= 素材時刻 3 秒）が声区間の中であること。
        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 1.5, preferredTimescale: 600)))
        XCTAssertEqual(inside.start, 0.25, accuracy: 1e-3,
                       "rate=2 で素材時刻の声区間が誤った合成時刻に写っている（区間内なのに下がっていない）")

        // 合成時刻 0.3 秒（= 素材時刻 0.6 秒。区間外）は下がっていないこと。
        let before = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.3, preferredTimescale: 600)))
        XCTAssertEqual(before.start, 1, accuracy: 1e-3,
                       "rate=2 で声区間の手前まで BGM が下がっている（境界が早すぎる）")

        // 合成時刻 2.7 秒（= 素材時刻 5.4 秒。区間外）も下がっていないこと。
        let after = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 2.7, preferredTimescale: 600)))
        XCTAssertEqual(after.start, 1, accuracy: 1e-3,
                       "rate=2 で声区間の後ろまで BGM が下がったまま残っている（境界が遅すぎる）")
    }

    // MARK: - 区間ミュートに覆われたクリップはダッキングしない

    func test_duckRange_fullyCoveredByMuteRange_isNotDucked() async throws {
        let videoURL = try await makeSilentVideo(seconds: 6)
        let audioURL = try await makeTestAudio(seconds: 6)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let videoSource = UUID()
        let audioSource = UUID()
        let clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)
        var item = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 6, compositionStart: 0)
        item.volume = 0.8
        item.duckingGain = 0.25
        let duckRange = ClipDuckRange(clipID: clip.id, sourceID: videoSource, sourceStart: 2, sourceEnd: 4)
        // 声区間を丸ごと覆う区間ミュート（ユーザーが明示的に消音した区間）。
        let muteRange = ClipAudioMuteRange(clipID: clip.id, sourceID: videoSource, sourceStart: 0, sourceEnd: 6)

        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], audioItems: [item],
            sources: [videoSource: AVURLAsset(url: videoURL), audioSource: AVURLAsset(url: audioURL)],
            clipAudioMuteRanges: [muteRange], clipDuckRanges: [duckRange], isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        // 「本来ダックが掛かるはずだった」区間の中でも BGM は volume のまま。
        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 3, preferredTimescale: 600)))
        XCTAssertEqual(inside.start, 0.8, accuracy: 1e-3,
                       "区間ミュートに覆われたクリップの声区間なのに BGM が下がっている")
    }

    // MARK: - duckingGain = 1（OFF）は従来どおり

    /// `duckingGain = 1` は「下げない」の既定と同じなので、声区間があっても BGM は
    /// `volume` のまま（`AudioItem.duckingGain` の doc 参照）。既存 BGM テストが
    /// 無改変で緑であることが主な回帰保証だが、ここでは声区間を渡した状態での
    /// 直接的な確認を残す。
    func test_duckingGainOne_doesNotLowerVolume() async throws {
        let videoURL = try await makeSilentVideo(seconds: 6)
        let audioURL = try await makeTestAudio(seconds: 6)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let videoSource = UUID()
        let audioSource = UUID()
        let clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)
        var item = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 6, compositionStart: 0)
        item.volume = 0.8
        // duckingGain は既定の 1（下げない）のまま。
        let duckRange = ClipDuckRange(clipID: clip.id, sourceID: videoSource, sourceStart: 2, sourceEnd: 4)

        let built = try await TimelineCompositionBuilder().build(
            clips: [clip], audioItems: [item],
            sources: [videoSource: AVURLAsset(url: videoURL), audioSource: AVURLAsset(url: audioURL)],
            clipDuckRanges: [duckRange], isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 3, preferredTimescale: 600)))
        XCTAssertEqual(inside.start, 0.8, accuracy: 1e-3,
                       "duckingGain = 1（OFF）なのに BGM が下がっている")
    }
}
