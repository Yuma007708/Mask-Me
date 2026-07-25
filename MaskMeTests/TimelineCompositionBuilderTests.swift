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
            clips: [clip], sources: [sourceID: AVURLAsset(url: url)])

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
            .build(clips: [first, second], sources: sources)

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    /// 素材が見つからない場合はエラーを投げること（黙って短い動画を作らない）。
    func test_missingSourceThrows() async throws {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 1)
        do {
            _ = try await TimelineCompositionBuilder().build(clips: [clip], sources: [:])
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
            .build(clips: [clip], sources: [sourceID: AVURLAsset(url: url)])

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
            .build(clips: [clip], sources: [sourceID: AVURLAsset(url: url)])

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
            .build(clips: [normal, fast], sources: sources)

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    // MARK: - S4: 解像度混在ガード

    /// 解像度が異なる素材の連結は明示エラーになること（S8 の videoComposition
    /// 導入まで、黙って壊れた縮尺の動画を作らない）。
    func test_mixedResolutionsThrow() async throws {
        let smallURL = try await makeTestVideo(seconds: 1.0)
        let largeURL = try await makeTestVideo(seconds: 1.0, width: 640, height: 480)
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
        do {
            _ = try await TimelineCompositionBuilder().build(clips: clips, sources: sources)
            XCTFail("解像度混在を検出できていない（壊れた縮尺の動画が黙って作られる）")
        } catch TimelineCompositionBuilder.BuildError.mixedVideoFormats {
            // 期待どおり
        }
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
            sources: [firstID: AVURLAsset(url: firstURL), secondID: AVURLAsset(url: secondURL)])

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }
}
