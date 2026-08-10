import Foundation

/// 素材 1 本ぶんの音声波形（表示用に縮約したピーク列）。
///
/// **素材時刻でアンカーする**（検出キャッシュ・モザイク適用区間と同じ理屈）。
/// 合成時刻で持つと、トリム・並べ替え・速度変更のたびに全部作り直しになり、
/// しかも編集途中の 1 フレームだけ波形が別の場所を指す。素材時刻なら、
/// クリップがどう動いても「その素材のこの瞬間の音量」は不変である。
///
/// 値は 0...1 に正規化済み（`peak` は絶対値の最大）。**音圧の絶対値ではない**ので、
/// 別素材どうしの波形の高さを比べても意味はない（1 本の中の相対的な大小だけ読める）。
public struct AudioWaveform: Equatable, Sendable {
    /// 1 秒あたりのピーク数。**表示解像度の上限**でもある。
    ///
    /// 100 は「ズーム最大（既定の目盛りが 0.5 秒）でも棒が足りる」ことから決めた。
    /// 上げるとメモリと解析時間が線形に増える（10 分の素材で 60,000 個）。
    public static let peaksPerSecond: Double = 100

    /// 0...1 に正規化したピーク列（先頭が素材時刻 0）。
    public let peaks: [Float]
    /// この波形が覆う素材尺（秒）。`peaks.count / peaksPerSecond` と一致するとは限らない
    /// （末尾の端数、解析の打ち切り）。
    public let sourceDuration: Double

    public init(peaks: [Float], sourceDuration: Double) {
        self.peaks = peaks
        self.sourceDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
    }

    /// 音声が無い素材（写真クリップ・無音動画）。
    public static let silent = AudioWaveform(peaks: [], sourceDuration: 0)

    public var isEmpty: Bool { peaks.isEmpty }

    /// 素材時刻のピーク（範囲外は 0）。
    public func peak(atSourceTime time: Double) -> Float {
        guard time.isFinite, time >= 0, !peaks.isEmpty else { return 0 }
        let index = Int(time * Self.peaksPerSecond)
        guard peaks.indices.contains(index) else { return 0 }
        return peaks[index]
    }
}

/// 波形を「帯に描く棒の高さ」へ落とす純ロジック。
public enum AudioWaveformLayout {

    /// 帯の幅ぶんの棒の高さ（0...1）を作る。
    ///
    /// - Parameters:
    ///   - waveform: 素材の波形。
    ///   - sourceStart: 帯の左端が指す**素材時刻**。
    ///   - rate: クリップの速度。2 倍なら同じ px 幅に 2 倍の素材時間が入る。
    ///   - barCount: 棒の本数（帯の幅 ÷ 棒の間隔）。
    ///   - secondsPerBar: 棒 1 本が受け持つ**合成時刻**の長さ。
    ///
    /// **1 本の棒には、その棒が跨ぐ素材区間の最大値を入れる**（平均ではない）。
    /// 平均にすると、拡大率を下げたときに波形がのっぺり潰れて「音が入っているか」
    /// すら読めなくなる。ピークの見た目が残る方が波形の役に立つ。
    public static func bars(waveform: AudioWaveform,
                            sourceStart: Double,
                            rate: Double,
                            barCount: Int,
                            secondsPerBar: Double) -> [Float] {
        guard barCount > 0, !waveform.isEmpty,
              secondsPerBar.isFinite, secondsPerBar > 0,
              rate.isFinite, rate > 0, sourceStart.isFinite else { return [] }
        let sourceSecondsPerBar = secondsPerBar * rate
        return (0..<barCount).map { index in
            let start = sourceStart + Double(index) * sourceSecondsPerBar
            return maximumPeak(waveform: waveform, from: start, length: sourceSecondsPerBar)
        }
    }

    /// 素材区間 `[from, from + length)` のピークの最大値。
    ///
    /// 区間がピーク 1 個より短い（＝拡大しすぎ）ときも、必ず 1 個は読む。
    /// 0 個読んで 0 を返すと、拡大するほど波形が消えていく。
    static func maximumPeak(waveform: AudioWaveform, from: Double, length: Double) -> Float {
        guard !waveform.isEmpty else { return 0 }
        let startIndex = max(0, Int(from * AudioWaveform.peaksPerSecond))
        let rawCount = Int((length * AudioWaveform.peaksPerSecond).rounded())
        let endIndex = min(waveform.peaks.count, startIndex + max(1, rawCount))
        guard startIndex < endIndex else { return 0 }
        return waveform.peaks[startIndex..<endIndex].max() ?? 0
    }
}
