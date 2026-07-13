import AVFoundation
import CoreMedia
import UIKit

/// アプリ内カメラのキャプチャ層。AVCaptureSession（映像 + 音声）を管理し、
/// フレームをクロージャで上位（`CameraViewModel`）へ流す。モザイク描画・録画・
/// 選択は上位層の責務で、このクラスはデバイス制御だけを持つ。
///
/// 向きの規約（重要）:
/// - 映像コネクションはポートレート固定に回転させる（アプリ自体が Portrait 固定）。
///   これで「検出に渡すフレーム」「描画するフレーム」「録画に書くフレーム」の
///   3 系統すべてが同じ縦長バッファになり、向きズレでモザイクが顔から外れる
///   事故を構造的に防ぐ。
/// - ミラーは常に無効（フロントでも非鏡像バッファ）。フロントカメラの鏡像は
///   iOS 標準に合わせて **表示レイヤーだけ** で反転する（保存は非鏡像）。
final class CameraCaptureController: NSObject {
    enum Position {
        case front
        case back

        var avPosition: AVCaptureDevice.Position {
            self == .front ? .front : .back
        }
    }

    /// 映像フレーム（BGRA・ポートレート回転済み）。キャプチャ専用キューで呼ばれる。
    var onVideoFrame: ((CMSampleBuffer) -> Void)?
    /// マイク音声サンプル。キャプチャ専用キューで呼ばれる。
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.maskme.camera.session")
    private let videoQueue = DispatchQueue(label: "com.maskme.camera.video")
    private let audioQueue = DispatchQueue(label: "com.maskme.camera.audio")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private(set) var position: Position = .back
    private var settings = CaptureSettings()

    // MARK: - 権限

    /// カメラは必須、マイクは任意（拒否されたら無音で撮影を続ける）。
    static func requestPermissions() async -> (camera: Bool, microphone: Bool) {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return (camera, microphone)
    }

    // MARK: - セッション制御

    /// セッションを構成して開始する。完了はメインキューへ通知。
    func start(settings: CaptureSettings,
               position: Position = .back,
               completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [self] in
            self.settings = settings
            let ok = configureSession(position: position)
            if ok {
                // コネクションの回転・ミラー設定はコミット後に必ず再適用する
                // （入力差し替えで再生成されたコネクションには構成中の設定が乗らない。
                // 実機報告: フロント切替後にプレビューが 90 度ずれる）。
                configureVideoConnection()
                applyFrameRate()
                session.startRunning()
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// フロント/バックを切り替える。完了後の実位置をメインキューへ通知。
    func switchCamera(completion: @escaping (Position) -> Void) {
        sessionQueue.async { [self] in
            let newPosition: Position = position == .back ? .front : .back
            session.beginConfiguration()
            if let current = videoDeviceInput {
                session.removeInput(current)
            }
            if attachVideoInput(position: newPosition) {
                position = newPosition
            } else if let fallback = videoDeviceInput, session.canAddInput(fallback) {
                // 新デバイスが取れなければ元に戻す
                session.addInput(fallback)
            }
            session.commitConfiguration()
            // 入力差し替えで再生成されたコネクションはデフォルト向き（センサー横長）に
            // 戻るため、回転・ミラーは **コミット後** に適用する。コミット前に設定すると
            // フロント切替後のフレームが 90 度ずれる（実機報告）。
            configureVideoConnection()
            applyFrameRate()
            DispatchQueue.main.async { [position] in completion(position) }
        }
    }

    // MARK: - 構成

    private func configureSession(position: Position) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = session.canSetSessionPreset(settings.resolution.preset)
            ? settings.resolution.preset
            : .high

        guard attachVideoInput(position: position) else { return false }
        self.position = position

        // マイクは任意: デバイス取得や追加に失敗しても映像のみで続行する。
        if session.inputs.allSatisfy({ ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) != true }),
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        if !session.outputs.contains(videoOutput) {
            // BGRA + Metal 互換はモザイク描画の必須条件（VideoMosaicExporter と同じ理由:
            // 指定を欠くとテクスチャ変換が失敗し、無加工フレームが保存されうる）。
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            // 描画・録画が遅れたフレームは捨てる（ライブでは最新フレーム優先）
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { return false }
            session.addOutput(videoOutput)
        }

        if !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }

        configureVideoConnection()
        applyFrameRate()
        return true
    }

    @discardableResult
    private func attachVideoInput(position: Position) -> Bool {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position.avPosition
        ), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoDeviceInput = input
        return true
    }

    /// 映像コネクションをポートレート回転・非ミラーに揃える（クラスコメントの規約）。
    /// 入力を差し替えるとコネクションが再生成されて設定が既定に戻るため、
    /// **commitConfiguration の後** に呼ぶこと。
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else {
            #if DEBUG
            print("[MMCAM] video connection なし（回転を適用できない）")
            #endif
            return
        }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        #if DEBUG
        if #available(iOS 17.0, *) {
            print("[MMCAM] position=\(position) rotation=\(connection.videoRotationAngle) "
                  + "mirrored=\(connection.isVideoMirrored)")
        }
        #endif
    }

    private func applyFrameRate() {
        guard let device = videoDeviceInput?.device else { return }
        let fps = Double(settings.fps)
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { $0.minFrameRate...$0.maxFrameRate ~= fps }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }
}

// MARK: - 出力デリゲート

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            onVideoFrame?(sampleBuffer)
        } else if output === audioOutput {
            onAudioSample?(sampleBuffer)
        }
    }
}
