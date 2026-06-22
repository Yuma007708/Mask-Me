import AVFoundation
import CoreImage
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// Reads a video frame-by-frame, applies the face mosaic on the GPU, and writes
/// a new H.264 file. Reports progress as a `0...1` fraction.
public final class VideoMosaicExporter {
    public enum ExportError: Error {
        case noVideoTrack
        case readerSetupFailed
        case writerSetupFailed
        case pixelBufferPoolUnavailable
        case textureConversionFailed
    }

    private let renderer: MosaicRenderer
    private let landmarker: FaceLandmarking
    private let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?

    public init(renderer: MosaicRenderer, landmarker: FaceLandmarking) {
        self.renderer = renderer
        self.landmarker = landmarker
        self.ciContext = CIContext(mtlDevice: renderer.device)
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, renderer.device, nil, &textureCache
        )
    }

    /// Exports `asset` to a temporary `.mov` and returns its URL.
    public func export(
        asset: AVAsset,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)

        let reader = try makeReader(asset: asset, track: track)
        guard let trackOutput = reader.outputs.first else {
            throw ExportError.readerSetupFailed
        }

        let outputURL = makeOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // Render in the sensor's natural orientation; `transform` rotates on play.
        let (writerInput, adaptor) = try makeWriterInput(size: naturalSize, transform: transform)
        guard writer.canAdd(writerInput) else { throw ExportError.writerSetupFailed }
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        renderer.reset()

        try await processFrames(
            reader: reader,
            trackOutput: trackOutput,
            writerInput: writerInput,
            adaptor: adaptor,
            duration: duration,
            progress: progress
        )

        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? ExportError.writerSetupFailed
        }
        await progress(1.0)
        return outputURL
    }

    // MARK: - Frame loop

    private func processFrames(
        reader: AVAssetReader,
        trackOutput: AVAssetReaderOutput,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        duration: CMTime,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)

        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            try mosaicFrame(sourceBuffer: sourceBuffer, pts: pts, adaptor: adaptor, input: writerInput)

            let fraction = min(CMTimeGetSeconds(pts) / totalSeconds, 1.0)
            await progress(fraction)
        }
    }

    private func mosaicFrame(
        sourceBuffer: CVPixelBuffer,
        pts: CMTime,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput
    ) throws {
        guard let cache = textureCache,
              let inputTexture = MetalTextureUtilities.texture(from: sourceBuffer, cache: cache) else {
            throw ExportError.textureConversionFailed
        }

        let timestampMs = Int(CMTimeGetSeconds(pts) * 1000)
        let landmarks = detectLandmarks(in: sourceBuffer, timestampMs: timestampMs)

        guard let pool = adaptor.pixelBufferPool,
              let outBuffer = makePixelBuffer(from: pool),
              let outputTexture = MetalTextureUtilities.texture(from: outBuffer, cache: cache) else {
            throw ExportError.pixelBufferPoolUnavailable
        }

        renderer.render(
            input: inputTexture,
            into: outputTexture,
            landmarks: landmarks,
            waitForCompletion: true
        )

        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        adaptor.append(outBuffer, withPresentationTime: pts)
    }

    private func detectLandmarks(in buffer: CVPixelBuffer, timestampMs: Int) -> FaceLandmarkSet? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return landmarker.landmarks(in: UIImage(cgImage: cgImage), timestampMs: timestampMs)
    }

    // MARK: - Setup helpers

    private func makeReader(asset: AVAsset, track: AVAssetTrack) throws -> AVAssetReader {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.readerSetupFailed }
        reader.add(output)
        return reader
    }

    private func makeWriterInput(
        size: CGSize,
        transform: CGAffineTransform
    ) throws -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        return (input, adaptor)
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-\(UUID().uuidString).mov")
    }
}
#endif
