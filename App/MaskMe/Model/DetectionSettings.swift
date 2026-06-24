import Foundation

/// 顔検出に関わる全パラメーターを1つにまとめた値型。
/// UserDefaults に JSON でシリアライズして永続化する。
public struct DetectionSettings: Equatable, Codable {
    public var minFaceDetectionConfidence: Float = 0.2
    public var minFacePresenceConfidence: Float = 0.2
    public var minTrackingConfidence: Float = 0.2
    public var numFaces: Int = 5
    public var minSpan: Double = 0.02

    public init(
        minFaceDetectionConfidence: Float = 0.2,
        minFacePresenceConfidence: Float = 0.2,
        minTrackingConfidence: Float = 0.2,
        numFaces: Int = 5,
        minSpan: Double = 0.02
    ) {
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.numFaces = numFaces
        self.minSpan = minSpan
    }

    public struct Preset {
        public let id: String
        public let name: String
        public let settings: DetectionSettings
    }

    public static let presets: [Preset] = [
        Preset(id: "outdoor", name: "屋外", settings: DetectionSettings(
            minFaceDetectionConfidence: 0.4,
            minFacePresenceConfidence: 0.4,
            minTrackingConfidence: 0.4,
            numFaces: 5,
            minSpan: 0.03
        )),
        Preset(id: "standard", name: "標準", settings: DetectionSettings(
            minFaceDetectionConfidence: 0.3,
            minFacePresenceConfidence: 0.3,
            minTrackingConfidence: 0.3,
            numFaces: 5,
            minSpan: 0.025
        )),
        Preset(id: "indoor", name: "室内", settings: DetectionSettings()),
        Preset(id: "dark", name: "暗所", settings: DetectionSettings(
            minFaceDetectionConfidence: 0.1,
            minFacePresenceConfidence: 0.1,
            minTrackingConfidence: 0.1,
            numFaces: 5,
            minSpan: 0.01
        ))
    ]

    /// 現在の値がいずれかのプリセットと一致するプリセット ID。
    public var matchingPresetID: String? {
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
