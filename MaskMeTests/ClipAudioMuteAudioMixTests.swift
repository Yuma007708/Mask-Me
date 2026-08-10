import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// クリップ内消音区間（区間ミュート）が `AudioMixFactory` の音量キーフレームへ
/// 正しく変換されることを検証する。
///
/// 実素材は使わず、自前生成した単色動画 + サイン波音声を組み合わせた
/// `AVMutableComposition` を「1 本の素材」として渡す（`TimelineCompositionBuilder` の
/// `insertClip` は `asset.loadTracks(withMediaType:)` で映像・音声を別々に拾うため、
/// この組み立てでも実素材と同じ経路を通る）。
final class ClipAudioMuteAudioMixTests: XCTestCase {
    // MARK: - 素材生成

    private func makeTestVideo(seconds: Double, width: Int = 320, height: Int = 240) async throws -> URL {
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
            samples.withUnsafeMutableBytes { pointer in
                _ = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pointer.count,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                    dataLength: pointer.count, flags: 0, blockBufferOut: &block)
                if let block { CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: block,
                                                              offsetIntoDestination: 0, dataLength: pointer.count) }
            }
            guard let block else { continue }
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                 sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            if let sampleBuffer { input.append(sampleBuffer) }
            written += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 映像 + 音声を 1 本の `AVAsset` にまとめる（クリップの元素材として渡す）。
    private func makeVideoWithAudio(seconds: Double) async throws -> (asset: AVAsset, cleanup: () -> Void) {
        let videoURL = try await makeTestVideo(seconds: seconds)
        let audioURL = try await makeTestAudio(seconds: seconds)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let loadedVideo = try await videoAsset.loadTracks(withMediaType: .video).first
        let loadedAudio = try await audioAsset.loadTracks(withMediaType: .audio).first
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let loadedVideo, let loadedAudio else {
            throw NSError(domain: "test", code: -1)
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try videoTrack.insertTimeRange(range, of: loadedVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: loadedAudio, at: .zero)
        return (composition, {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        })
    }

    private static func volumeRamp(in params: AVAudioMixInputParameters, at time: CMTime)
        -> (start: Float, end: Float, range: CMTimeRange)? {
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        guard params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
        return (start, end, range)
    }

    // MARK: - 基本: 区間内は 0、区間外は originalAudioVolume

    /// 消音区間の中で実際に音量 0 のランプ／点が置かれること。
    func test_muteRange_setsVolumeZero_withinRange() async throws {
        let (asset, cleanup) = try await makeVideoWithAudio(seconds: 4)
        defer { cleanup() }
        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        var timeline = TimelineState()
        timeline.clips = [clip]
        // 合成時刻 1...2 秒を消音（等速クリップなので素材時刻もそのまま 1...2 秒）。
        timeline = timeline.addingClipAudioMuteRange(fromCompositionTime: 1, to: 2)

        let built = try await TimelineCompositionBuilder().build(
            clips: timeline.clips, sources: [sourceID: asset],
            clipAudioMuteRanges: timeline.clipAudioMuteRanges, isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first,
                                   "区間ミュートがあるのに audioMix の入力パラメータが無い")

        let value = try XCTUnwrap(
            Self.volumeRamp(in: params, at: CMTime(seconds: 1.5, preferredTimescale: 600)),
            "消音区間内に音量の点が置かれていない")
        XCTAssertEqual(value.start, 0, "消音区間内なのに音量が 0 になっていない")
        XCTAssertEqual(value.end, 0, "消音区間内なのに音量が 0 になっていない")
    }

    /// 区間外は `originalAudioVolume` に戻ること。
    func test_outsideMuteRange_isOriginalVolume() async throws {
        let (asset, cleanup) = try await makeVideoWithAudio(seconds: 4)
        defer { cleanup() }
        let sourceID = UUID()
        var clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        clip.originalAudioVolume = 0.6
        var timeline = TimelineState()
        timeline.clips = [clip]
        timeline = timeline.addingClipAudioMuteRange(fromCompositionTime: 1, to: 2)

        let built = try await TimelineCompositionBuilder().build(
            clips: timeline.clips, sources: [sourceID: asset],
            clipAudioMuteRanges: timeline.clipAudioMuteRanges, isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        let before = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.5, preferredTimescale: 600)))
        XCTAssertEqual(before.start, 0.6, accuracy: 1e-6, "消音区間の手前が originalAudioVolume に戻っていない")

        let after = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 3.5, preferredTimescale: 600)))
        XCTAssertEqual(after.start, 0.6, accuracy: 1e-6, "消音区間の後ろが originalAudioVolume に戻っていない")
    }

    /// 区間ミュートがあるとき audioMix が nil にならない（パススルーへ落ちない）。
    func test_muteRangePresent_audioMixIsNotNil() async throws {
        let (asset, cleanup) = try await makeVideoWithAudio(seconds: 4)
        defer { cleanup() }
        let sourceID = UUID()
        // 音量は既定（1.0）・トランジション無し・BGM 無し ＝ 区間ミュートが無ければ
        // audioMix は付かない構成。
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        var timeline = TimelineState()
        timeline.clips = [clip]
        timeline = timeline.addingClipAudioMuteRange(fromCompositionTime: 1, to: 2)

        let built = try await TimelineCompositionBuilder().build(
            clips: timeline.clips, sources: [sourceID: asset],
            clipAudioMuteRanges: timeline.clipAudioMuteRanges, isPro: true)
        XCTAssertNotNil(built.audioMix,
                        "区間ミュートがあるのに audioMix が nil（書き出しがパススルーへ落ちて消音が効かない）")
    }

    // MARK: - rate ≠ 1

    /// `rate != 1` のクリップで、消音の開始・終了が正しい合成時刻に来ること
    /// （素材時刻 → 合成時刻の写像が効いていることの番人）。
    func test_rateNotOne_muteBoundaries_mapToCorrectCompositionTime() async throws {
        let (asset, cleanup) = try await makeVideoWithAudio(seconds: 4)
        defer { cleanup() }
        let sourceID = UUID()
        var clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        clip.rate = 2  // 合成尺は素材の半分（4 秒 → 2 秒）。
        var timeline = TimelineState()
        timeline.clips = [clip]
        // 素材時刻 1...3 秒（rate=2 なので合成時刻では 0.5...1.5 秒）を直接指定して確認する。
        let muteRange = ClipAudioMuteRange(clipID: clip.id, sourceID: sourceID, sourceStart: 1, sourceEnd: 3)
        timeline.clipAudioMuteRanges = [muteRange]

        let built = try await TimelineCompositionBuilder().build(
            clips: timeline.clips, sources: [sourceID: asset],
            clipAudioMuteRanges: timeline.clipAudioMuteRanges, isPro: true)
        let params = try XCTUnwrap(built.audioMix?.inputParameters.first)

        // 合成時刻 0.5...1.5 秒（= 素材時刻 1...3 秒）が消音であること。
        let inside = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 1.0, preferredTimescale: 600)))
        XCTAssertEqual(inside.start, 0, "rate=2 で素材時刻の消音区間が誤った合成時刻に写っている（区間内なのに音が鳴る）")

        // 合成時刻 0.2 秒（= 素材時刻 0.4 秒。区間外）は originalAudioVolume のまま。
        let beforeStart = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 0.2, preferredTimescale: 600)))
        XCTAssertEqual(beforeStart.start, 1, accuracy: 1e-6,
                       "rate=2 で消音区間の手前まで消音が漏れている（境界が早すぎる）")

        // 合成時刻 1.8 秒（= 素材時刻 3.6 秒。区間外）も originalAudioVolume のまま。
        let afterEnd = try XCTUnwrap(Self.volumeRamp(in: params, at: CMTime(seconds: 1.8, preferredTimescale: 600)))
        XCTAssertEqual(afterEnd.start, 1, accuracy: 1e-6,
                       "rate=2 で消音区間の後ろまで消音が残っている（境界が遅すぎる）")
    }

    // MARK: - トランジションのクロスフェードと同居

    /// トランジションのクロスフェードと同居しても、クロスフェードが壊れないこと。
    /// 消音区間はクロスフェード区間の外に置き、ランプが従来どおり 0→volume（もしくは逆）
    /// のまま残ることを確認する。
    func test_muteRange_coexistsWithTransition_crossfadeSurvives() async throws {
        let (asset, cleanup) = try await makeVideoWithAudio(seconds: 4)
        defer { cleanup() }
        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        let transitions = [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)]
        var timeline = TimelineState()
        timeline.clips = [first, second]
        timeline.transitions = transitions
        // second クリップの後半（クロスフェード区間より後ろ）を消音する。
        let mapping = TimelineMapping(clips: [first, second], transitions: transitions)
        guard let secondStart = mapping.clipStartTime(clipID: second.id) else {
            return XCTFail("second クリップの合成開始時刻が引けない")
        }
        timeline = timeline.addingClipAudioMuteRange(
            fromCompositionTime: secondStart + 0.8, to: secondStart + 1.0)

        let built = try await TimelineCompositionBuilder().build(
            clips: timeline.clips, transitions: timeline.transitions, sources: [sourceID: asset],
            clipAudioMuteRanges: timeline.clipAudioMuteRanges, isPro: true)
        XCTAssertEqual(built.audioMix?.inputParameters.count, 2,
                       "A/B 2 トラックぶんの音量パラメータが揃っていない")

        // クロスフェード区間の途中でランプが生きていること（消音の追加で消えていないか）。
        let overlap = try XCTUnwrap(mapping.overlaps.first)
        let midOverlap = CMTime(seconds: (overlap.start + overlap.end) / 2, preferredTimescale: 600)
        let hasRamp = built.audioMix?.inputParameters.contains {
            Self.volumeRamp(in: $0, at: midOverlap) != nil
        }
        XCTAssertEqual(hasRamp, true, "クロスフェード区間のランプが区間ミュートの追加で失われている")

        // 先行（outgoing）クリップのランプが重なりの終わりでちゃんと 0 まで落ちること
        // （区切り点の評価が半開区間のままだと、終端だけ素の音量に化ける）。
        let outgoingRamp = try XCTUnwrap(built.audioMix?.inputParameters.compactMap {
            Self.volumeRamp(in: $0, at: midOverlap)
        }.first { $0.start > $0.end })
        XCTAssertEqual(outgoingRamp.end, 0, accuracy: 1e-6,
                       "先行クリップのクロスフェードが重なりの終わりで無音まで落ちきっていない")
    }
}
