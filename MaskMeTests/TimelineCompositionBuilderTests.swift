import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// Composition 構築のテスト。実素材を使わず、生成した無音・単色動画で検証する。
final class TimelineCompositionBuilderTests: XCTestCase {
    /// テスト用に指定秒数の単色動画を生成する。
    /// 外部の素材ファイルに依存しないための自前生成。
    /// 解像度は既定 320x240（混在ガードのテスト用に変更可能）。
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
        for i in 0..<total {
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
            adaptor.append(buffer,
                           withPresentationTime: CMTime(value: CMTimeValue(i),
                                                        timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 単一クリップでも Composition を経由すること。
    /// 特別扱いの分岐を作らない設計を固定する。
    func test_singleClipProducesComposition() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let builder = TimelineCompositionBuilder()
        let composition = try await builder.build(
            clips: [clip], sources: [sourceID: AVURLAsset(url: url)]).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
        let tracks = try await composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    /// 2クリップを連結すると尺が合算されること。
    func test_twoClipsAreConcatenated() async throws {
        let url = try await makeTestVideo(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let sources = [sourceID: AVURLAsset(url: url) as AVAsset]
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)

        let composition = try await TimelineCompositionBuilder()
            .build(clips: [first, second], sources: sources).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    /// 素材が見つからない場合はエラーを投げること（黙って短い動画を作らない）。
    func test_missingSourceThrows() async throws {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 1)
        do {
            _ = try await TimelineCompositionBuilder().build(clips: [clip], sources: [:]).composition
            XCTFail("素材欠落を検出できていない")
        } catch TimelineCompositionBuilder.BuildError.missingSource {
            // 期待どおり
        }
    }

    // MARK: - S4: rate（scaleTimeRange）

    /// rate 0.5（スロー）で合成尺が素材長の 2 倍になること。
    func test_rateHalf_doublesCompositionDuration() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 0.5)
        let composition = try await TimelineCompositionBuilder()
            .build(clips: [clip], sources: [sourceID: AVURLAsset(url: url)]).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 4.0, accuracy: 0.15,
                       "rate 0.5 のクリップが合成尺 2 倍（scaleTimeRange）になっていない")
    }

    /// rate 2（倍速）で合成尺が素材長の半分になること。
    func test_rateDouble_halvesCompositionDuration() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2, rate: 2.0)
        let composition = try await TimelineCompositionBuilder()
            .build(clips: [clip], sources: [sourceID: AVURLAsset(url: url)]).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.15,
                       "rate 2 のクリップが合成尺 1/2（scaleTimeRange）になっていない")
    }

    /// 等速と倍速の混在: クリップごとに独立して rate が適用され、
    /// 合成尺が各クリップの合成尺（素材長 ÷ rate）の合計になること。
    func test_mixedRateClips_sumScaledDurations() async throws {
        let url = try await makeTestVideo(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let sources = [sourceID: AVURLAsset(url: url) as AVAsset]
        // 1s @1x（=1s） + 2s @2x（=1s） → 合計 2s
        let normal = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        let fast = TimelineClip(sourceID: sourceID, sourceStart: 1, sourceEnd: 3, rate: 2.0)

        let composition = try await TimelineCompositionBuilder()
            .build(clips: [normal, fast], sources: sources).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    // MARK: - S8: 解像度混在の解禁

    /// **契約の更新（S6 → S8）**: 解像度が異なる素材の連結は、S6 までは
    /// `BuildError.mixedVideoFormats` で reject していた。S8 で `AVVideoComposition`
    /// を導入したので、混在は「正しく合成される」が正しい契約になった:
    /// videoComposition が装着され、renderSize は**先頭クリップ基準**、後続クリップは
    /// アスペクトフィットで配置される（配置は `TimelineRenderLayout` として顔座標にも
    /// 同じ計算で適用される）。
    func test_mixedResolutionsAreComposedIntoRenderSize() async throws {
        let smallURL = try await makeTestVideo(seconds: 1.0)
        let largeURL = try await makeTestVideo(seconds: 1.0, width: 640, height: 360)
        defer {
            try? FileManager.default.removeItem(at: smallURL)
            try? FileManager.default.removeItem(at: largeURL)
        }

        let smallID = UUID()
        let largeID = UUID()
        let sources: [UUID: AVAsset] = [
            smallID: AVURLAsset(url: smallURL),
            largeID: AVURLAsset(url: largeURL)
        ]
        let clips = [
            TimelineClip(sourceID: smallID, sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceID: largeID, sourceStart: 0, sourceEnd: 1)
        ]
        let built = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)

        let duration = try await built.composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15,
                       "解像度混在の連結で合成尺が壊れている")
        let videoComposition = try XCTUnwrap(built.videoComposition,
                                             "解像度混在なのに videoComposition が装着されていない")
        XCTAssertEqual(videoComposition.renderSize, CGSize(width: 320, height: 240),
                       "renderSize が先頭クリップ基準になっていない")
        // 16:9 の後続クリップは 4:3 のフレームに上下レターボックスで収まる。
        let secondPlacement = built.layout.placement(for: clips[1].id)
        XCTAssertEqual(secondPlacement.width, 1.0, accuracy: 1e-6)
        XCTAssertEqual(secondPlacement.height, (360.0 / 640.0 * 320.0) / 240.0, accuracy: 1e-6,
                       "後続クリップのアスペクトフィット配置が想定と違う")
        XCTAssertEqual(built.layout.placement(for: clips[0].id),
                       CGRect(x: 0, y: 0, width: 1, height: 1),
                       "先頭クリップは全面配置（恒等）のはず")
    }

    /// 同一フォーマット・等速・トランジション無しの構成では videoComposition を
    /// **装着しない**こと（無変換構成の忠実度を壊さないための入口契約）。
    func test_noTransformTimelineAttachesNothing() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        let built = try await TimelineCompositionBuilder().build(
            clips: [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1),
                    TimelineClip(sourceID: sourceID, sourceStart: 1, sourceEnd: 2)],
            sources: [sourceID: AVURLAsset(url: url)])
        XCTAssertNil(built.videoComposition, "無変換構成に videoComposition が装着された")
        XCTAssertNil(built.audioMix, "無変換構成に audioMix が装着された")
        XCTAssertEqual(built.layout, .identity)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "無変換構成で映像トラックが 2 本になっている")
    }

    // MARK: - S8: トランジション（A/B 交互配置）

    /// トランジションのある境界でクリップが重なり、A/B 2 トラックへ交互配置されること。
    /// 合成尺は `TimelineMapping` の重なりモデル（Σ合成尺 − ΣD）と一致すること。
    func test_transitionOverlapsClipsOnAlternatingTracks() async throws {
        let url = try await makeTestVideo(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        let transitions = [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)]

        let built = try await TimelineCompositionBuilder().build(
            clips: [first, second], transitions: transitions,
            sources: [sourceID: AVURLAsset(url: url)])

        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 2, "トランジションがあるのに単一トラックのまま（重なりを表現できない）")
        let duration = try await built.composition.load(.duration)
        let mapping = TimelineMapping(clips: [first, second], transitions: transitions)
        XCTAssertEqual(CMTimeGetSeconds(duration), mapping.totalDuration, accuracy: 0.1,
                       "合成尺が TimelineMapping の重なりモデルと一致しない")
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.5, accuracy: 0.1)
        XCTAssertNotNil(built.videoComposition, "トランジションがあるのに videoComposition が無い")
    }

    /// instruction が合成タイムライン全体を**隙間なく**覆うこと。
    /// AVFoundation は instruction の時間範囲が連続していないと再生・書き出しが破綻する。
    func test_videoCompositionInstructionsCoverTimelineWithoutGaps() async throws {
        let url = try await makeTestVideo(seconds: 6.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        // fadeToBlack（区分線形 = 重なりの中央でも instruction が割れる）を含む 3 クリップ。
        let clips = [
            TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4),
            TimelineClip(sourceID: sourceID, sourceStart: 4, sourceEnd: 6)
        ]
        let transitions = [
            clips[0].id: TransitionSpec(kind: .fadeToBlack, duration: 0.6),
            clips[1].id: TransitionSpec(kind: .wipeLeft, duration: 0.4)
        ]
        let built = try await TimelineCompositionBuilder().build(
            clips: clips, transitions: transitions, sources: [sourceID: AVURLAsset(url: url)])
        let videoComposition = try XCTUnwrap(built.videoComposition)
        let instructions = videoComposition.instructions
        XCTAssertGreaterThan(instructions.count, 3, "重なりのランプ分割点で instruction が割れていない")

        XCTAssertEqual(instructions.first?.timeRange.start, .zero, "先頭 instruction が 0 から始まっていない")
        for index in 0..<(instructions.count - 1) {
            XCTAssertEqual(instructions[index].timeRange.end, instructions[index + 1].timeRange.start,
                           "instruction \(index) と \(index + 1) の間に隙間（または重複）がある")
        }
        let compositionDuration = try await built.composition.load(.duration)
        let end = try XCTUnwrap(instructions.last?.timeRange.end)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(end), CMTimeGetSeconds(compositionDuration) - 0.001,
                                    "末尾の instruction が composition の終端まで届いていない")
        // AVFoundation 自身の検証（隙間・不正な時間範囲を弾く）。
        let isValid = try await videoComposition.isValid(
            for: built.composition,
            timeRange: CMTimeRange(start: .zero, duration: compositionDuration),
            validationDelegate: nil)
        XCTAssertTrue(isValid, "AVFoundation の videoComposition 検証に通らない")
        // 重なり区間では 2 レイヤ（前面 = outgoing / 背面 = incoming）が載ること。
        let overlapStart = try XCTUnwrap(TimelineMapping(clips: clips, transitions: transitions)
            .overlaps.first?.start)
        let overlapTime = CMTime(seconds: overlapStart + 0.05, preferredTimescale: 600)
        let overlapInstruction = try XCTUnwrap(
            videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }
                .first { $0.timeRange.start <= overlapTime && overlapTime < $0.timeRange.end })
        XCTAssertEqual(overlapInstruction.layerInstructions.count, 2,
                       "重なり区間の instruction に 2 クリップぶんのレイヤが無い")
    }

    /// 音声が 1 本も無い構成では audioMix を付けないこと、および音量クランプの契約。
    /// 実音声付きのクロスフェード（RMS 検証）は `MultiClipExportTests` が固定する。
    func test_audioMixAbsentWithoutAudioAndVolumeIsClamped() async throws {
        let url = try await makeTestVideo(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = UUID()
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 4)
        // 音声トラックの無い素材（makeTestVideo は映像のみ）では audioMix は付かない。
        let silent = try await TimelineCompositionBuilder().build(
            clips: [first, second],
            transitions: [first.id: TransitionSpec(kind: .crossfade, duration: 0.5)],
            sources: [sourceID: AVURLAsset(url: url)])
        XCTAssertNil(silent.audioMix, "音声が 1 本も無いのに audioMix が付いている")

        // 音量調整だけ（トランジション無し）でも audioMix が要る
        // ＝ 純ロジックの入口を `AudioMixFactory.make` に閉じ込めてある。
        XCTAssertEqual(AudioMixFactory.clampedVolume(1.5), 1.0)
        XCTAssertEqual(AudioMixFactory.clampedVolume(-1), 0.0)
        XCTAssertEqual(AudioMixFactory.clampedVolume(.nan), 1.0, "NaN 音量が素通りしている")
    }

    /// 同一解像度なら別素材の連結は成功すること（ガードの過剰反応防止）。
    func test_sameResolutionDifferentSources_buildSucceeds() async throws {
        let firstURL = try await makeTestVideo(seconds: 1.0)
        let secondURL = try await makeTestVideo(seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstID = UUID()
        let secondID = UUID()
        let composition = try await TimelineCompositionBuilder().build(
            clips: [TimelineClip(sourceID: firstID, sourceStart: 0, sourceEnd: 1),
                    TimelineClip(sourceID: secondID, sourceStart: 0, sourceEnd: 1)],
            sources: [firstID: AVURLAsset(url: firstURL), secondID: AVURLAsset(url: secondURL)]).composition

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }
}
