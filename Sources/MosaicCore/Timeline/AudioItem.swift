import Foundation

/// BGM（背景音）1 本ぶん（E2）。
///
/// ## アンカーが適用区間と**逆**であること
///
/// `MosaicApplyRange` は素材時刻アンカーで、クリップの分割・並べ替え・トリムに自動追従する。
/// **`AudioItem` は合成時刻アンカーで、クリップの編集に一切追従しない。**
/// BGM は特定のクリップに紐づく効果ではないので、クリップを並べ替えたら BGM まで動く、
/// のはユーザーの期待と食い違うためである。
///
/// この違いは型の使い方に直接効く。`clipID` を持たないので、**クリップ id で照合する
/// 経路へこの型を混ぜてはいけない**（`TimelineApplySpan.anchorClipID` が `.audio` の
/// セグメントで nil なのはこのため）。
///
/// ## クリップを消して合成尺が縮んだとき
///
/// BGM は合成時刻アンカーなので、クリップを消すと末尾からはみ出す。
/// **適用区間の孤児と同じ規則にする**: データは温存し、表示と書き出しで合成尺にクリップする
/// （`TimelineState.effectiveAudioItems(totalDuration:)`）。トリムを戻せば戻る。
///
/// ## 曲どうしは重ならない
///
/// ユーザー決定（2026-08-02）。おかげで composition の BGM トラックは**1 本で足りる**。
/// 重なりの解消は `TimelineState.normalizedAudioItems` が最後の砦として行うが、
/// 本来は編集操作の側がぶつからない位置へクランプして防ぐ（すり抜けさせない）。
public struct AudioItem: Equatable, Sendable, Identifiable {
    /// これを下回る長さの BGM は作らない・残さない。
    ///
    /// 0 長の区間は composition の `insertTimeRange` で無音の失敗になり、帯としても
    /// 掴めない（幅 0）。編集操作のクランプと正規化の両方がこの値を下限にする。
    public static let minimumDuration: Double = 0.1

    public let id: UUID
    /// 音源素材の id（`TimelineSource.kind == .audio` のエントリを指す）。
    public var sourceID: UUID
    /// 曲のどこから鳴らすか（素材時刻・秒）。
    public var sourceStart: Double
    /// 曲のどこまで鳴らすか（素材時刻・秒）。
    public var sourceEnd: Double
    /// 合成タイムライン上の開始位置（秒）。
    public var compositionStart: Double
    /// 音量（0...1）。元動画の音量（`TimelineClip.originalAudioVolume`）とは独立に持つ。
    public var volume: Float
    /// フェードイン時間（秒。0 = フェードなし。E2-2）。
    ///
    /// **常に `duration / 2` 以下へクランプされた値を保持する**（`clampedFade` が唯一の
    /// 丸め実装）。トリム・尺のクリップで `duration` が変わるたびに `clampFades()` を
    /// 呼び直し、フェードイン＋アウトが重ならないようにする。
    public var fadeInDuration: Double
    /// フェードアウト時間（秒。0 = フェードなし。E2-2）。`fadeInDuration` と同じ規則。
    public var fadeOutDuration: Double

    public init(id: UUID = UUID(), sourceID: UUID,
                sourceStart: Double, sourceEnd: Double,
                compositionStart: Double, volume: Float = 1,
                fadeInDuration: Double = 0, fadeOutDuration: Double = 0) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.compositionStart = compositionStart
        self.volume = volume
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        clampFades()
    }

    /// 鳴っている長さ（秒）。**BGM に倍速は無い**ので素材尺と合成尺は常に一致する
    /// （`TimelineClip` と違い `rate` を持たない）。
    public var duration: Double { sourceEnd - sourceStart }

    /// 合成タイムライン上の終端（秒・半開区間の右端）。
    public var compositionEnd: Double { compositionStart + duration }

    /// フェード時間 1 本ぶんの丸め（純関数・テスト対象）。
    ///
    /// **上限は「その BGM の再生尺の半分」。** イン・アウトそれぞれ独立にこの上限へ
    /// クランプすることで、両方を上限いっぱいに使っても合計が `duration` を超えず
    /// （＝重ならず）に済む。非有限・0 以下は 0（フェードなし）に落とす。
    /// **`duration` 側の非有限も弾くこと。** Swift の `min`/`max` は NaN との比較が
    /// 常に false になるため、`max(.nan, 0)` は `.nan`、続く `min(value, .nan)` は
    /// `value` をそのまま返す ＝ **丸めが素通しになる**。
    /// いまの公開編集 API からは尺が非有限になる経路は塞がれているが、ここは
    /// 「壊れた値が来ても安全側へ倒す」最後の砦なので、素通しにしておかない。
    public static func clampedFade(_ value: Double, duration: Double) -> Double {
        guard value.isFinite, value > 0, duration.isFinite else { return 0 }
        let cap = max(duration, 0) / 2
        return min(value, cap)
    }

    /// `fadeInDuration` / `fadeOutDuration` を現在の `duration` へ丸め直す。
    ///
    /// **`duration` が変わり得る操作（トリム・`clipped(toTotalDuration:)`）の後に
    /// 必ず呼ぶこと。** 呼び忘れると、尺が縮んだ後もフェードが古い（大きすぎる）
    /// 値のまま残り、`AudioMixFactory` がフェードイン終了より前にフェードアウトを
    /// 始める（＝範囲の逆転）を起こし得る。
    public mutating func clampFades() {
        fadeInDuration = Self.clampedFade(fadeInDuration, duration: duration)
        fadeOutDuration = Self.clampedFade(fadeOutDuration, duration: duration)
    }

    /// 合成尺 `totalDuration` で切ったときに実際に鳴る部分。1 秒も鳴らないなら nil。
    ///
    /// **書き出しと帯表示は必ずこれを通すこと。** 生の `compositionStart`/`compositionEnd` を
    /// そのまま使うと、クリップを消して縮んだタイムラインの外へ BGM を挿入しにいく。
    public func clipped(toTotalDuration totalDuration: Double) -> AudioItem? {
        guard totalDuration.isFinite, totalDuration > 0,
              compositionStart.isFinite, duration.isFinite else { return nil }
        let start = max(compositionStart, 0)
        let end = min(compositionEnd, totalDuration)
        guard end - start >= Self.minimumDuration else { return nil }
        var result = self
        result.compositionStart = start
        result.sourceStart = sourceStart + (start - compositionStart)
        result.sourceEnd = result.sourceStart + (end - start)
        // 末尾を切ったことで duration が縮み得る（`clampFades` の doc 参照）。
        result.clampFades()
        return result
    }
}

// MARK: - Codable（後方互換）

extension AudioItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceStart, sourceEnd, compositionStart, volume
        case fadeInDuration, fadeOutDuration
    }

    /// フェード（E2-2 で追加）の無い旧下書きは「フェードなし（0 秒）」として復元する。
    ///
    /// `TimelineStateCodable` の `audioItems` 追加時と同じ流儀
    /// （無いキーは機能追加前の意味＝オフを表す）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        sourceStart = try container.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try container.decode(Double.self, forKey: .sourceEnd)
        compositionStart = try container.decode(Double.self, forKey: .compositionStart)
        volume = try container.decode(Float.self, forKey: .volume)
        fadeInDuration = try container.decodeIfPresent(Double.self, forKey: .fadeInDuration) ?? 0
        fadeOutDuration = try container.decodeIfPresent(Double.self, forKey: .fadeOutDuration) ?? 0
        clampFades()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encode(sourceEnd, forKey: .sourceEnd)
        try container.encode(compositionStart, forKey: .compositionStart)
        try container.encode(volume, forKey: .volume)
        try container.encode(fadeInDuration, forKey: .fadeInDuration)
        try container.encode(fadeOutDuration, forKey: .fadeOutDuration)
    }
}
