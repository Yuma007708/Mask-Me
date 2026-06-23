import AVFoundation
import CoreImage
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 動画をフレームごとに処理してモザイクを適用し、新しい .mov ファイルを生成する。
public final class VideoMosaicExporter: @unchecked Sendable {
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

    /// 動画をエクスポートして一時 URL を返す。
    /// - Parameters:
    ///   - selectedFaceTargets: モザイク対象として選択された顔。空の場合は全顔に適用。
    ///   - manualRegions: 手動指定矩形（全フレームに適用）。
    ///   - detectionCache: 事前スキャンで得た検出キャッシュ（不使用のときは空辞書）。
    ///   - faceEnabled: 顔モザイク全体の ON/OFF。false なら手動矩形のみ適用。
    public func export(
        asset: AVAsset,
        selectedFaceTargets: [FaceTarget] = [],
        manualRegions: [ManualRegion] = [],
        detectionCache: [Double: [FaceLandmarkSet]] = [:],
        faceEnabled: Bool = true,
        progress: @Sendable @escaping (Double) -> Void
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
        let (writerInput, adaptor) = try makeWriterInput(size: naturalSize, transform: transform)
        guard writer.canAdd(writerInput) else { throw ExportError.writerSetupFailed }
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        renderer.reset()

        let targets = selectedFaceTargets
        let regions = manualRegions
        let cache = detectionCache
        let enabled = faceEnabled

        try await Task.detached(priority: .userInitiated) { [self] in
            self.processFrames(
                trackOutput: trackOutput,
                writerInput: writerInput,
                adaptor: adaptor,
                duration: duration,
                selectedFaceTargets: targets,
                manualRegions: regions,
                detectionCache: cache,
                faceEnabled: enabled,
                videoSize: naturalSize,
                progress: progress
            )
        }.value

        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? ExportError.writerSetupFailed
        }
        progress(1.0)
        return outputURL
    }

    // MARK: - Frame loop

    private func processFrames(
        trackOutput: AVAssetReaderOutput,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        duration: CMTime,
        selectedFaceTargets: [FaceTarget],
        manualRegions: [ManualRegion],
        detectionCache: [Double: [FaceLandmarkSet]],
        faceEnabled: Bool,
        videoSize: CGSize,
        progress: @Sendable (Double) -> Void
    ) {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let detectionInterval = 2
        var frameIndex = 0
        var cachedLandmarkSets: [FaceLandmarkSet] = []

        guard let cache = textureCache else { return }

        while let sample = trackOutput.copyNextSampleBuffer() {
            // 各フレームの一時オブジェクト（CIImage/CGImage/テクスチャ等）を都度解放し、
            // 長尺動画でメモリが膨張してジェットサム(強制終了)される問題を防ぐ。
            autoreleasepool {
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let timeSec = CMTimeGetSeconds(pts)
                let timestampMs = Int(timeSec * 1000)

                if frameIndex % detectionInterval == 0 {
                    if faceEnabled {
                        // キャッシュから近傍フレームを探す（なければ新規検出）
                        let fromCache = lookupCache(detectionCache, at: timeSec)
                        if !fromCache.isEmpty {
                            cachedLandmarkSets = filterToSelected(fromCache, targets: selectedFaceTargets)
                        } else {
                            let detected = detectAll(in: sourceBuffer, timestampMs: timestampMs)
                            cachedLandmarkSets = filterToSelected(detected, targets: selectedFaceTargets)
                        }
                    } else {
                        cachedLandmarkSets = []
                    }
                }

                let additionalPaths = manualRegions.map { region -> FaceMaskBuilder.RegionPath in
                    let path = FaceMaskBuilder.rectPath(from: region.normalizedRect, in: videoSize)
                    return FaceMaskBuilder.RegionPath(path: path, value: 0.4)
                }

                try? mosaicFrame(
                    sourceBuffer: sourceBuffer,
                    pts: pts,
                    landmarkSets: cachedLandmarkSets,
                    additionalPaths: additionalPaths,
                    adaptor: adaptor,
                    input: writerInput,
                    cache: cache
                )

                // Metal テクスチャキャッシュに溜まった参照を解放。
                CVMetalTextureCacheFlush(cache, 0)

                frameIndex += 1
                progress(min(timeSec / totalSeconds, 1.0))
            }
        }
    }

    private func mosaicFrame(
        sourceBuffer: CVPixelBuffer,
        pts: CMTime,
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath],
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        cache: CVMetalTextureCache
    ) throws {
        guard let inputTexture = MetalTextureUtilities.texture(from: sourceBuffer, cache: cache) else {
            throw ExportError.textureConversionFailed
        }
        guard let pool = adaptor.pixelBufferPool,
              let outBuffer = makePixelBuffer(from: pool),
              let outputTexture = MetalTextureUtilities.texture(from: outBuffer, cache: cache) else {
            throw ExportError.pixelBufferPoolUnavailable
        }

        renderer.render(
            input: inputTexture,
            into: outputTexture,
            landmarkSets: landmarkSets,
            additionalPaths: additionalPaths,
            waitForCompletion: true
        )

        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        adaptor.append(outBuffer, withPresentationTime: pts)
    }

    // MARK: - Detection helpers

    private func detectAll(in buffer: CVPixelBuffer, timestampMs: Int) -> [FaceLandmarkSet] {
        let ci = CIImage(cvPixelBuffer: buffer)
        let scale = min(800.0 / ci.extent.width, 1.0)
        let resized = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(resized, from: resized.extent) else { return [] }
        return landmarker.allLandmarks(in: UIImage(cgImage: cg), timestampMs: timestampMs)
    }

    private func lookupCache(_ cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        if let exact = cache[time] { return exact }
        var best: (dist: Double, faces: [FaceLandmarkSet]) = (0.3, [])
        for (t, faces) in cache {
            let d = abs(t - time)
            if d < best.dist { best = (d, faces) }
        }
        return best.faces
    }

    private func filterToSelected(_ faces: [FaceLandmarkSet], targets: [FaceTarget]) -> [FaceLandmarkSet] {
        if targets.isEmpty { return faces }
        return faces.filter { face in
            let fc = normalizedCentroid(of: face)
            return targets.contains { target in
                let tc = normalizedCentroid(of: target.landmarks)
                return hypot(fc.x - tc.x, fc.y - tc.y) < 0.3
            }
        }
    }

    private func normalizedCentroid(of lm: FaceLandmarkSet) -> CGPoint {
        guard !lm.points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        var sx: Float = 0; var sy: Float = 0
        for p in lm.points { sx += p.x; sy += p.y }
        let n = Float(lm.points.count)
        return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
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
