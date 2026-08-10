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
public struct AudioItem: Codable, Equatable, Sendable, Identifiable {
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

    public init(id: UUID = UUID(), sourceID: UUID,
                sourceStart: Double, sourceEnd: Double,
                compositionStart: Double, volume: Float = 1) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.compositionStart = compositionStart
        self.volume = volume
    }

    /// 鳴っている長さ（秒）。**BGM に倍速は無い**ので素材尺と合成尺は常に一致する
    /// （`TimelineClip` と違い `rate` を持たない）。
    public var duration: Double { sourceEnd - sourceStart }

    /// 合成タイムライン上の終端（秒・半開区間の右端）。
    public var compositionEnd: Double { compositionStart + duration }

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
        return result
    }
}
