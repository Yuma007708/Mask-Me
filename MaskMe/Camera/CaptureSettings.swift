import AVFoundation
import Foundation

/// 撮影解像度。セッションプリセットに対応する。
enum CaptureResolution: String, Codable, CaseIterable, Identifiable {
    case hd720
    case hd1080

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        }
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        }
    }

    /// センサー座標（横長）での出力寸法。ポートレート撮影ではバッファが 90° 回転
    /// されて縦長で届くため、実サイズは常にバッファから取ること。
    var sensorSize: CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        }
    }
}

/// 撮影の画質設定。設定画面で変更し UserDefaults に永続化する。
struct CaptureSettings: Codable, Equatable {
    var resolution: CaptureResolution = .hd1080
    var fps: Int = 30

    static let availableFrameRates = [30, 60]
}

/// `CaptureSettings` を UserDefaults に永続化する ObservableObject。
/// `DetectionSettingsStore` と同じパターン。
final class CaptureSettingsStore: ObservableObject {
    @Published var settings: CaptureSettings {
        didSet { save() }
    }
    private let key = "captureSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CaptureSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 端末カメラの対応状況。設定画面は非対応の組み合わせを表示しない。
enum CaptureCapabilities {
    /// 背面カメラが `resolution` × `fps` に対応しているか。
    /// （フロントは背面より広い対応幅を持つのが普通なので背面基準で絞る）
    static func supports(resolution: CaptureResolution, fps: Int) -> Bool {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else { return false }
        let target = resolution.sensorSize
        return device.formats.contains { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard CGFloat(dims.width) >= target.width,
                  CGFloat(dims.height) >= target.height else { return false }
            return format.videoSupportedFrameRateRanges
                .contains { $0.maxFrameRate >= Double(fps) }
        }
    }

    /// 対応している解像度 × fps の組み合わせ一覧。
    static func supportedCombinations() -> [(resolution: CaptureResolution, fps: Int)] {
        CaptureResolution.allCases.flatMap { res in
            CaptureSettings.availableFrameRates.compactMap { fps in
                supports(resolution: res, fps: fps) ? (res, fps) : nil
            }
        }
    }
}
