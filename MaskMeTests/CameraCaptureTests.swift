import AVFoundation
import CoreVideo
import XCTest
@testable import MaskMe

#if canImport(Metal)

/// リアルタイム撮影の焼き込み経路（レコーダー / パイプライン）の検証。
/// Simulator にカメラは無いため、合成フレームを実機の映像キャプチャと同じ形
/// （BGRA CMSampleBuffer・単調増加 PTS）で流し込んで出力ファイルを確かめる。
final class CameraCaptureTests: XCTestCase {
    private let size = CGSize(width: 720, height: 1280)

    // MARK: - CameraRecorder

    /// 30fps × 1 秒ぶんのフレームで再生可能な mp4 ができること。
    /// リアルタイム writer はエンコーダが追いつくまで `isReadyForMoreMediaData=false` を
    /// 返すため、実機のフレーム到着間隔と同じく readiness を待ってから追記する。
    func test_recorder_writesPlayableMovie() async throws {
        let recorder = try CameraRecorder(size: size, fps: 30, includeAudio: false)
        for i in 0..<30 {
            let buffer = try makePixelBuffer(fill: UInt8(i * 8))
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            var appended = false
            for _ in 0..<200 where !appended {
                appended = recorder.appendVideo(buffer, at: pts)
                if !appended { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            XCTAssertTrue(appended, "frame \(i) の追記に失敗")
        }
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(duration, 1.0, accuracy: 0.2)
        XCTAssertEqual(tracks.count, 1)
        let trackSize = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(trackSize.width, size.width)
        XCTAssertEqual(trackSize.height, size.height)
    }

    /// 開始前 PTS の音声は捨てられ、映像開始後の音声だけが書かれてもクラッシュしない
    /// （音声トラック有りの構成でも finish が成功すること）。
    func test_recorder_withAudioTrack_finishes() async throws {
        let recorder = try CameraRecorder(size: size, fps: 30, includeAudio: true)
        for i in 0..<10 {
            let buffer = try makePixelBuffer(fill: 128)
            recorder.appendVideo(buffer, at: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// cancel は一時ファイルを残さない。
    func test_recorder_cancelRemovesFile() throws {
        let recorder = try CameraRecorder(size: size, fps: 30, includeAudio: false)
        let buffer = try makePixelBuffer(fill: 0)
        recorder.appendVideo(buffer, at: .zero)
        recorder.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.outputURL.path))
    }

    // MARK: - CameraMosaicPipeline

    /// 実機の映像コールバックと同じ流れで録画し、プレビューと mp4 の両方が出ること。
    func test_pipeline_recordsMovieAndPublishesPreview() async throws {
        let pipeline = try XCTUnwrap(
            CameraMosaicPipeline(settings: DetectionSettings()),
            "Simulator の Metal が必要")
        var previewCount = 0
        pipeline.onPreviewImage = { _ in previewCount += 1 }

        pipeline.startRecording(includeAudio: false)
        for i in 0..<30 {
            let sample = try makeSampleBuffer(
                fill: UInt8(i * 8), pts: CMTime(value: CMTimeValue(i), timescale: 30))
            pipeline.process(sampleBuffer: sample)
            // 実機と同じ 30fps ペーシング（追いつかないフレームを落とすのは正常挙動
            // だが、テストでは尺の検証のため全フレームを書かせる）
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        let recorder = try XCTUnwrap(pipeline.stopRecording(), "レコーダーが生成されていない")
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertGreaterThan(previewCount, 0, "録画中のプレビューが1枚も出ていない")
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.25)
        // 検出はバックグラウンドで走るため、終了前に静かに待つ（クラッシュ検知目的）
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// 写真撮影はフレームと同じ解像度の UIImage を返すこと。
    func test_pipeline_capturePhoto_returnsFullResolutionImage() async throws {
        let pipeline = try XCTUnwrap(CameraMosaicPipeline(settings: DetectionSettings()))
        let sample = try makeSampleBuffer(fill: 200, pts: .zero)
        let photo = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            pipeline.capturePhoto { cont.resume(returning: $0) }
            pipeline.process(sampleBuffer: sample)
        }
        let image = try XCTUnwrap(photo, "写真が生成されていない")
        XCTAssertEqual(image.size.width * image.scale, size.width)
        XCTAssertEqual(image.size.height * image.scale, size.height)
    }

    /// 横長（コネクション回転が効かなかった）フレームはパイプラインが 90° 回転して
    /// 縦長に正規化すること（実機報告: フロントカメラだけ 90 度ずれる、の回帰テスト）。
    func test_pipeline_normalizesLandscapeFramesToPortrait() async throws {
        let pipeline = try XCTUnwrap(CameraMosaicPipeline(settings: DetectionSettings()))
        let landscape = CGSize(width: 1280, height: 720)
        let sample = try makeSampleBuffer(fill: 90, pts: .zero, size: landscape)
        let photo = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            pipeline.capturePhoto { cont.resume(returning: $0) }
            pipeline.process(sampleBuffer: sample)
        }
        let image = try XCTUnwrap(photo, "写真が生成されていない")
        XCTAssertEqual(image.size.width * image.scale, landscape.height, "縦長に回転されるはず")
        XCTAssertEqual(image.size.height * image.scale, landscape.width, "縦長に回転されるはず")
    }

    // MARK: - ヘルパー

    private func makePixelBuffer(fill: UInt8, size: CGSize? = nil) throws -> CVPixelBuffer {
        let size = size ?? self.size
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill),
                   CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func makeSampleBuffer(fill: UInt8, pts: CMTime,
                                  size: CGSize? = nil) throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer(fill: fill, size: size)
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: try XCTUnwrap(formatDesc),
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw NSError(domain: "test", code: Int(status))
        }
        return sample
    }
}
#endif
