import Foundation

/// 補助顔検出器のバックエンド選択。
/// MediaPipe FaceLandmarker（478 メッシュ）の取りこぼしを補う bbox 検出を、誰に任せるかを表す。
/// 取得した bbox は `MediaPipeFaceLandmarkerAdapter.augmentWithBBoxDetector` 内で ROI として
/// MP IMG モードに再投入され、最終的に MP のメッシュとして出力される（モザイク品質は MP と同等）。
public enum FaceDetectorBackend: String, Codable {
    /// 補助検出なし（MediaPipe 単独）。
    case off
    /// Apple Vision のみ。実機専用（Simulator では 0 検出）。
    case vision
    /// MediaPipe Face Detector (BlazeFace) のみ。Simulator でも実機でも動作。
    case faceDetector
    /// Vision + Face Detector 並走 union。最高検出率だが処理時間も最大。
    case both
}

/// 顔検出に関わる全パラメーターを1つにまとめた値型。
/// UserDefaults に JSON でシリアライズして永続化する。
public struct DetectionSettings: Equatable, Codable {
    public var minFaceDetectionConfidence: Float = 0.2
    public var minFacePresenceConfidence: Float = 0.2
    public var minTrackingConfidence: Float = 0.2
    public var numFaces: Int = 5
    public var minSpan: Double = 0.02
    /// 補助検出器のバックエンド。詳細は `FaceDetectorBackend` 参照。
    public var faceDetectorBackend: FaceDetectorBackend = .vision

    public init(
        minFaceDetectionConfidence: Float = 0.2,
        minFacePresenceConfidence: Float = 0.2,
        minTrackingConfidence: Float = 0.2,
        numFaces: Int = 5,
        minSpan: Double = 0.02,
        faceDetectorBackend: FaceDetectorBackend = .vision
    ) {
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.numFaces = numFaces
        self.minSpan = minSpan
        self.faceDetectorBackend = faceDetectorBackend
    }

    // MARK: - Codable (with migration)

    private enum CodingKeys: String, CodingKey {
        case minFaceDetectionConfidence
        case minFacePresenceConfidence
        case minTrackingConfidence
        case numFaces
        case minSpan
        case faceDetectorBackend
        // 旧キー：useAppleVision: Bool。新キー faceDetectorBackend が未保存のときだけ参照する。
        case useAppleVision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.minFaceDetectionConfidence = try c.decodeIfPresent(Float.self, forKey: .minFaceDetectionConfidence) ?? 0.2
        self.minFacePresenceConfidence  = try c.decodeIfPresent(Float.self, forKey: .minFacePresenceConfidence) ?? 0.2
        self.minTrackingConfidence      = try c.decodeIfPresent(Float.self, forKey: .minTrackingConfidence) ?? 0.2
        self.numFaces                   = try c.decodeIfPresent(Int.self, forKey: .numFaces) ?? 5
        self.minSpan                    = try c.decodeIfPresent(Double.self, forKey: .minSpan) ?? 0.02
        if let backend = try c.decodeIfPresent(FaceDetectorBackend.self, forKey: .faceDetectorBackend) {
            self.faceDetectorBackend = backend
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .useAppleVision) {
            // useAppleVision: true → .vision, false → .off にマイグレーション
            self.faceDetectorBackend = legacy ? .vision : .off
        } else {
            self.faceDetectorBackend = .vision
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minFaceDetectionConfidence, forKey: .minFaceDetectionConfidence)
        try c.encode(minFacePresenceConfidence,  forKey: .minFacePresenceConfidence)
        try c.encode(minTrackingConfidence,      forKey: .minTrackingConfidence)
        try c.encode(numFaces,                   forKey: .numFaces)
        try c.encode(minSpan,                    forKey: .minSpan)
        try c.encode(faceDetectorBackend,        forKey: .faceDetectorBackend)
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
