import Foundation

/// 補助顔検出器のバックエンド表現。
///
/// 内部表現としては `DetectionSettings` 内の 2 つの Bool（useFaceDetector / useYunet）が
/// ground truth で、この enum は「テスト・既存 UI からの呼び出し」「Codable 旧フォーマット互換」用に
/// 残してある。getter は 2 Bool の組み合わせから最も近い enum を返し、setter は 2 Bool に展開する。
///
/// 注: かつて存在した Apple Vision backend (`.vision`) は完全削除した。Vision は実機で
/// torso・首・肩を顔として拾い体モザイクの原因になった上、Simulator では 0 検出のため
/// シミュレータで挙動検証ができない（＝実機との乖離を自動テストで捕まえられない）。
public enum FaceDetectorBackend: String, Codable {
    /// 補助検出なし（MediaPipe 単独）。
    case off
    /// MediaPipe Face Detector (BlazeFace) のみ。Simulator でも実機でも動作。
    case faceDetector
    /// YuNet (OpenCV) のみ。Core ML で動作、シミュレータ・実機どちらでも動く。
    case yunet
    /// Face Detector + YuNet 並走 union。最高検出率。
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

    /// MediaPipe Face Detector (BlazeFace) を補助検出器として使う。
    /// デフォルト ON: Vision 削除後の検出率をシミュレータ検証可能な2系統で支える。
    public var useFaceDetector: Bool = true
    /// YuNet (Core ML) を補助検出器として使う。デフォルト ON（同上）。
    public var useYunet: Bool = true

    /// 旧 API 互換。2 Bool の組み合わせを最も近い enum で返し、setter で 2 Bool に展開する。
    public var faceDetectorBackend: FaceDetectorBackend {
        get {
            switch (useFaceDetector, useYunet) {
            case (false, false): return .off
            case (true,  false): return .faceDetector
            case (false, true ): return .yunet
            case (true,  true ): return .all
            }
        }
        set {
            switch newValue {
            case .off:          useFaceDetector = false; useYunet = false
            case .faceDetector: useFaceDetector = true;  useYunet = false
            case .yunet:        useFaceDetector = false; useYunet = true
            case .all:          useFaceDetector = true;  useYunet = true
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
        self.faceDetectorBackend = faceDetectorBackend  // 2 Bool に展開される
    }

    /// 新 API: 2 Bool を直接指定。
    public init(
        minFaceDetectionConfidence: Float,
        minFacePresenceConfidence: Float,
        minTrackingConfidence: Float,
        numFaces: Int,
        minSpan: Double,
        useFaceDetector: Bool,
        useYunet: Bool
    ) {
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.numFaces = numFaces
        self.minSpan = minSpan
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
        case useFaceDetector
        case useYunet
        // 旧キー: 補助検出器バックエンドを enum で保存していた時代の値。
        case faceDetectorBackend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.minFaceDetectionConfidence = try c.decodeIfPresent(Float.self, forKey: .minFaceDetectionConfidence) ?? 0.2
        self.minFacePresenceConfidence  = try c.decodeIfPresent(Float.self, forKey: .minFacePresenceConfidence) ?? 0.2
        self.minTrackingConfidence      = try c.decodeIfPresent(Float.self, forKey: .minTrackingConfidence) ?? 0.2
        self.numFaces                   = try c.decodeIfPresent(Int.self, forKey: .numFaces) ?? 5
        self.minSpan                    = try c.decodeIfPresent(Double.self, forKey: .minSpan) ?? 0.02

        // 新フォーマット (2 Bool)。旧フォーマットは enum を raw String として読み、
        // 削除済みの "vision" を含む未知値はデフォルト（両方 ON）に落とす。
        if let fd = try c.decodeIfPresent(Bool.self, forKey: .useFaceDetector) {
            self.useFaceDetector = fd
            self.useYunet = try c.decodeIfPresent(Bool.self, forKey: .useYunet) ?? true
        } else if let raw = try? c.decodeIfPresent(String.self, forKey: .faceDetectorBackend),
                  let backend = FaceDetectorBackend(rawValue: raw) {
            self.faceDetectorBackend = backend  // setter が 2 Bool に展開
        } else {
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
    /// Apple Vision 削除 + FaceDetector/YuNet デフォルト ON への一括切り替えマイグレーション。
    /// 一度だけ既存設定を上書きする（以後ユーザーが OFF にした選択は尊重される）。
    private let visionRemovalMigrationKey = "detectionSettings.migration.visionRemoved.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(DetectionSettings.self, from: data) {
            var s = decoded
            if !UserDefaults.standard.bool(forKey: visionRemovalMigrationKey) {
                s.useFaceDetector = true
                s.useYunet = true
                UserDefaults.standard.set(true, forKey: visionRemovalMigrationKey)
            }
            settings = s
        } else {
            UserDefaults.standard.set(true, forKey: visionRemovalMigrationKey)
            settings = DetectionSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
