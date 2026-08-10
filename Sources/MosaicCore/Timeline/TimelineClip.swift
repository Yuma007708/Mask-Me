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

    /// クリップに掛ける向き（90 度単位の回転 + 左右反転）。既定は無変換。
    ///
    /// **これは映像だけの設定ではない。** 顔ランドマークと矩形モザイクの正規化座標も
    /// 同じ向きで写さなければモザイクが素材からずれて顔が素通しになる。写像の唯一の
    /// 経路は `TimelineRenderLayout`（`orientations`）で、映像側の
    /// `VideoCompositionFactory.fitTransform` と同じ `ClipOrientation` から作られる。
    public var orientation: ClipOrientation

    /// クリップに掛ける色調補正（明るさ・コントラスト・彩度・暖かみ）。既定は無補正。
    ///
    /// クランプは `ColorGrade` 自身の 1 箇所（`didSet` / `init` / `init(from:)` の
    /// 3 経路）に閉じている。`TimelineClip` 側でこの値をさらにクランプする必要はない
    /// （`orientation` と同じく、値型自身が不変条件を守る設計）。
    public var colorGrade: ColorGrade

    /// クリップに掛ける拡大縮小・位置（変形）。既定は無変形。
    ///
    /// **これは AVFoundation 合成段（`VideoCompositionFactory.make`）で、Metal の
    /// モザイク段より前に効く。** `AspectFit.placement(of:in:)` が作る配置矩形へ
    /// この変形を 1 回だけ掛け、その結果を映像側（`fitTransform`）と顔座標の写像
    /// （`layoutRects` → `TimelineRenderLayout`）の両方へ渡すことで、映像とモザイクが
    /// 構造的に一致する（`orientation` と同じ「共有した写像から作る」設計）。
    public var transform: ClipTransform

    public init(id: UUID = UUID(),
                sourceID: UUID,
                sourceStart: Double,
                sourceEnd: Double,
                originalAudioVolume: Float = 1.0,
                rate: Double = 1.0,
                orientation: ClipOrientation = .identity,
                colorGrade: ColorGrade = .identity,
                transform: ClipTransform = .identity) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        // init 中は didSet が走らないため、rate と同様に明示的にクランプする。
        self.originalAudioVolume = Self.clampedVolume(originalAudioVolume)
        self.rate = Self.clampedRate(rate)
        self.orientation = orientation
        self.colorGrade = colorGrade
        self.transform = transform
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
        case id, sourceID, sourceStart, sourceEnd, originalAudioVolume, rate, orientation, colorGrade
        case transform
    }

    /// `rate` キーを持たない旧 JSON（rate 導入前に保存された下書き）も
    /// 等速（1.0）としてデコードできるようにする。`orientation` も同じ規約で、
    /// キーが無い旧下書きは**回転なし・反転なし**（`ClipOrientation.identity`）になる。
    /// `colorGrade`（v7 で追加）も同じ規約で、キーが無い v6 以前の下書きは
    /// **無補正**（`ColorGrade.identity`）になる。`transform`（v7 に合流）も同じ規約で、
    /// キーが無い下書きは**無変形**（`ClipTransform.identity`）になる。
    ///
    /// **`init(from:)` は didSet を経由しない**ため、`rate`・`originalAudioVolume` の
    /// どちらも明示的にクランプする（壊れた下書きから範囲外の値が入るのを防ぐ）。
    /// `colorGrade` 自身のクランプは `ColorGrade.init(from:)` が別途行う。
    ///
    /// **`transform` キーは `try?` で包んで decode する。** `ClipTransform.init(from:)`
    /// 自身は成分ごとの型不一致を握り潰すが、`"transform"` の値そのものが JSON オブジェクト
    /// でない（例: 文字列・数値）場合は `decoder.container(keyedBy:)` の時点で throw する。
    /// これを伝播させると `TimelineClip` ごとデコードが失敗し下書きが丸ごと消えるため、
    /// ここでも二重に握り潰して `.identity` へ倒す。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.sourceID = try container.decode(UUID.self, forKey: .sourceID)
        self.sourceStart = try container.decode(Double.self, forKey: .sourceStart)
        self.sourceEnd = try container.decode(Double.self, forKey: .sourceEnd)
        self.originalAudioVolume = Self.clampedVolume(
            try container.decode(Float.self, forKey: .originalAudioVolume))
        self.rate = Self.clampedRate(try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0)
        self.orientation = try container.decodeIfPresent(
            ClipOrientation.self, forKey: .orientation) ?? .identity
        self.colorGrade = try container.decodeIfPresent(
            ColorGrade.self, forKey: .colorGrade) ?? .identity
        self.transform = (try? container.decodeIfPresent(
            ClipTransform.self, forKey: .transform)) ?? .identity
    }
}
