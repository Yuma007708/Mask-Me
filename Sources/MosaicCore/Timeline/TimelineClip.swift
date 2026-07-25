import Foundation

/// タイムライン上の1クリップ。素材（動画ファイル）の一部分を指す。
///
/// `sourceID` は素材の識別子であり、クリップの識別子ではない。
/// 1つの素材を分割して2つのクリップになった場合、両者は同じ `sourceID` を持つ。
/// 検出キャッシュを素材単位で共有するための設計である。
public struct TimelineClip: Identifiable, Hashable, Sendable, Codable {
    /// 再生倍率の許容範囲。UI のスライダー範囲（0.1x〜10x）と一致させる。
    public static let rateRange: ClosedRange<Double> = 0.1...10.0

    public let id: UUID
    /// 素材の識別子。分割しても変わらない。
    public let sourceID: UUID
    /// 素材内での使用開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での使用終了位置（秒）。
    public var sourceEnd: Double
    /// 元音声の音量の許容範囲（無音〜等倍）。
    public static let volumeRange: ClosedRange<Float> = 0...1

    /// 元音声の音量（0...1）。
    /// init・デコード・直接代入のどれでも `volumeRange` にクランプされる。
    public var originalAudioVolume: Float {
        // didSet 内の再代入はオブザーバを再帰呼び出ししない（rate と同じ手口）。
        didSet { originalAudioVolume = Self.clampedVolume(originalAudioVolume) }
    }
    /// 再生倍率。1.0 が等速、2.0 は倍速（合成尺が半分になる）。
    /// init・直接代入のどちらでも `rateRange` にクランプされる。
    public var rate: Double {
        // didSet 内の再代入はオブザーバを再帰呼び出ししない。
        didSet { rate = Self.clampedRate(rate) }
    }

    public init(id: UUID = UUID(),
                sourceID: UUID,
                sourceStart: Double,
                sourceEnd: Double,
                originalAudioVolume: Float = 1.0,
                rate: Double = 1.0) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        // init 中は didSet が走らないため、rate と同様に明示的にクランプする。
        self.originalAudioVolume = Self.clampedVolume(originalAudioVolume)
        self.rate = Self.clampedRate(rate)
    }

    /// このクリップが合成タイムライン上で占める長さ（秒）。
    /// 素材内の長さを再生倍率で割った値（2x なら半分、0.5x なら倍）。
    public var duration: Double { max(0, sourceEnd - sourceStart) / rate }

    /// 再生倍率を許容範囲（`rateRange`）にクランプする。
    /// NaN は min/max を素通りして mapping 全体を無効化するため、等速（1.0）に落とす。
    public static func clampedRate(_ rate: Double) -> Double {
        rate.isNaN ? 1.0 : min(max(rate, rateRange.lowerBound), rateRange.upperBound)
    }

    /// 元音声の音量を許容範囲（`volumeRange`）にクランプする。
    /// NaN は min/max を素通りしてミキサーのパラメータを壊すため、等倍（1.0）に落とす
    /// （`clampedRate` と同じ理由・同じ倒し方）。
    public static func clampedVolume(_ volume: Float) -> Float {
        volume.isNaN ? 1 : min(max(volume, volumeRange.lowerBound), volumeRange.upperBound)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceStart, sourceEnd, originalAudioVolume, rate
    }

    /// `rate` キーを持たない旧 JSON（rate 導入前に保存された下書き）も
    /// 等速（1.0）としてデコードできるようにする。
    ///
    /// **`init(from:)` は didSet を経由しない**ため、`rate`・`originalAudioVolume` の
    /// どちらも明示的にクランプする（壊れた下書きから範囲外の値が入るのを防ぐ）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.sourceID = try container.decode(UUID.self, forKey: .sourceID)
        self.sourceStart = try container.decode(Double.self, forKey: .sourceStart)
        self.sourceEnd = try container.decode(Double.self, forKey: .sourceEnd)
        self.originalAudioVolume = Self.clampedVolume(
            try container.decode(Float.self, forKey: .originalAudioVolume))
        self.rate = Self.clampedRate(try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0)
    }
}
