import Foundation

/// 顔の見た目から作った人物署名（SFace の埋め込み）。
///
/// 位置ではなく**見た目**で人物を同定するための値型。アプリ層の埋め込み器
/// （OpenCV/SFace）が生の `[Float]` を作り、ここへ包んでからコアへ渡す。
/// `MosaicCore` は MediaPipe にも OpenCV にも依存しないという規約を守るため、
/// **この型は生成方法を一切知らない**（`FaceLandmarkSet` と同じ関係）。
///
/// 比較はコサイン類似度で行う。SFace の埋め込みは L2 正規化されていない生ベクトルで
/// 返ることがあるため、`init` で必ず正規化してから保持する（正規化済みなら内積が
/// そのままコサイン類似度になり、比較のたびにノルムを計算しなくて済む）。
public struct FaceSignature: Sendable, Equatable, Codable {
    /// L2 正規化済みの埋め込み。
    public let values: [Float]

    /// SFace の埋め込み次元。この長さでないベクトルは受け付けない
    /// （モデル差し替えで無言に精度が壊れるのを防ぐ）。
    public static let dimension = 128

    /// - Returns: 長さが `dimension` でない、または零ベクトル（正規化できない）なら nil。
    public init?(rawValues: [Float]) {
        guard rawValues.count == Self.dimension else { return nil }
        var norm: Float = 0
        for v in rawValues { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 1e-6, norm.isFinite else { return nil }
        self.values = rawValues.map { $0 / norm }
    }

    /// 正規化済みと分かっているベクトルから直接作る（復元・テスト用）。
    init(normalizedValues: [Float]) {
        self.values = normalizedValues
    }

    /// コサイン類似度（-1〜1、大きいほど同一人物らしい）。
    /// 双方 L2 正規化済みなので内積がそのままコサインになる。
    public func similarity(to other: FaceSignature) -> Float {
        guard values.count == other.values.count else { return -1 }
        var dot: Float = 0
        for i in values.indices { dot += values[i] * other.values[i] }
        return dot
    }

    /// 複数の署名の平均（人物の代表署名を作るため）。
    /// 平均後に再正規化するので、要素数が違う・空・零和のときは nil。
    public static func mean(of signatures: [FaceSignature]) -> FaceSignature? {
        guard let first = signatures.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for signature in signatures {
            guard signature.values.count == sum.count else { return nil }
            for i in sum.indices { sum[i] += signature.values[i] }
        }
        return FaceSignature(rawValues: sum)
    }
}

/// 同一人物と判定する閾値。
///
/// 実測（`Fixtures/faces` の 2 人 14 枚・91 ペア、SFace fp32）:
/// - 同一人物ペア 51 件の**最小**類似度 0.8384
/// - 別人ペア 40 件の**最大**類似度 0.2344
///
/// 間に 0.6 の空白があり、SFace 公式閾値 0.363 で両方向とも誤り 0 件だった。
/// ただしこれはスタジオ撮影の正面ポートレートという易しい条件での数字である。
///
/// 実動画（同一人物のフレーム同士なので本来は全て高いはず）:
/// - 動きブレ 0.7730（余裕あり）
/// - 暗所     0.3642（閾値とほぼ同値）
/// - 遮蔽     0.2030（**閾値を割る＝同一人物を別人と誤る**）
///
/// つまり**閾値だけでは足りない**。暗所・遮蔽の顔は署名そのものが信用できないので、
/// `FaceSignatureQuality` で先に足切りし、信用できない顔は署名判定に掛けずに
/// 位置追跡へ、それも決まらなければ「隠す」へ落とす（`FaceIdentityPolicy`）。
public enum FaceIdentityThreshold {
    /// SFace 公式のコサイン閾値。上記の実測でこの値の妥当性を確認している。
    public static let match: Float = 0.363

    /// 「別人と言い切れる」下限。これを下回れば自信をもって別人とする。
    /// `match` との間（0.25〜0.363）は判断保留＝安全側（隠す）に倒す帯。
    /// 実測の別人ペア最大 0.2344 のすぐ上に置いてある。
    public static let distinct: Float = 0.25
}
