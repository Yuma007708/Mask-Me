import AVFoundation
import CoreImage
import UIKit
import MosaicCore

/// 加工の速度／品質バランス。検出は 1 フレームあたり複数のニューラル推論を伴い
/// 尺に比例して支配的コストになるため、検出頻度（何フレームおきに検出するか）と
/// 検出入力解像度で速度を段階制御する。検出しないフレームは直前の検出結果を保持し、
/// キャッシュ（`detectionCache`）にヒットするフレームは検出をスキップする。
/// UI／モデルから参照するため Metal ガード外に置く（純粋な値型で Metal 非依存）。
public enum ExportSpeed: Sendable, CaseIterable {
    /// 最大品質。従来挙動（2フレーム毎・800px）。精度計画の基準。
    case maxQuality
    /// 既定。検出を約1/1.5に間引き、検出解像度を落として体感品質を保ちつつ高速化。
    case balanced
    /// 最速。検出を大幅に間引く。速い動きでは追従がややラフになる。
    case fast

    /// 何フレームおきに検出するか（値が大きいほど検出回数が減る＝速い）。
    var detectionInterval: Int {
        switch self {
        case .maxQuality: return 2
        case .balanced:   return 3
        case .fast:       return 5
        }
    }

    /// 検出に渡す画像の最大幅（px）。小さいほど推論が速い（小顔検出はやや不利）。
    var detectionMaxWidth: Double {
        switch self {
        case .maxQuality: return 800
        case .balanced:   return 640
        case .fast:       return 512
        }
    }

    /// UI 表示用の短いラベル。
    public var displayName: String {
        switch self {
        case .maxQuality: return "高品質"
        case .balanced:   return "標準（推奨）"
        case .fast:       return "最速"
        }
    }
}

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
    /// 描画直前のランドマーク EMA（フレーム間の微小ちらつき吸収）。検出キャッシュには
    /// 適用しない（計測系と描画系の分離）。export ごとに reset して使う。
    private let landmarkSmoother = LandmarkSmoother()
    #if canImport(Vision)
    private let backgroundSegmenter = PersonSegmenter(quality: .balanced)
    #endif

    // MARK: - 速度計測（数値のみ・フレーム画像は一切扱わない）
    // 単一の videoQueue 上で直列に更新されるためロック不要。export ごとに reset する。
    private var perfDetectSec = 0.0
    private var perfRenderSec = 0.0
    private var perfSegSec = 0.0
    private var perfDecodeSec = 0.0
    private var perfDetectCalls = 0
    private var perfFrames = 0
    private var perfWallStart: CFAbsoluteTime = 0

    /// 検出入力の最大幅（速度段で決まる）。pump 開始時に設定し detectAll が参照する。
    private var detectMaxWidth: Double = 800

    private func resetPerf() {
        perfDetectSec = 0; perfRenderSec = 0; perfSegSec = 0; perfDecodeSec = 0
        perfDetectCalls = 0; perfFrames = 0
        perfWallStart = CFAbsoluteTimeGetCurrent()
    }

    private func logPerfSummary(totalSeconds: Double) {
        let wall = CFAbsoluteTimeGetCurrent() - perfWallStart
        let fps = wall > 0 ? Double(perfFrames) / wall : 0
        // other = wall − 計測済み各段。encode は adaptor.append の裏で writer が非同期実行するため
        // 直接計測できず、isReadyForMoreMediaData の待ち（バックプレッシャー）として other に残る。
        // Simulator は HW エンコーダ非搭載でこの encode 待ちが支配的（実機では HW で縮む）。
        let other = max(0, wall - perfDetectSec - perfRenderSec - perfSegSec - perfDecodeSec)
        // %.1f で百分率を出し、内訳が一目で分かるようにする。
        func pct(_ v: Double) -> String { String(format: "%.0f%%", wall > 0 ? v / wall * 100 : 0) }
        print("""
        [MMEXPORT] frames=\(perfFrames) videoSec=\(String(format: "%.1f", totalSeconds)) \
        wall=\(String(format: "%.1f", wall))s fps=\(String(format: "%.1f", fps))
        [MMEXPORT] detect=\(String(format: "%.1f", perfDetectSec))s(\(pct(perfDetectSec)), calls=\(perfDetectCalls)) \
        render=\(String(format: "%.1f", perfRenderSec))s(\(pct(perfRenderSec))) \
        seg=\(String(format: "%.1f", perfSegSec))s(\(pct(perfSegSec))) \
        decode=\(String(format: "%.1f", perfDecodeSec))s(\(pct(perfDecodeSec))) \
        other/encode=\(String(format: "%.1f", other))s(\(pct(other)))
        """)
    }

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
        speed: ExportSpeed = .balanced,
        /// 動画の書き出し範囲（0...1 正規化）。既定は全長。
        /// 範囲外のフレーム/音声サンプルはスキップし、writer 側の時刻を
        /// `trimRange.lowerBound` 分だけシフトして出力尺を短縮する。
        trimRange: ClosedRange<Double> = 0...1,
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

        // トリム範囲の設定: reader.timeRange で読み込み範囲を制限し、
        // 書き出し時に PTS を `trimStart` 分シフトして writer タイムラインを 0 起点に保つ。
        let totalDurationSeconds = CMTimeGetSeconds(duration)
        let clampedLower = max(0.0, min(1.0, trimRange.lowerBound))
        let clampedUpper = max(clampedLower, min(1.0, trimRange.upperBound))
        let trimStartSec = clampedLower * totalDurationSeconds
        let trimEndSec = clampedUpper * totalDurationSeconds
        let effectiveDuration: CMTime
        if clampedLower > 0.001 || clampedUpper < 0.999 {
            let start = CMTime(seconds: trimStartSec, preferredTimescale: 600)
            let dur = CMTime(seconds: trimEndSec - trimStartSec, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)
            effectiveDuration = dur
        } else {
            effectiveDuration = duration
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
            duration: effectiveDuration,
            videoSize: naturalSize,
            selectedFaceTargets: selectedFaceTargets,
            manualRegions: manualRegions,
            detectionCache: detectionCache,
            faceEnabled: faceEnabled,
            backgroundEnabled: backgroundEnabled,
            backgroundBlock: backgroundBlock,
            speed: speed,
            trimStartSec: trimStartSec,
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
        speed: ExportSpeed,
        trimStartSec: Double,
        cache: CVMetalTextureCache,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let detectionInterval = speed.detectionInterval
        detectMaxWidth = speed.detectionMaxWidth
        // 同一 exporter インスタンスの再利用に備え、前回 export の EMA 状態を捨てる。
        landmarkSmoother.reset()
        resetPerf()

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
                    let decodeStart = CFAbsoluteTimeGetCurrent()
                    let nextSample = videoOutput.copyNextSampleBuffer()
                    perfDecodeSec += CFAbsoluteTimeGetCurrent() - decodeStart
                    guard reader.status == .reading, let sample = nextSample else {
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
                            trimStartSec: trimStartSec,
                            adaptor: adaptor,
                            input: videoInput,
                            cache: cache,
                            progress: progress
                        )
                    }
                }
            }

            // 音声：再エンコードせずサンプルをそのままコピー。
            // トリム時は PTS をシフトして writer タイムラインを 0 起点に揃える。
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
                        if trimStartSec > 0.001,
                           let shifted = Self.shiftSample(sample, byMinusSeconds: trimStartSec) {
                            audioInput.append(shifted)
                        } else {
                            audioInput.append(sample)
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                self.logPerfSummary(totalSeconds: totalSeconds)
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
        trimStartSec: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        cache: CVMetalTextureCache,
        progress: (Double) -> Void
    ) {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let rawPts = CMSampleBufferGetPresentationTimeStamp(sample)
        // トリム時は writer の 0 起点に揃えるため PTS をシフトする。
        // 検出（timestampMs）と detectionCache の検索は元動画時刻のままで一貫させる。
        let pts: CMTime
        if trimStartSec > 0.001 {
            let shifted = CMTimeGetSeconds(rawPts) - trimStartSec
            pts = CMTime(seconds: max(0, shifted), preferredTimescale: 600)
        } else {
            pts = rawPts
        }
        let timeSec = CMTimeGetSeconds(rawPts)
        let timestampMs = Int(timeSec * 1000)

        if frameIndex % detectionInterval == 0 {
            if faceEnabled {
                // キャッシュから近傍フレームを探す（なければ新規検出）
                let fromCache = lookupCache(detectionCache, at: timeSec)
                if !fromCache.isEmpty {
                    cachedLandmarkSets = filterToSelected(fromCache, targets: selectedFaceTargets)
                } else {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let detected = detectAll(in: sourceBuffer, timestampMs: timestampMs)
                    perfDetectSec += CFAbsoluteTimeGetCurrent() - t0
                    perfDetectCalls += 1
                    cachedLandmarkSets = filterToSelected(detected, targets: selectedFaceTargets)
                }
                // 描画直前の EMA。検出更新のタイミング（= 位置が変わりうる瞬間）にだけかける。
                cachedLandmarkSets = landmarkSmoother.smooth(cachedLandmarkSets)
            } else {
                cachedLandmarkSets = []
            }
            // 背景マスクも同じ間隔で更新（毎フレームは重いため）。
            // セグメンテーションが一時的に失敗（nil）したら直前のマスクを維持する。
            // nil で上書きすると、その間のフレームで背景が無加工のまま書き出されてしまう。
            if backgroundEnabled {
                let s0 = CFAbsoluteTimeGetCurrent()
                let mask = segmentBackground(sourceBuffer)
                perfSegSec += CFAbsoluteTimeGetCurrent() - s0
                if let mask {
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

        let r0 = CFAbsoluteTimeGetCurrent()
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
        perfRenderSec += CFAbsoluteTimeGetCurrent() - r0
        perfFrames += 1

        // Metal テクスチャキャッシュに溜まった参照を解放。
        CVMetalTextureCacheFlush(cache, 0)

        frameIndex += 1
        // トリム時は「トリム範囲内の進捗」で 0..1 化して表示する。
        let progressSec = max(0, timeSec - trimStartSec)
        progress(min(progressSec / totalSeconds, 1.0))
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
        let scale = min(detectMaxWidth / ci.extent.width, 1.0)
        let resized = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(resized, from: resized.extent) else { return [] }
        return landmarker.allLandmarks(in: UIImage(cgImage: cg), timestampMs: timestampMs)
    }

    /// 検出キャッシュの両側補間参照。仕様は `DetectionBridge` を参照
    /// （MosaicEditorModel のプレビューおよび精度計測と共通の挙動）。lerp 有効。
    private func lookupCache(_ cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        DetectionBridge(interpolates: true).faces(in: cache, at: time)
    }

    /// 選択顔の時系列トラッカー。旧実装は選択時の静的位置と距離 0.3 で毎フレーム照合
    /// しており、顔が移動しただけで書き出し動画からモザイクが消えていた
    /// （実機報告「フレームアウト→イン／後ろ向き→正面のあと一切掛からない」の
    /// エクスポート側の原因）。SelectedFaceTracker がマッチのたびに位置を追従させる。
    private var selectedTracker: SelectedFaceTracker?

    private func filterToSelected(_ faces: [FaceLandmarkSet], targets: [FaceTarget]) -> [FaceLandmarkSet] {
        if targets.isEmpty { return faces }
        if selectedTracker == nil {
            selectedTracker = SelectedFaceTracker(
                initialCentroids: targets.map { SelectedFaceTracker.centroid(of: $0.landmarks) }
            )
        }
        return selectedTracker?.filter(faces) ?? faces
    }

    // MARK: - Setup helpers

    private func makeVideoOutput(track: AVAssetTrack) -> AVAssetReaderTrackOutput {
        // Metal 互換を明示しないと、環境によってはリーダのバッファから
        // `CVMetalTextureCacheCreateTextureFromImage` が失敗し、モザイク描画が全フレーム
        // 早期リターン → 出力が無加工/空になる（Simulator で実測確認済みの潜在バグ）。
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
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

    /// トリム開始時刻ぶんだけ PTS と DTS を負方向にシフトした CMSampleBuffer を返す。
    /// audio でタイムラインを 0 起点に揃えるために使う。
    static func shiftSample(_ sample: CMSampleBuffer, byMinusSeconds seconds: Double) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return nil }
        var timingInfos = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo.invalid,
            count: count
        )
        var infoCountOut: CMItemCount = 0
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: count,
            arrayToFill: &timingInfos,
            entriesNeededOut: &infoCountOut
        )
        guard status == noErr else { return nil }
        let shift = CMTime(seconds: seconds, preferredTimescale: 600)
        for i in 0..<count {
            if timingInfos[i].presentationTimeStamp.isValid {
                timingInfos[i].presentationTimeStamp =
                    CMTimeSubtract(timingInfos[i].presentationTimeStamp, shift)
            }
            if timingInfos[i].decodeTimeStamp.isValid {
                timingInfos[i].decodeTimeStamp =
                    CMTimeSubtract(timingInfos[i].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfos,
            sampleBufferOut: &out
        )
        return copyStatus == noErr ? out : nil
    }
}
#endif
