import AVFoundation
import CoreImage
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 動画をフレームごとに処理してモザイクを適用し、新しい .mp4 ファイルを生成する。
/// 元動画の音声トラックはそのまま（再エンコードせず）保持する。
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
    #if canImport(Vision)
    private let backgroundSegmenter = PersonSegmenter(quality: .balanced)
    #endif

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
    ///   - faceEnabled: 顔モザイク全体の ON/OFF。手動矩形も顔検出の補助なので
    ///     これに従う（false なら顔・手動矩形ともに適用しない）。
    public func export(
        asset: AVAsset,
        selectedFaceTargets: [FaceTarget] = [],
        manualRegions: [ManualRegion] = [],
        detectionCache: [Double: [FaceLandmarkSet]] = [:],
        faceEnabled: Bool = true,
        backgroundEnabled: Bool = false,
        backgroundBlock: Float = 28,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first

        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let estimatedDataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
        var audioFormat: CMFormatDescription?
        if let audioTrack {
            audioFormat = (try? await audioTrack.load(.formatDescriptions))?.first
        }

        // --- Reader: 映像（BGRA）＋ 音声（パススルー） ---
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = makeVideoOutput(track: videoTrack)
        guard reader.canAdd(videoOutput) else { throw ExportError.readerSetupFailed }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // --- Writer: 映像（HEVC優先）＋ 音声（パススルー） ---
        let outputURL = makeOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let (videoInput, adaptor) = try makeVideoWriterInput(
            size: naturalSize,
            transform: transform,
            estimatedDataRate: estimatedDataRate,
            writer: writer
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let aIn = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audioFormat
            )
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            } else {
                audioOutput = nil
            }
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        renderer.reset()

        guard let cache = textureCache else { throw ExportError.textureConversionFailed }

        return try await pump(
            reader: reader,
            writer: writer,
            outputURL: outputURL,
            videoOutput: videoOutput,
            videoInput: videoInput,
            adaptor: adaptor,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: duration,
            videoSize: naturalSize,
            selectedFaceTargets: selectedFaceTargets,
            manualRegions: manualRegions,
            detectionCache: detectionCache,
            faceEnabled: faceEnabled,
            backgroundEnabled: backgroundEnabled,
            backgroundBlock: backgroundBlock,
            cache: cache,
            progress: progress
        )
    }

    // MARK: - Pump（ビジーウェイトなしの読み書き）

    // swiftlint:disable:next function_parameter_count function_body_length
    private func pump(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputURL: URL,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        duration: CMTime,
        videoSize: CGSize,
        selectedFaceTargets: [FaceTarget],
        manualRegions: [ManualRegion],
        detectionCache: [Double: [FaceLandmarkSet]],
        faceEnabled: Bool,
        backgroundEnabled: Bool,
        backgroundBlock: Float,
        cache: CVMetalTextureCache,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let detectionInterval = 2

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()

            // 映像：必要になったタイミングでだけコールバックが呼ばれる（Thread.sleep 不要）。
            var frameIndex = 0
            var cachedLandmarkSets: [FaceLandmarkSet] = []
            var cachedBackgroundMask: MaskBuffer?
            let videoQueue = DispatchQueue(label: "mask-me.export.video")
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                while videoInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sample = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    // フレーム毎の一時オブジェクトを都度解放し、長尺でのジェットサムを防ぐ。
                    autoreleasepool {
                        processVideoSample(
                            sample,
                            frameIndex: &frameIndex,
                            cachedLandmarkSets: &cachedLandmarkSets,
                            cachedBackgroundMask: &cachedBackgroundMask,
                            detectionInterval: detectionInterval,
                            selectedFaceTargets: selectedFaceTargets,
                            manualRegions: manualRegions,
                            detectionCache: detectionCache,
                            faceEnabled: faceEnabled,
                            backgroundEnabled: backgroundEnabled,
                            backgroundBlock: backgroundBlock,
                            videoSize: videoSize,
                            totalSeconds: totalSeconds,
                            adaptor: adaptor,
                            input: videoInput,
                            cache: cache,
                            progress: progress
                        )
                    }
                }
            }

            // 音声：再エンコードせずサンプルをそのままコピー。
            if let audioInput, let audioOutput {
                let audioQueue = DispatchQueue(label: "mask-me.export.audio")
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard reader.status == .reading,
                              let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        audioInput.append(sample)
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if reader.status == .failed {
                    continuation.resume(throwing: reader.error ?? ExportError.readerSetupFailed)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        progress(1.0)
                        continuation.resume(returning: outputURL)
                    } else {
                        continuation.resume(
                            throwing: writer.error ?? ExportError.writerSetupFailed
                        )
                    }
                }
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func processVideoSample(
        _ sample: CMSampleBuffer,
        frameIndex: inout Int,
        cachedLandmarkSets: inout [FaceLandmarkSet],
        cachedBackgroundMask: inout MaskBuffer?,
        detectionInterval: Int,
        selectedFaceTargets: [FaceTarget],
        manualRegions: [ManualRegion],
        detectionCache: [Double: [FaceLandmarkSet]],
        faceEnabled: Bool,
        backgroundEnabled: Bool,
        backgroundBlock: Float,
        videoSize: CGSize,
        totalSeconds: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        cache: CVMetalTextureCache,
        progress: (Double) -> Void
    ) {
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
            // 背景マスクも同じ間隔で更新（毎フレームは重いため）。
            // セグメンテーションが一時的に失敗（nil）したら直前のマスクを維持する。
            // nil で上書きすると、その間のフレームで背景が無加工のまま書き出されてしまう。
            if backgroundEnabled {
                if let mask = segmentBackground(sourceBuffer) {
                    cachedBackgroundMask = mask
                }
            } else {
                cachedBackgroundMask = nil
            }
        }

        // 手動矩形は顔検出の補助なので顔モザイク（faceEnabled）の状態に従う。
        let additionalPaths = faceEnabled
            ? manualRegions.map { region -> FaceMaskBuilder.RegionPath in
                let path = FaceMaskBuilder.rectPath(from: region.normalizedRect, in: videoSize)
                return FaceMaskBuilder.RegionPath(path: path, value: 0.4)
            }
            : []

        try? mosaicFrame(
            sourceBuffer: sourceBuffer,
            pts: pts,
            landmarkSets: cachedLandmarkSets,
            additionalPaths: additionalPaths,
            backgroundMask: cachedBackgroundMask,
            backgroundBlock: backgroundBlock,
            adaptor: adaptor,
            input: input,
            cache: cache
        )

        // Metal テクスチャキャッシュに溜まった参照を解放。
        CVMetalTextureCacheFlush(cache, 0)

        frameIndex += 1
        progress(min(timeSec / totalSeconds, 1.0))
    }

    private func mosaicFrame(
        sourceBuffer: CVPixelBuffer,
        pts: CMTime,
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath],
        backgroundMask: MaskBuffer?,
        backgroundBlock: Float,
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

        // 背景パスがある場合は、顔モザイクを中間テクスチャに描いてから背景を出力に重ねる。
        if let backgroundMask,
           let intermediate = MetalTextureUtilities.makeOutputTexture(like: inputTexture, device: renderer.device) {
            renderer.render(
                input: inputTexture, into: intermediate,
                landmarkSets: landmarkSets, additionalPaths: additionalPaths,
                waitForCompletion: true
            )
            renderer.renderBackground(
                input: intermediate, into: outputTexture,
                mask: backgroundMask,
                block: backgroundBlock, waitForCompletion: true
            )
        } else {
            renderer.render(
                input: inputTexture, into: outputTexture,
                landmarkSets: landmarkSets, additionalPaths: additionalPaths,
                waitForCompletion: true
            )
        }

        // 呼び出し側が isReadyForMoreMediaData を確認済みなのでビジーウェイト不要。
        adaptor.append(outBuffer, withPresentationTime: pts)
    }

    /// 動画フレームの背景マスク（人物前景を反転）。Vision 非対応環境では nil。
    private func segmentBackground(_ buffer: CVPixelBuffer) -> MaskBuffer? {
        #if canImport(Vision)
        return backgroundSegmenter.backgroundMask(pixelBuffer: buffer)
        #else
        return nil
        #endif
    }

    // MARK: - Detection helpers

    private func detectAll(in buffer: CVPixelBuffer, timestampMs: Int) -> [FaceLandmarkSet] {
        let ci = CIImage(cvPixelBuffer: buffer)
        let scale = min(800.0 / ci.extent.width, 1.0)
        let resized = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(resized, from: resized.extent) else { return [] }
        return landmarker.allLandmarks(in: UIImage(cgImage: cg), timestampMs: timestampMs)
    }

    /// 前後 0.25 秒以内の両側に検出があるときだけ直近フレームで補間する。片側だけ
    /// （フレームアウト／イン境界）は空を返し、呼び出し側のライブ再検出に委ねる。
    /// 直近の検出を無条件に外挿すると、顔がフレーム外へ出た位置にモザイクが固定される。
    private func lookupCache(_ cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        if let exact = cache[time], !exact.isEmpty { return exact }
        // 15fps 検出基準で 5 フレームまでの抜けをブリッジする（MosaicEditorModel と同値）。
        let bridgeWindow = 5.0 / 15.0
        var before: (dist: Double, faces: [FaceLandmarkSet])?
        var after: (dist: Double, faces: [FaceLandmarkSet])?
        for (t, faces) in cache where !faces.isEmpty {
            let d = abs(t - time)
            guard d <= bridgeWindow else { continue }
            if t <= time {
                if before == nil || d < before!.dist { before = (d, faces) }
            } else {
                if after == nil || d < after!.dist { after = (d, faces) }
            }
        }
        guard let before, let after else { return [] }
        // before の顔のうち、after にも IoU > 0.3 で対応する顔があるものだけ補間に使う。
        // フレームアウト→イン（位置が大きく変わる）は除外され、アウト位置への固定を防ぐ。
        return before.faces.filter { $0.hasCounterpart(in: after.faces) }
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

    private func makeVideoOutput(track: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        return output
    }

    /// HEVC を優先し、対応していなければ H.264 にフォールバックして映像入力を作る。
    /// 作成した入力は writer に追加済みで返す。
    private func makeVideoWriterInput(
        size: CGSize,
        transform: CGAffineTransform,
        estimatedDataRate: Float,
        writer: AVAssetWriter
    ) throws -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        // 元動画のビットレートを踏襲（取得不可なら解像度から概算: 約0.15bpp×30fps）。
        let bitrate = estimatedDataRate > 0
            ? Int(estimatedDataRate)
            : Int(Double(size.width) * Double(size.height) * 0.15 * 30)

        func makeInput(codec: AVVideoCodecType) -> AVAssetWriterInput {
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            return input
        }

        var input = makeInput(codec: .hevc)
        if !writer.canAdd(input) {
            input = makeInput(codec: .h264)
        }
        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)

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
            .appendingPathComponent("mosaic-\(UUID().uuidString).mp4")
    }
}
#endif
