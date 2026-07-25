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

/// 音声書き出しの経路。S7 の AudioPipelineDecision へ育てる土台として、
/// 分岐判定をこの決定関数 1 箇所に閉じ込める。
///
/// - `passthrough`: 元パケットを無変換コピー（フェーズ1 の bit 同一忠実度を温存）。
/// - `reencode`: PCM デコード読み → AAC 再エンコード。圧縮パススルーの読みは
///   `copyNextSampleBuffer` がセグメント単位の巨大バッチ（実測 1s 超）で届き、
///   マルチセグメント composition では reader.timeRange / 自前ゲートのどちらも
///   トリム位置で正しく切れない（-16364 失敗や音声全損の実測あり）。
///   デコード済み PCM なら timeRange がサンプル精度で機能する。
enum AudioExportPipeline: Equatable {
    case passthrough
    case reencode

    /// 現時点の判定基準はトリムの有無だけ（rate≠1 のピッチ保持等は S7 の仕事）。
    static func decide(isTrimming: Bool) -> AudioExportPipeline {
        isTrimming ? .reencode : .passthrough
    }
}

#if canImport(Metal)
import Metal

// フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
// swiftlint:disable file_length type_body_length

/// 動画をフレームごとに処理してモザイクを適用し、新しい .mp4 ファイルを生成する。
/// 音声はトリム無しなら元トラックをそのまま（再エンコードせず）保持し、
/// トリム時のみ AAC 再エンコードする（`AudioExportPipeline` 参照）。
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

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable cyclomatic_complexity function_body_length
    /// 動画をエクスポートして一時 URL を返す。
    /// - Parameters:
    ///   - selectedFaceTargets: モザイク対象として選択された顔。空の場合は全顔に適用。
    ///   - manualRegions: 手動指定矩形（全フレームに適用）。
    ///   - detectionCaches: 素材IDごとの検出キャッシュ（キーは素材内時刻）。
    ///     フレーム PTS（合成時刻）を `mapping` で素材位置へ写像してから参照する
    ///     （丸め・近傍補間は必ず写像の後。合成時刻のまま丸めると rate≠1 でずれる）。
    ///   - mapping: 合成時刻→素材位置の写像。`asset`（合成結果）を構築したのと
    ///     同じクリップ列から作ること。クリップ境界の時系列リセット判定にも使う。
    ///     空の写像ではキャッシュ参照と境界リセットが無効になるだけで、
    ///     全フレーム自前検出で完走する（素の AVAsset 書き出し・テスト互換）。
    ///   - faceEnabled: 顔モザイク全体の ON/OFF。手動矩形も顔検出の補助なので
    ///     これに従う（false なら顔・手動矩形ともに適用しない）。
    public func export(
        asset: AVAsset,
        selectedFaceTargets: [FaceTarget] = [],
        manualRegions: [ManualRegion] = [],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]] = [:],
        mapping: TimelineMapping = TimelineMapping(clips: []),
        faceEnabled: Bool = true,
        backgroundEnabled: Bool = false,
        backgroundBlock: Float = 28,
        speed: ExportSpeed = .balanced,
        /// 動画の書き出し範囲（0...1 正規化）。既定は全長。
        /// 範囲外のフレーム/音声サンプルは reader.timeRange で読まず、writer 側の
        /// 時刻を `trimRange.lowerBound` 分シフトして出力尺を短縮する。
        /// トリム時の音声はパススルーではなく AAC 再エンコードになる
        /// （`AudioExportPipeline` 参照。トリム無しは従来どおり無変換コピー）。
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

        // トリム範囲の計算（音声リーダーの構成が変わるため、出力の追加より先に行う）。
        let totalDurationSeconds = CMTimeGetSeconds(duration)
        let clampedLower = max(0.0, min(1.0, trimRange.lowerBound))
        let clampedUpper = max(clampedLower, min(1.0, trimRange.upperBound))
        let trimStartSec = clampedLower * totalDurationSeconds
        let trimEndSec = clampedUpper * totalDurationSeconds
        let isTrimming = clampedLower > 0.001 || clampedUpper < 0.999

        // 音声経路の決定（パススルー / 再エンコード。判定は AudioExportPipeline に集約）。
        //
        // トリム時は**別リーダー + AVAssetReaderAudioMixOutput（デコード済み PCM）**で読む。
        // 圧縮パススルー読みは copyNextSampleBuffer がセグメント単位の巨大バッチで届き、
        // ①マルチセグメント composition + timeRange で -16364 失敗、②自前ゲートでは
        // トリム範囲と交差するバッチを丸ごと採否してしまい音声全損、の両方を実測済み。
        // デコード済み PCM なら reader.timeRange がサンプル精度で機能する
        // （MultiClipExportTests の trim 系テストが RMS 解析込みで固定している）。
        // 映像は従来どおり主リーダー側の timeRange で制限する。
        let audioPipeline = AudioExportPipeline.decide(isTrimming: isTrimming)
        var audioOutput: AVAssetReaderOutput?
        var separateAudioReader: AVAssetReader?
        if let audioTrack {
            switch audioPipeline {
            case .passthrough:
                let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                out.alwaysCopiesSampleData = false
                if reader.canAdd(out) {
                    reader.add(out)
                    audioOutput = out
                }
            case .reencode:
                // ≤2ch は audioSettings nil = 非圧縮（LinearPCM）のネイティブデコード。
                // >2ch（5.1ch 等）はデコード段でステレオ PCM へダウンミックスする
                // （`reencodeDecodeSettings(matching:)` 参照）。
                // TODO(S7): trim × rate>1 は音声末尾に約 0.11s の余剰が残る
                //   （AudioMixOutput.timeRange × scaleTimeRange 固有）。S7 で対応。
                // TODO(S7): トリム出力尺の accuracy（0.2）の締め付けと trim×rate の
                //   組み合わせテスト追加も S7 で行う。
                let out = AVAssetReaderAudioMixOutput(
                    audioTracks: [audioTrack],
                    audioSettings: Self.reencodeDecodeSettings(matching: audioFormat))
                out.alwaysCopiesSampleData = false
                let audioReader = try AVAssetReader(asset: asset)
                audioReader.timeRange = CMTimeRange(
                    start: CMTime(seconds: trimStartSec, preferredTimescale: 600),
                    duration: CMTime(seconds: trimEndSec - trimStartSec, preferredTimescale: 600))
                if audioReader.canAdd(out) {
                    audioReader.add(out)
                    audioOutput = out
                    separateAudioReader = audioReader
                }
            }
        }

        // --- Writer: 映像（HEVC優先）＋ 音声（パススルー or AAC 再エンコード） ---
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
            let aIn: AVAssetWriterInput
            switch audioPipeline {
            case .passthrough:
                aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: audioFormat
                )
            case .reencode:
                // デコード済み PCM を AAC で書き直す。sourceFormatHint は渡さない
                // （渡すのは元の圧縮フォーマット記述であり、PCM 入力と矛盾するため。
                // 計画書アーキテクチャ決定 5）。
                aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: Self.aacAudioSettings(matching: audioFormat)
                )
            }
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            } else {
                audioOutput = nil
            }
        }

        // トリム時は映像リーダーの読み込み範囲を制限し、書き出し時に PTS を
        // `trimStart` 分シフトして writer タイムラインを 0 起点に保つ
        // （音声側は別リーダーの timeRange で同じ範囲に制限済み。pump 側で同量シフト）。
        let effectiveDuration: CMTime
        if isTrimming {
            let start = CMTime(seconds: trimStartSec, preferredTimescale: 600)
            let dur = CMTime(seconds: trimEndSec - trimStartSec, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)
            effectiveDuration = dur
        } else {
            effectiveDuration = duration
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.readerSetupFailed }
        if let separateAudioReader {
            guard separateAudioReader.startReading() else {
                reader.cancelReading()
                throw separateAudioReader.error ?? ExportError.readerSetupFailed
            }
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        renderer.reset()

        guard let cache = textureCache else { throw ExportError.textureConversionFailed }

        return try await pump(
            reader: reader,
            audioReader: separateAudioReader,
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
            detectionCaches: detectionCaches,
            mapping: mapping,
            faceEnabled: faceEnabled,
            backgroundEnabled: backgroundEnabled,
            backgroundBlock: backgroundBlock,
            speed: speed,
            trimStartSec: trimStartSec,
            trimEndSec: trimEndSec,
            cache: cache,
            progress: progress
        )
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Pump（ビジーウェイトなしの読み書き）

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count function_body_length
    private func pump(
        reader: AVAssetReader,
        /// トリム時のみ非 nil: 音声をトリム範囲の PCM デコードで読む専用リーダー
        /// （export の doc 参照）。
        audioReader: AVAssetReader?,
        writer: AVAssetWriter,
        outputURL: URL,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        /// パススルーは AVAssetReaderTrackOutput、再エンコードは
        /// AVAssetReaderAudioMixOutput（共通の基底型で受ける）。
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?,
        duration: CMTime,
        videoSize: CGSize,
        selectedFaceTargets: [FaceTarget],
        manualRegions: [ManualRegion],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]],
        mapping: TimelineMapping,
        faceEnabled: Bool,
        backgroundEnabled: Bool,
        backgroundBlock: Float,
        speed: ExportSpeed,
        trimStartSec: Double,
        trimEndSec: Double,
        cache: CVMetalTextureCache,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let detectionInterval = speed.detectionInterval
        detectMaxWidth = speed.detectionMaxWidth
        // 同一 exporter インスタンスの再利用に備え、前回 export の EMA 状態と
        // 選択顔トラッカー（前回の追従位置）を捨てる。
        landmarkSmoother.reset()
        selectedTracker = nil
        resetPerf()

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()

            // 映像：必要になったタイミングでだけコールバックが呼ばれる（Thread.sleep 不要）。
            var frameIndex = 0
            // 直前フレームが属していたクリップ（境界跨ぎの時系列リセット判定用）。
            var previousClipID: UUID?
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
                            previousClipID: &previousClipID,
                            cachedLandmarkSets: &cachedLandmarkSets,
                            cachedBackgroundMask: &cachedBackgroundMask,
                            detectionInterval: detectionInterval,
                            selectedFaceTargets: selectedFaceTargets,
                            manualRegions: manualRegions,
                            detectionCaches: detectionCaches,
                            mapping: mapping,
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

            // 音声：パススルー（トリム無し）はサンプルをそのままコピー。
            // 再エンコード（トリム時・audioReader 非 nil）は timeRange で切られた
            // デコード済み PCM を受け取り、PTS を trimStart 分シフトして writer
            // タイムラインを 0 起点に揃えてから AAC 入力へ渡す（トリム精度は
            // PCM サンプル単位。映像側 shiftSample と同じ 0 起点に一致する）。
            if let audioInput, let audioOutput {
                let audioSourceReader = audioReader ?? reader
                let audioQueue = DispatchQueue(label: "mask-me.export.audio")
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard audioSourceReader.status == .reading,
                              let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        // セグメント境界で samples=0・pts 不定のマーカーバッファが
                        // 届くことがある（マルチクリップ composition の実測）。
                        // writer に渡すと失敗するため読み飛ばす。
                        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                        if trimStartSec > 0.001 {
                            // シフト失敗（タイミング情報が取れない異常バッファ）は
                            // 落とす。未シフトのまま書くと出力タイムラインが壊れる。
                            if let shifted = Self.shiftSample(sample, byMinusSeconds: trimStartSec) {
                                audioInput.append(shifted)
                            }
                        } else {
                            audioInput.append(sample)
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                self.logPerfSummary(totalSeconds: totalSeconds)
                if reader.status == .failed || audioReader?.status == .failed {
                    continuation.resume(throwing:
                        reader.error ?? audioReader?.error ?? ExportError.readerSetupFailed)
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

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count
    private func processVideoSample(
        _ sample: CMSampleBuffer,
        frameIndex: inout Int,
        previousClipID: inout UUID?,
        cachedLandmarkSets: inout [FaceLandmarkSet],
        cachedBackgroundMask: inout MaskBuffer?,
        detectionInterval: Int,
        selectedFaceTargets: [FaceTarget],
        manualRegions: [ManualRegion],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]],
        mapping: TimelineMapping,
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
        // 検出（timestampMs）と写像・キャッシュ検索は合成時刻（rawPts）のままで
        // 一貫させる（シフト済み pts を写像に通すと「シフト＋写像」の二重適用になる。
        // シフトは writer タイムライン専用）。
        let pts: CMTime
        if trimStartSec > 0.001 {
            let shifted = CMTimeGetSeconds(rawPts) - trimStartSec
            pts = CMTime(seconds: max(0, shifted), preferredTimescale: 600)
        } else {
            pts = rawPts
        }
        let timeSec = CMTimeGetSeconds(rawPts)
        let timestampMs = Int(timeSec * 1000)

        // 合成時刻 → 素材位置（クリップ・素材ID・素材内時刻）。
        let location = resolveLocation(mapping, at: timeSec)
        // クリップ境界を跨いだフレームは時系列状態をリセットし、
        // 検出間引きに関係なく検出し直す（前クリップの顔位置を持ち越さない）。
        let crossedClipBoundary = resetAtClipBoundary(
            location: location, previousClipID: &previousClipID,
            cachedLandmarkSets: &cachedLandmarkSets,
            cachedBackgroundMask: &cachedBackgroundMask)

        if frameIndex % detectionInterval == 0 || crossedClipBoundary {
            if faceEnabled {
                // 素材スコープのキャッシュから近傍フレームを探す（なければ新規検出）。
                // 参照キーは写像済みの素材内時刻（丸め・近傍補間は写像の後）。
                let fromCache: [FaceLandmarkSet]
                if let location, let sourceCache = detectionCaches[location.sourceID] {
                    fromCache = lookupCache(sourceCache, at: location.time)
                } else {
                    fromCache = []
                }
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

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count
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
    /// `cache` は素材スコープ（キーは素材内時刻）、`time` は写像済みの素材内時刻。
    private func lookupCache(_ cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        DetectionBridge(interpolates: true).faces(in: cache, at: time)
    }

    /// 合成時刻を素材位置へ解決する。半開区間の外に出た有限時刻（終端フレームの
    /// PTS 揺らぎ）はタイムライン端へクランプして写像する
    /// （`MosaicEditorModel.resolveSourceTime(atComposition:)` と同じ規則）。
    /// 写像が空（クリップなし）のときは nil（キャッシュ参照なし・自前検出）。
    private func resolveLocation(
        _ mapping: TimelineMapping, at compositionTime: Double
    ) -> TimelineMapping.SourceLocation? {
        if let location = mapping.sourceLocation(at: compositionTime) { return location }
        guard compositionTime.isFinite, mapping.totalDuration > 0 else { return nil }
        let clamped = min(max(compositionTime, 0), mapping.totalDuration.nextDown)
        return mapping.sourceLocation(at: clamped)
    }

    /// クリップ境界を跨いだ最初のフレームで時系列状態をリセットする。
    ///
    /// EMA（landmarkSmoother）・保持中の顔位置・背景マスク・選択顔トラッカーは
    /// すべて「直前フレームと映像内容が連続している」前提の状態なので、別クリップに
    /// 入ったら持ち越さない（境界直後のフレームに前クリップの顔位置・マスクがにじむ）。
    /// 単一クリップ・写像なしでは clipID が変わらないため呼んでも何も起きない。
    /// - Returns: 境界を跨いだかどうか（true のフレームは間引きに関係なく再検出する）。
    private func resetAtClipBoundary(
        location: TimelineMapping.SourceLocation?,
        previousClipID: inout UUID?,
        cachedLandmarkSets: inout [FaceLandmarkSet],
        cachedBackgroundMask: inout MaskBuffer?
    ) -> Bool {
        guard location?.clipID != previousClipID else { return false }
        let crossedBoundary = previousClipID != nil
        previousClipID = location?.clipID
        guard crossedBoundary else { return false }
        landmarkSmoother.reset()
        selectedTracker = nil
        cachedLandmarkSets = []
        cachedBackgroundMask = nil
        return true
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

    /// 再エンコード経路（トリム時）のデコード設定（AVAssetReaderAudioMixOutput 用）。
    ///
    /// ≤2ch は nil（ネイティブの非圧縮 LinearPCM デコード）。>2ch（5.1ch 等）は
    /// リーダー段で 16bit ステレオ PCM へダウンミックスする。6ch のままデコードして
    /// 2ch AAC の writer 入力へ渡すと、writer 側のチャンネル変換が -12780 で
    /// 失敗する（6ch .mp4 で実測）ため、変換はミックス機能を持つリーダー側で行う。
    static func reencodeDecodeSettings(matching format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mChannelsPerFrame > 2 else { return nil }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 再エンコード経路（トリム時）の AAC 出力設定。サンプルレートは元素材に合わせ
    /// （取得できなければ 44.1kHz。AAC エンコーダ上限の 48kHz 超は 48kHz へ）、
    /// チャンネル数は**最大 2（ステレオ）にクランプ**する。レート変換・ダウンミックスは
    /// AVAssetWriterInput が行う。
    ///
    /// 3ch 以上（5.1ch 等）を AVChannelLayoutKey 無しで指定すると AVAssetWriterInput の
    /// init が `NSInvalidArgumentException`（ObjC 例外・Swift で catch 不能）を投げて
    /// プロセスごと落ちる（6ch .mov で実測）。レイアウトを正しく引き回すより、
    /// モザイクアプリの書き出しとして十分なステレオへのダウンミックスで固定する。
    static func aacAudioSettings(matching format: CMFormatDescription?) -> [String: Any] {
        var sampleRate = 44_100.0
        var channels = 2
        if let format,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = min(asbd.mSampleRate, 48_000) }
            if asbd.mChannelsPerFrame > 0 { channels = min(Int(asbd.mChannelsPerFrame), 2) }
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000 * channels
        ]
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
    ///
    /// タイミング情報は必要エントリ数を先に問い合わせる: デコード済み PCM バッファは
    /// 数千サンプルでも均一タイミング（必要エントリ 1 個）のため、サンプル数ぶんの
    /// 配列を確保する必要はない。
    static func shiftSample(_ sample: CMSampleBuffer, byMinusSeconds seconds: Double) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { return nil }
        var neededCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &neededCount)
        guard neededCount > 0 else { return nil }
        let count = neededCount
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
// swiftlint:enable type_body_length
#endif
// swiftlint:enable file_length
