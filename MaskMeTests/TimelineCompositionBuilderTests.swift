import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// Composition 構築のテスト。実素材を使わず、生成した無音・単色動画で検証する。
final class TimelineCompositionBuilderTests: XCTestCase {
    /// テスト用に指定秒数の単色動画を生成する。
    /// 外部の素材ファイルに依存しないための自前生成。
    private func makeTestVideo(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
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
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * 240)
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
}
