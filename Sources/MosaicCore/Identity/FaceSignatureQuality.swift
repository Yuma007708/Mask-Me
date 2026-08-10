import CoreGraphics
import Foundation

/// 「この顔から作った署名を信じてよいか」の足切り。
///
/// **なぜ要るか**: 実動画で測ると、同一人物のフレーム同士でも
/// 遮蔽 0.2030 / 暗所 0.3642 まで類似度が落ちる（閾値 0.363 を割る）。
/// このまま署名で判定させると「同一人物を別人と判定する」ため、
/// **信用できない顔は署名判定に掛けない**。落ちた先の扱いは `FaceIdentityPolicy`。
///
/// 判定は**ランドマークだけ**で行う（画像を持ち込むとコアが描画層に依存する）。
/// 明るさ・ブレのような画像側の指標は、必要になった時点でアプリ層が
/// `imageQualityOverride` として渡せるようにしてある。
public struct FaceSignatureQuality: Sendable, Equatable {
    /// 顔の画素幅。SFace の入力が 112×112 なので、これを大きく下回る顔は
    /// 引き伸ばされた潰れた画像になり、署名が当てにならない。
    /// **正規化幅ではなく画素幅で見る**（同じ 0.08 でも 720p と 4K で実体が違う）。
    public static let minimumFacePixelWidth: CGFloat = 80

    /// 正面度。鼻先が両目の中点からどれだけ横にずれているかを、目の間隔で割った比。
    /// 正準顔（`frontalUV`）では目の中心が u=0.2965 と u=0.7035、鼻先が u=0.5 なので
    /// ちょうど 0 になる。横を向くほど大きくなる。
    ///
    /// **暫定値**: 実素材で較正するまでの仮置き（S1c の計測で確定させる）。
    public static let maximumNoseSkew: CGFloat = 0.35

    /// 検出器が出した信頼度の下限。
    public static let minimumConfidence: Float = 0.5

    /// 計測値（閾値と比較する前の生の数字。ログと較正のために公開する）。
    public let facePixelWidth: CGFloat
    public let noseSkew: CGFloat
    public let confidence: Float

    public init(facePixelWidth: CGFloat, noseSkew: CGFloat, confidence: Float) {
        self.facePixelWidth = facePixelWidth
        self.noseSkew = noseSkew
        self.confidence = confidence
    }

    /// 署名を信じてよいか。
    public var isTrustworthy: Bool {
        facePixelWidth >= Self.minimumFacePixelWidth
            && noseSkew <= Self.maximumNoseSkew
            && confidence >= Self.minimumConfidence
    }

    /// メッシュから計測する。5 点が取れない（部分メッシュ・矩形由来）顔は nil。
    public static func measure(_ set: FaceLandmarkSet, imageSize: CGSize) -> FaceSignatureQuality? {
        guard let points = FaceAlignmentPoints.extract(from: set) else { return nil }
        let leftEye = points[0], rightEye = points[1], nose = points[2]
        let eyeSpan = abs(rightEye.x - leftEye.x)
        guard eyeSpan > 1e-6 else { return nil }
        let eyeMidX = (leftEye.x + rightEye.x) / 2
        return FaceSignatureQuality(
            facePixelWidth: set.boundingBox.width * imageSize.width,
            noseSkew: abs(nose.x - eyeMidX) / eyeSpan,
            confidence: set.confidence)
    }
}
