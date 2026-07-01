import Foundation

/// 補助顔検出器のバックエンド表現。
///
/// 内部表現としては `DetectionSettings` 内の 3 つの Bool（useVision / useFaceDetector / useYunet）が
/// ground truth で、この enum は「テスト・既存 UI からの呼び出し」「Codable 旧フォーマット互換」用に
/// 残してある。getter は 3 Bool の組み合わせから最も近い enum を返し、setter は 3 Bool に展開する。
public enum FaceDetectorBackend: String, Codable {
    /// 補助検出なし（MediaPipe 単独）。
    case off
    /// Apple Vision のみ。実機専用（Simulator では 0 検出）。
    case vision
    /// MediaPipe Face Detector (BlazeFace) のみ。Simulator でも実機でも動作。
    case faceDetector
    /// YuNet (OpenCV) のみ。Core ML で動作、シミュレータ・実機どちらでも動く。
    case yunet
    /// Vision + Face Detector + YuNet 並走 union。最高検出率だが処理時間も最大。
    case all
}

/// 顔検出に関わる全パラメーターを1つにまとめた値型。
/// UserDefaults に JSON でシリアライズして永続化する。
public struct DetectionSettings: Equatable, Codable {
    public var minFaceDetectionConfidence: Float = 0.2
    public var minFacePresenceConfidence: Float = 0.2
    public var minTrackingConfidence: Float = 0.2
    public var numFaces: Int = 5
    public var minSpan: Double = 0.02

    /// Apple Vision を補助検出器として使う。実機専用（Simulator では 0 検出）。
    /// 設定 UI には出さず、常時 true がデフォルト。
    public var useVision: Bool = true
    /// MediaPipe Face Detector (BlazeFace) を補助検出器として使う。
    public var useFaceDetector: Bool = true
    /// YuNet (Core ML) を補助検出器として使う。
    public var useYunet: Bool = true

    /// 旧 API 互換。3 Bool の組み合わせを最も近い enum で返し、setter で 3 Bool に展開する。
    public var faceDetectorBackend: FaceDetectorBackend {
        get {
            switch (useVision, useFaceDetector, useYunet) {
            case (false, false, false): return .off
            case (true,  false, false): return .vision
            case (false, true,  false): return .faceDetector
            case (false, false, true ): return .yunet
            case (true,  true,  true ): return .all
            // 混在ケース（V+F, V+Y, F+Y）は enum で名前を持たないので all 扱い
            default: return .all
            }
        }
        set {
            switch newValue {
            case .off:          useVision = false; useFaceDetector = false; useYunet = false
            case .vision:       useVision = true;  useFaceDetector = false; useYunet = false
            case .faceDetector: useVision = false; useFaceDetector = true;  useYunet = false
            case .yunet:        useVision = false; useFaceDetector = false; useYunet = true
            case .all:          useVision = true;  useFaceDetector = true;  useYunet = true
            }
        }
    }

    public init(
        minFaceDetectionConfidence: Float = 0.2,
        minFacePresenceConfidence: Float = 0.2,
        minTrackingConfidence: Float = 0.2,
        numFaces: Int = 5,
        minSpan: Double = 0.02,
        faceDetectorBackend: FaceDetectorBackend = .all
    ) {
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.numFaces = numFaces
        self.minSpan = minSpan
        self.faceDetectorBackend = faceDetectorBackend  // 3 Bool に展開される
    }

    /// 新 API: 3 Bool を直接指定。
    public init(
        minFaceDetectionConfidence: Float,
        minFacePresenceConfidence: Float,
        minTrackingConfidence: Float,
        numFaces: Int,
        minSpan: Double,
        useVision: Bool,
        useFaceDetector: Bool,
        useYunet: Bool
    ) {
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.numFaces = numFaces
        self.minSpan = minSpan
        self.useVision = useVision
        self.useFaceDetector = useFaceDetector
        self.useYunet = useYunet
    }

    // MARK: - Codable (with migration)

    private enum CodingKeys: String, CodingKey {
        case minFaceDetectionConfidence
        case minFacePresenceConfidence
        case minTrackingConfidence
        case numFaces
        case minSpan
        case useVision
        case useFaceDetector
        case useYunet
        // 旧キー：補助検出器バックエンドを enum で保存していた時代の値。
        case faceDetectorBackend
        // さらに古い旧キー：useAppleVision: Bool。
        case useAppleVision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.minFaceDetectionConfidence = try c.decodeIfPresent(Float.self, forKey: .minFaceDetectionConfidence) ?? 0.2
        self.minFacePresenceConfidence  = try c.decodeIfPresent(Float.self, forKey: .minFacePresenceConfidence) ?? 0.2
        self.minTrackingConfidence      = try c.decodeIfPresent(Float.self, forKey: .minTrackingConfidence) ?? 0.2
        self.numFaces                   = try c.decodeIfPresent(Int.self, forKey: .numFaces) ?? 5
        self.minSpan                    = try c.decodeIfPresent(Double.self, forKey: .minSpan) ?? 0.02

        // 新フォーマット (3 Bool) → 旧フォーマット (enum) → 最古フォーマット (useAppleVision Bool) の順で試す。
        if let v = try c.decodeIfPresent(Bool.self, forKey: .useVision) {
            self.useVision = v
            self.useFaceDetector = try c.decodeIfPresent(Bool.self, forKey: .useFaceDetector) ?? true
            self.useYunet = try c.decodeIfPresent(Bool.self, forKey: .useYunet) ?? true
        } else if let backend = try c.decodeIfPresent(FaceDetectorBackend.self, forKey: .faceDetectorBackend) {
            self.faceDetectorBackend = backend  // setter が 3 Bool に展開
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .useAppleVision) {
            self.faceDetectorBackend = legacy ? .vision : .off
        } else {
            // 何も無ければ全部 true（Vision + FaceDetector + YuNet 並走）。
            // 旧デフォルト .vision よりも検出率が高い側に倒す。
            self.useVision = true
            self.useFaceDetector = true
            self.useYunet = true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minFaceDetectionConfidence, forKey: .minFaceDetectionConfidence)
        try c.encode(minFacePresenceConfidence,  forKey: .minFacePresenceConfidence)
        try c.encode(minTrackingConfidence,      forKey: .minTrackingConfidence)
        try c.encode(numFaces,                   forKey: .numFaces)
        try c.encode(minSpan,                    forKey: .minSpan)
        try c.encode(useVision,                  forKey: .useVision)
        try c.encode(useFaceDetector,            forKey: .useFaceDetector)
        try c.encode(useYunet,                   forKey: .useYunet)
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
