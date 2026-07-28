import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// リアルタイム撮影のフレーム処理層。カメラの生フレームを受け取り、
/// ライブ顔検出（`liveLandmarks`: ROI 再検出 + フロー橋渡し）→ オプトアウト選択
/// フィルタ → Metal モザイク描画、をフレームごとに行い、プレビュー画像と
/// 録画用の焼き込み済みバッファを生成する。
///
/// 「プレビューに映った = 保存される」の一致保証: 録画中はレコーダー用に描画した
/// 焼き込み済みバッファ **そのもの** からプレビュー画像を作る。プレビューと保存で
/// 別々にレンダリングしないため、見えたものと違う映像が保存されることがない。
///
/// スレッド規約: `process(sampleBuffer:)` は映像キャプチャキューから直列に呼ばれる。
/// 検出は専用キューで非同期に回し（フレーム処理を塞がない）、共有状態は
/// `stateLock` で守る。設定系プロパティはメインスレッドから `stateLock` 経由で更新。
final class CameraMosaicPipeline {
    /// プレビュー画像（呼び出しスレッドはフレーム処理キュー。UI 側で main へ hop する）。
    var onPreviewImage: ((UIImage) -> Void)?
    /// 検出顔数と OFF 数の変化通知（UI バッジ用）。フレーム処理キューから呼ばれる。
    var onFaceCountChange: ((_ detected: Int, _ unmasked: Int) -> Void)?

    let renderer: MosaicRenderer
    private let scanner: FaceLandmarking
    let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    private let detectionQueue = DispatchQueue(label: "com.maskme.camera.detection")

    /// 毎フレーム前進層（stateLock 内でのみ触る）。検出(10Hz)間のフレームを
    /// フロー変換で前進させ、モザイクを顔に貼り付かせ続ける。
    private let propagator = LiveFacePropagator()
    /// フロートラッカー束（videoQueue 専有。ロック不要）。
    private let advancer = CameraFlowAdvancer()

    private let stateLock = NSLock()
    private var selection = CameraFaceSelection()
    /// 描画対象の顔添字（`propagator.faces` 基準）。検出合流・タップ時に更新。
    private var maskedIdx: [Int] = []
    /// 検出合流後、次フレームでフロートラッカーを蒔き直すフラグ。
    private var pendingReseed = false
    private var detectionInFlight = false
    private var lastDetectionSeconds = -Double.greatestFiniteMagnitude
    private var lastNonEmptySeconds = -Double.greatestFiniteMagnitude
    private var recorder: CameraRecorder?
    private var pendingRecordingIncludesAudio: Bool?
    private var photoCompletion: ((UIImage?) -> Void)?
    private var blockSize: Float = 28
    /// 検出間隔（秒）。発熱時にビューモデルが引き上げる。
    private var detectionInterval = 0.1

    private var startSeconds: Double?
    private var configuredFPS = 30
    /// 横長バッファを縦長へ回転する自前フォールバック用のバッファプール。
    /// コネクションの `videoRotationAngle` はカメラ/フォーマットによって非対応が
    /// ありうる（実機報告: フロントだけ 90 度ずれる）ため、デバイス差に依存しない
    /// 最終防衛としてパイプライン側でも向きを保証する。
    var portraitPool: CVPixelBufferPool?
    var portraitPoolSize = CGSize.zero
    #if DEBUG
    /// 実機診断用: フレーム寸法が変わったときだけログを出す（縦長=回転適用済みの確認）。
    private var lastLoggedFrameSize = CGSize.zero
    #endif

    /// プレビュー描画の最大幅。粗さスライダーの基準幅
    /// （`MosaicRenderer.referenceFrameWidth`）に合わせる。`MosaicPreviewController`
    /// の縮小幅と同じ由来で、素の定数を書くと片方だけ変えたときに
    /// プレビューとカメラで粗さが食い違う。
    static let previewMaxWidth = Double(MosaicRenderer.referenceFrameWidth)
    /// 非録画時、検出全滅がこの秒数続いたらモザイクを消す。録画中は消さない
    /// （焼き込みは不可逆のため、最後の位置に置きつづける安全側挙動）。
    private static let lostGraceSeconds = 0.5

    init?(settings: DetectionSettings) {
        guard let renderer = try? MosaicRenderer() else { return nil }
        self.renderer = renderer
        self.scanner = makeFaceLandmarker(forVideo: false, settings: settings)
        self.ciContext = CIContext(
            mtlDevice: renderer.device, options: [.useSoftwareRenderer: false])
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache)
    }

    // MARK: - メインスレッドから呼ぶ制御

    func setBlockSize(_ value: Float) {
        withLock { blockSize = value }
    }

    func setDetectionInterval(_ value: Double) {
        withLock { detectionInterval = value }
    }

    func setFrameRate(_ fps: Int) {
        withLock { configuredFPS = fps }
    }

    /// タップ位置（正規化・非ミラー座標）の顔の ON/OFF を切り替える。
    /// 判定対象は前進済みの現フレーム推定なので、動いている顔にも正しく当たる。
    /// - Returns: 切替後の状態（true=ON に戻した / false=OFF にした）、顔なしは nil。
    func toggleFace(atNormalized point: CGPoint) -> Bool? {
        withLock {
            let faces = propagator.faces
            let result = selection.toggle(at: point, in: faces)
            maskedIdx = selection.maskedIndices(from: faces)
            return result
        }
    }

    /// 次の映像フレームから録画を開始する（レコーダーはフレーム実寸で遅延生成）。
    func startRecording(includeAudio: Bool) {
        withLock { pendingRecordingIncludesAudio = includeAudio }
    }

    /// 録画を止め、確定処理用のレコーダーを返す（呼び出し側が finish/cancel する）。
    func stopRecording() -> CameraRecorder? {
        withLock {
            let r = recorder
            recorder = nil
            pendingRecordingIncludesAudio = nil
            return r
        }
    }

    /// 次のフレームを写真として焼き込み撮影する。
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        withLock { photoCompletion = completion }
    }

    /// カメラ切替・画面終了時に追跡と選択を初期化する（時系列が変わるため）。
    /// フロートラッカー（videoQueue 専有）はここでは触らず、pendingReseed で
    /// 次フレームに空の蒔き直しをさせて破棄する。
    func resetTracking() {
        detectionQueue.async { [scanner] in scanner.resetLiveTracking() }
        withLock {
            selection.reset()
            propagator.reset()
            maskedIdx = []
            pendingReseed = true
            lastNonEmptySeconds = -Double.greatestFiniteMagnitude
        }
    }

    // MARK: - フレーム処理（映像キャプチャキュー）

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next cyclomatic_complexity
    func process(sampleBuffer: CMSampleBuffer) {
        guard let rawBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }
        // コネクションの回転が効かなかったフレームはここで縦長に正規化する
        let pixelBuffer = normalizedPortraitBuffer(rawBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        #if DEBUG
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        if frameSize != lastLoggedFrameSize {
            lastLoggedFrameSize = frameSize
            let rotated = rawBuffer !== pixelBuffer
            print("[MMCAM] frame=\(Int(frameSize.width))x\(Int(frameSize.height)) "
                  + "rotationFallback=\(rotated)")
        }
        #endif
        if startSeconds == nil { startSeconds = pts.seconds }
        let t = pts.seconds - (startSeconds ?? 0)

        // 検出スロットル判定を先に行い、縮小画像（検出とフローで共有）は
        // どちらかが必要なフレームだけ生成する。
        let shouldDetect = claimDetectionSlot(at: t)
        let needsFlow = withLock { !propagator.isEmpty || pendingReseed }
        var scaledCG: CGImage?
        if shouldDetect || needsFlow {
            scaledCG = downscaledCGImage(
                from: pixelBuffer, maxWidth: MosaicEditorModel.liveDetectionTargetWidth)
        }

        // 毎フレームのフロー前進（検出発行より先: begin 時点 = このフレーム）
        if needsFlow, let cg = scaledCG {
            advanceFlow(cg: cg)
        }
        if shouldDetect {
            if let cg = scaledCG {
                dispatchDetection(cg: cg, at: t)
            } else {
                withLock { detectionInFlight = false }
            }
        }

        struct FrameJob {
            let faces: [FaceLandmarkSet]
            let options: [MosaicRenderer.FaceRenderOption]
            let block: Float
            let recorder: CameraRecorder?
            let photoCompletion: ((UIImage?) -> Void)?
        }
        let job = withLock { () -> FrameJob in
            // 録画開始要求はフレーム実寸が要るのでここで具現化する
            if let includeAudio = pendingRecordingIncludesAudio, recorder == nil {
                let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                  height: CVPixelBufferGetHeight(pixelBuffer))
                recorder = try? CameraRecorder(
                    size: size, fps: configuredFPS, includeAudio: includeAudio)
                pendingRecordingIncludesAudio = nil
            }
            let cb = photoCompletion
            photoCompletion = nil
            // 前進済みの現フレーム推定から描画対象（オプトアウト除外後）を抜き出し、
            // 速度・外挿状態に応じたマスクマージンを顔ごとに算出する
            let all = propagator.faces
            var faces: [FaceLandmarkSet] = []
            var options: [MosaicRenderer.FaceRenderOption] = []
            for index in maskedIdx where all.indices.contains(index) {
                faces.append(all[index])
                options.append(renderOption(forTrackAt: index))
            }
            return FrameJob(faces: faces, options: options, block: blockSize,
                            recorder: recorder, photoCompletion: cb)
        }
        renderer.params = MosaicParams(block: job.block)

        if let activeRecorder = job.recorder {
            renderRecordingFrame(
                pixelBuffer: pixelBuffer, pts: pts, faces: job.faces, options: job.options,
                recorder: activeRecorder, photoCompletion: job.photoCompletion, cache: cache)
        } else if let photoCb = job.photoCompletion {
            renderPhotoFrame(pixelBuffer: pixelBuffer, faces: job.faces, options: job.options,
                             completion: photoCb, cache: cache)
        } else {
            renderPreviewOnlyFrame(pixelBuffer: pixelBuffer, faces: job.faces,
                                   options: job.options)
        }
    }

    /// トラックの速度・外挿状態から顔ごとの描画オプションを作る（stateLock 内で呼ぶ）。
    /// - 速い顔ほど凸包マージンを広げる（1 フレーム分の残差ラグを吸収）。
    /// - フロー外挿中は不確かさに応じてさらに漸増し、余白ゼロのメッシュ経路は
    ///   余白のある凸包マスクへ降格する（原本レス設計の露出防止を最優先）。
    private func renderOption(forTrackAt index: Int) -> MosaicRenderer.FaceRenderOption {
        let extrapolating = propagator.extrapolationFrames(at: index)
        let dilation = Self.baseDilation
            + min(0.06, propagator.speed(at: index) * 1.5)
            + min(0.06, CGFloat(extrapolating) * 0.015)
        return MosaicRenderer.FaceRenderOption(
            dilation: dilation, forceConvexHull: extrapolating > 0)
    }

    /// 静止時の凸包マージン（FaceMaskBuilder の既定と同じ顔幅 4%）。
    private static let baseDilation: CGFloat = 0.04

    /// マイク音声（音声キャプチャキュー）。録画中のみレコーダーへ流す。
    func processAudio(sampleBuffer: CMSampleBuffer) {
        let activeRecorder = withLock { recorder }
        activeRecorder?.appendAudio(sampleBuffer)
    }

    // MARK: - フロー前進（毎フレーム・videoQueue）

    /// 全トラックを現フレームへ前進させ、検出合流直後なら補正済み bbox で
    /// フロートラッカーを蒔き直す。`cg` は検出と同じ縮小画像
    /// （observations の座標系はこの縮小 px。propagator へ同じサイズを渡す）。
    private func advanceFlow(cg: CGImage) {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        // cg は既に縮小済みなので MMGrayFrame では再縮小しない（長辺そのまま）
        guard let frame = MMGrayFrame(
            image: UIImage(cgImage: cg),
            maxLongSide: Double(max(cg.width, cg.height))) else { return }
        let observations = advancer.advance(frame: frame)
        let size = CGSize(width: cg.width, height: cg.height)
        let reseedBoxes = withLock { () -> [CGRect]? in
            propagator.advance(observations: observations, imageSize: size)
            guard pendingReseed else { return nil }
            pendingReseed = false
            return propagator.boundingBoxes
        }
        if let reseedBoxes {
            advancer.reseed(frame: frame, faceBoxes: reseedBoxes)
        }
        #if DEBUG
        logFlowCost(CFAbsoluteTimeGetCurrent() - started)
        #endif
    }

    #if DEBUG
    private var flowCostSum = 0.0
    private var flowCostCount = 0
    /// 実機診断用: フロー前進の平均所要時間を約 5 秒ごとに出す。
    private func logFlowCost(_ elapsed: Double) {
        flowCostSum += elapsed
        flowCostCount += 1
        if flowCostCount >= 150 {
            let avgMs = flowCostSum / Double(flowCostCount) * 1000
            print(String(format: "[MMCAM] flowAdvance avg=%.2fms faces=%d",
                         avgMs, withLock { propagator.count }))
            flowCostSum = 0
            flowCostCount = 0
        }
    }
    #endif

    // MARK: - 検出（10Hz・detectionQueue）

    /// 検出スロットルの判定と in-flight ガードの獲得。
    private func claimDetectionSlot(at t: Double) -> Bool {
        withLock {
            guard !detectionInFlight, t - lastDetectionSeconds >= detectionInterval else {
                return false
            }
            detectionInFlight = true
            lastDetectionSeconds = t
            return true
        }
    }

    private func dispatchDetection(cg: CGImage, at t: Double) {
        // 以降のフレーム間変換が累積され、完了時に「古い検出結果」を現フレームへ補正する
        let token = withLock { propagator.beginDetection() }
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scanner.liveLandmarks(in: UIImage(cgImage: cg), atMediaSeconds: t)
            let detectionSize = CGSize(width: cg.width, height: cg.height)
            var counts: (detected: Int, unmasked: Int) = (0, 0)
            self.withLock {
                if !result.faces.isEmpty {
                    self.propagator.completeDetection(
                        token: token, faces: result.faces, imageSize: detectionSize)
                    self.lastNonEmptySeconds = t
                    self.maskedIdx = self.selection.maskedIndices(from: self.propagator.faces)
                    self.pendingReseed = true
                } else {
                    // 検出全滅（フロー橋渡しの上限切れ含む）。録画中は最後の位置を
                    // 保持しつづける（不可逆な焼き込みでの露出を最優先で防ぐ）。
                    // 非録画時だけ、猶予を超えたらプレビューのモザイクを消す。
                    let hold = self.recorder != nil
                        || (t - self.lastNonEmptySeconds) < Self.lostGraceSeconds
                    if !hold {
                        self.propagator.reset()
                        self.maskedIdx = []
                        self.pendingReseed = true   // 次フレームで空の蒔き直し
                    }
                }
                self.detectionInFlight = false
                counts = (self.propagator.count, self.selection.unmaskedCount)
            }
            self.onFaceCountChange?(counts.detected, counts.unmasked)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
#endif
