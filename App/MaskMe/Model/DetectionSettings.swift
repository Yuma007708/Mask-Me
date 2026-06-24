import Foundation

/// 顔検出に関わる全パラメーターを1つにまとめた値型。
/// UserDefaults に JSON でシリアライズして永続化する。
struct DetectionSettings: Equatable, Codable {
    var minFaceDetectionConfidence: Float = 0.2
    var minFacePresenceConfidence: Float  = 0.2
    var minTrackingConfidence: Float      = 0.2
    var numFaces: Int                     = 5
    var minSpan: Double                   = 0.02
    var eyeWidthRatioMin: Double          = 0.10
    var eyeWidthRatioMax: Double          = 0.95

    static let presets: [(id: String, name: String, settings: DetectionSettings)] = [
        ("outdoor", "屋外", DetectionSettings(
            minFaceDetectionConfidence: 0.4,
            minFacePresenceConfidence:  0.4,
            minTrackingConfidence:      0.4,
            numFaces: 5,
            minSpan: 0.03,
            eyeWidthRatioMin: 0.12,
            eyeWidthRatioMax: 0.92
        )),
        ("standard", "標準", DetectionSettings(
            minFaceDetectionConfidence: 0.3,
            minFacePresenceConfidence:  0.3,
            minTrackingConfidence:      0.3,
            numFaces: 5,
            minSpan: 0.025,
            eyeWidthRatioMin: 0.10,
            eyeWidthRatioMax: 0.95
        )),
        ("indoor", "室内", DetectionSettings()),   // デフォルト値 = 室内向け
        ("dark", "暗所", DetectionSettings(
            minFaceDetectionConfidence: 0.1,
            minFacePresenceConfidence:  0.1,
            minTrackingConfidence:      0.1,
            numFaces: 5,
            minSpan: 0.01,
            eyeWidthRatioMin: 0.08,
            eyeWidthRatioMax: 0.97
        )),
    ]

    /// 現在の値がいずれかのプリセットと一致するプリセット ID。
    var matchingPresetID: String? {
        Self.presets.first(where: { $0.settings == self })?.id
    }
}

/// UserDefaults に `DetectionSettings` を永続化する ObservableObject。
final class DetectionSettingsStore: ObservableObject {
    @Published var settings: DetectionSettings {
        didSet { save() }
    }
    private let key = "detectionSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(DetectionSettings.self, from: data) {
            settings = decoded
        } else {
            settings = DetectionSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
