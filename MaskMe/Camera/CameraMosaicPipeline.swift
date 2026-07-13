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

    private let renderer: MosaicRenderer
    private let scanner: FaceLandmarking
    private let smoother = LandmarkSmoother()
    private let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    private let detectionQueue = DispatchQueue(label: "com.maskme.camera.detection")

    private let stateLock = NSLock()
    private var selection = CameraFaceSelection()
    /// 直近の検出顔（タップ判定用の全顔）。
    private var lastFaces: [FaceLandmarkSet] = []
    /// 描画対象（オプトアウト除外後）。検出が新しく来たときだけ更新する。
    private var maskedFaces: [FaceLandmarkSet] = []
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
    #if DEBUG
    /// 実機診断用: フレーム寸法が変わったときだけログを出す（縦長=回転適用済みの確認）。
    private var lastLoggedFrameSize = CGSize.zero
    #endif

    /// プレビュー描画の最大幅（MosaicPreviewController と同じ 720px）。
    private static let previewMaxWidth = 720.0
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
    /// - Returns: 切替後の状態（true=ON に戻した / false=OFF にした）、顔なしは nil。
    func toggleFace(atNormalized point: CGPoint) -> Bool? {
        withLock {
            let result = selection.toggle(at: point, in: lastFaces)
            maskedFaces = selection.facesToMask(from: lastFaces)
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
    func resetTracking() {
        detectionQueue.async { [scanner] in scanner.resetLiveTracking() }
        withLock {
            smoother.reset()
            selection.reset()
            lastFaces = []
            maskedFaces = []
            lastNonEmptySeconds = -Double.greatestFiniteMagnitude
        }
    }

    // MARK: - フレーム処理（映像キャプチャキュー）

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        #if DEBUG
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        if frameSize != lastLoggedFrameSize {
            lastLoggedFrameSize = frameSize
            // 縦長（h > w）でなければコネクションの回転が効いていない
            print("[MMCAM] frame=\(Int(frameSize.width))x\(Int(frameSize.height))")
        }
        #endif
        if startSeconds == nil { startSeconds = pts.seconds }
        let t = pts.seconds - (startSeconds ?? 0)

        maybeDetect(pixelBuffer: pixelBuffer, at: t)

        struct FrameJob {
            let faces: [FaceLandmarkSet]
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
            // 描画直前の EMA（プレビュー再生と同じちらつき吸収）
            return FrameJob(faces: smoother.smooth(maskedFaces), block: blockSize,
                            recorder: recorder, photoCompletion: cb)
        }
        renderer.params = MosaicParams(block: job.block)

        if let activeRecorder = job.recorder {
            renderRecordingFrame(
                pixelBuffer: pixelBuffer, pts: pts, faces: job.faces,
                recorder: activeRecorder, photoCompletion: job.photoCompletion, cache: cache)
        } else if let photoCb = job.photoCompletion {
            renderPhotoFrame(pixelBuffer: pixelBuffer, faces: job.faces,
                             completion: photoCb, cache: cache)
        } else {
            renderPreviewOnlyFrame(pixelBuffer: pixelBuffer, faces: job.faces)
        }
    }

    /// マイク音声（音声キャプチャキュー）。録画中のみレコーダーへ流す。
    func processAudio(sampleBuffer: CMSampleBuffer) {
        let activeRecorder = withLock { recorder }
        activeRecorder?.appendAudio(sampleBuffer)
    }

    // MARK: - 検出

    private func maybeDetect(pixelBuffer: CVPixelBuffer, at t: Double) {
        let shouldDetect = withLock { () -> Bool in
            guard !detectionInFlight, t - lastDetectionSeconds >= detectionInterval else {
                return false
            }
            detectionInFlight = true
            lastDetectionSeconds = t
            return true
        }
        guard shouldDetect else { return }
        guard let cg = downscaledCGImage(
            from: pixelBuffer, maxWidth: MosaicEditorModel.liveDetectionTargetWidth) else {
            withLock { detectionInFlight = false }
            return
        }
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scanner.liveLandmarks(in: UIImage(cgImage: cg), atMediaSeconds: t)
            var counts: (detected: Int, unmasked: Int) = (0, 0)
            self.withLock {
                if !result.faces.isEmpty {
                    self.lastFaces = result.faces
                    self.lastNonEmptySeconds = t
                    self.maskedFaces = self.selection.facesToMask(from: result.faces)
                } else {
                    // 検出全滅（フロー橋渡しの上限切れ含む）。録画中は最後の位置を
                    // 保持しつづける（不可逆な焼き込みでの露出を最優先で防ぐ）。
                    // 非録画時だけ、猶予を超えたらプレビューのモザイクを消す。
                    let hold = self.recorder != nil
                        || (t - self.lastNonEmptySeconds) < Self.lostGraceSeconds
                    if !hold {
                        self.lastFaces = []
                        self.maskedFaces = []
                    }
                }
                self.detectionInFlight = false
                counts = (self.lastFaces.count, self.selection.unmaskedCount)
            }
            self.onFaceCountChange?(counts.detected, counts.unmasked)
        }
    }

    // MARK: - レンダリング

    /// 録画中: フル解像度でレコーダーのプールへ焼き込み、同じバッファから
    /// プレビュー（と要求があれば写真）を作る。
    private func renderRecordingFrame(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        faces: [FaceLandmarkSet],
        recorder: CameraRecorder,
        photoCompletion: ((UIImage?) -> Void)?,
        cache: CVMetalTextureCache
    ) {
        guard let inputTexture = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache),
              let pool = recorder.pixelBufferPool,
              let outBuffer = makePixelBuffer(from: pool),
              let outputTexture = MetalTextureUtilities.texture(from: outBuffer, cache: cache)
        else {
            photoCompletion?(nil)
            return
        }
        renderer.render(input: inputTexture, into: outputTexture,
                        landmarkSets: faces, waitForCompletion: true)
        recorder.appendVideo(outBuffer, at: pts)
        publishPreview(from: outBuffer)
        if let photoCompletion {
            let image = downscaledCGImage(from: outBuffer, maxWidth: .infinity)
                .map { UIImage(cgImage: $0) }
            photoCompletion(image)
        }
    }

    /// 写真撮影: フル解像度で新規テクスチャへ描画して UIImage 化する。
    private func renderPhotoFrame(
        pixelBuffer: CVPixelBuffer,
        faces: [FaceLandmarkSet],
        completion: (UIImage?) -> Void,
        cache: CVMetalTextureCache
    ) {
        guard let inputTexture = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache),
              let result = renderer.renderToNewTexture(input: inputTexture, landmarkSets: faces),
              let cg = MetalTextureUtilities.cgImage(from: result.texture) else {
            completion(nil)
            return
        }
        completion(UIImage(cgImage: cg))
        onPreviewImage?(UIImage(cgImage: cg))
    }

    /// 待機中: 720px に縮小してから描画する（プレビュー再生と同じ負荷削減）。
    private func renderPreviewOnlyFrame(pixelBuffer: CVPixelBuffer, faces: [FaceLandmarkSet]) {
        guard let cg = downscaledCGImage(from: pixelBuffer, maxWidth: Self.previewMaxWidth),
              let inputTexture = try? MetalTextureUtilities.texture(
                  from: cg, device: renderer.device),
              let result = renderer.renderToNewTexture(input: inputTexture, landmarkSets: faces),
              let outCG = MetalTextureUtilities.cgImage(from: result.texture) else { return }
        onPreviewImage?(UIImage(cgImage: outCG))
    }

    private func publishPreview(from pixelBuffer: CVPixelBuffer) {
        guard let cg = downscaledCGImage(from: pixelBuffer, maxWidth: Self.previewMaxWidth) else {
            return
        }
        onPreviewImage?(UIImage(cgImage: cg))
    }

    // MARK: - 変換ヘルパー

    private func downscaledCGImage(from pixelBuffer: CVPixelBuffer,
                                   maxWidth: Double) -> CGImage? {
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let scale = min(maxWidth / width, 1.0)
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if scale < 0.99 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
#endif
