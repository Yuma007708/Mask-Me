import AVFoundation
import SwiftUI
import MosaicCore

#if canImport(Metal)

/// リアルタイムモザイク撮影画面の状態管理。
/// キャプチャ（`CameraCaptureController`）とフレーム処理（`CameraMosaicPipeline`）を
/// 接続し、UI 状態（プレビュー画像・録画状態・確認待ちメディア）を公開する。
@MainActor
final class CameraViewModel: ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case photo
        case video

        var id: String { rawValue }
        var label: String { self == .photo ? "写真" : "動画" }
    }

    enum PermissionState {
        case checking
        case granted
        case denied
    }

    @Published private(set) var permission: PermissionState = .checking
    @Published private(set) var previewImage: UIImage?
    @Published var mode: CaptureMode = .video
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var position: CameraCaptureController.Position = .back
    @Published var blockSize: Float = 28 {
        didSet { pipeline?.setBlockSize(blockSize) }
    }
    @Published private(set) var detectedFaceCount = 0
    @Published private(set) var unmaskedCount = 0
    /// 確認プレビュー待ちの撮影結果。保存 or 破棄されるまで画面に出す。
    @Published var pendingPhoto: UIImage?
    @Published var pendingVideoURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var isFinishingVideo = false

    /// フロントカメラはプレビューだけ鏡像表示する（保存は非鏡像 = iOS 標準）。
    var isMirrored: Bool { position == .front }

    private let capture = CameraCaptureController()
    private var pipeline: CameraMosaicPipeline?
    private let captureSettings: CaptureSettings
    private let detectionSettings: DetectionSettings
    private var microphoneGranted = false
    private var recordingTimer: Timer?
    private var thermalObserver: NSObjectProtocol?

    init(captureSettings: CaptureSettings, detectionSettings: DetectionSettings) {
        self.captureSettings = captureSettings
        self.detectionSettings = detectionSettings
    }

    // MARK: - ライフサイクル

    func start() async {
        let granted = await CameraCaptureController.requestPermissions()
        microphoneGranted = granted.microphone
        guard granted.camera else {
            permission = .denied
            return
        }
        guard let pipeline = CameraMosaicPipeline(settings: detectionSettings) else {
            errorMessage = "この端末ではカメラ撮影を利用できません（GPU 初期化に失敗）"
            permission = .denied
            return
        }
        self.pipeline = pipeline
        pipeline.setBlockSize(blockSize)
        pipeline.setFrameRate(captureSettings.fps)
        pipeline.onPreviewImage = { [weak self] image in
            Task { @MainActor in self?.previewImage = image }
        }
        pipeline.onFaceCountChange = { [weak self] detected, unmasked in
            Task { @MainActor in
                self?.detectedFaceCount = detected
                self?.unmaskedCount = unmasked
            }
        }
        capture.onVideoFrame = { [weak pipeline] sample in
            pipeline?.process(sampleBuffer: sample)
        }
        capture.onAudioSample = { [weak pipeline] sample in
            pipeline?.processAudio(sampleBuffer: sample)
        }
        observeThermalState()

        capture.start(settings: captureSettings, position: position) { [weak self] ok in
            guard let self else { return }
            self.permission = ok ? .granted : .denied
        }
    }

    func stop() {
        if isRecording {
            // 画面離脱で録画が宙に浮かないよう、進行中の録画は破棄する
            pipeline?.stopRecording()?.cancel()
            stopRecordingTimer()
            isRecording = false
        }
        capture.stop()
        pipeline?.resetTracking()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        // 前後で時系列・被写体が変わるため追跡と選択を破棄する
        pipeline?.resetTracking()
        capture.switchCamera { [weak self] newPosition in
            self?.position = newPosition
        }
    }

    // MARK: - 操作

    /// タップ位置（プレビュー画像内の正規化座標・ミラー補正済み）で顔の ON/OFF を切替。
    /// - Returns: 切替後の状態。顔が無ければ nil。
    @discardableResult
    func toggleFace(atNormalized point: CGPoint) -> Bool? {
        pipeline?.toggleFace(atNormalized: point)
    }

    func shutterTapped() {
        switch mode {
        case .photo:
            pipeline?.capturePhoto { [weak self] image in
                Task { @MainActor in
                    guard let self else { return }
                    if let image {
                        self.pendingPhoto = image
                    } else {
                        self.errorMessage = "写真の撮影に失敗しました"
                    }
                }
            }
        case .video:
            // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
            // swiftlint:disable:next void_function_in_ternary
            isRecording ? finishRecording() : beginRecording()
        }
    }

    private func beginRecording() {
        pipeline?.startRecording(includeAudio: microphoneGranted)
        isRecording = true
        recordingSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingSeconds += 1 }
        }
    }

    private func finishRecording() {
        guard let recorder = pipeline?.stopRecording() else {
            isRecording = false
            stopRecordingTimer()
            return
        }
        isRecording = false
        stopRecordingTimer()
        isFinishingVideo = true
        Task {
            defer { isFinishingVideo = false }
            do {
                pendingVideoURL = try await recorder.finish()
            } catch {
                recorder.cancel()
                errorMessage = "録画の保存準備に失敗しました"
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - 確認プレビューの保存 / 破棄

    func savePendingPhoto() async {
        guard let photo = pendingPhoto else { return }
        do {
            try await PhotosSaver.save(image: photo)
            pendingPhoto = nil
        } catch {
            errorMessage = "写真アプリへの保存に失敗しました（写真へのアクセスを確認してください）"
        }
    }

    func savePendingVideo() async {
        guard let url = pendingVideoURL else { return }
        do {
            try await PhotosSaver.save(videoURL: url)
            try? FileManager.default.removeItem(at: url)
            pendingVideoURL = nil
        } catch {
            errorMessage = "写真アプリへの保存に失敗しました（写真へのアクセスを確認してください）"
        }
    }

    func discardPending() {
        pendingPhoto = nil
        if let url = pendingVideoURL {
            try? FileManager.default.removeItem(at: url)
            pendingVideoURL = nil
        }
    }

    // MARK: - 発熱対策

    /// 端末温度が上がったら検出頻度を落とす（描画・録画は継続）。
    /// 長尺録画（時間無制限）でのコマ落ち・強制終了を避けるための段階的縮退。
    private func observeThermalState() {
        applyThermalPolicy(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.applyThermalPolicy(state) }
        }
    }

    private func applyThermalPolicy(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal, .fair:
            pipeline?.setDetectionInterval(0.1)
        case .serious:
            pipeline?.setDetectionInterval(0.2)
        case .critical:
            pipeline?.setDetectionInterval(0.34)
        @unknown default:
            pipeline?.setDetectionInterval(0.2)
        }
    }
}
#endif
