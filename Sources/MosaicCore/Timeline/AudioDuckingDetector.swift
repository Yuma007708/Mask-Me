import Foundation

/// クリップの音声波形（`AudioWaveform`）から「声が鳴っている」区間を検出する純関数。
///
/// **固定の絶対しきい値は使わない。** `AudioWaveform` は 0...1 に正規化済みだが、
/// 「別素材どうしの高さを比べても意味はない」（型 doc 参照）ため、しきい値は
/// **そのクリップが使う素材区間内のピーク分布**から相対的に決める。
public enum AudioDuckingDetector {
    /// 開き（有音とみなす）しきい値の下限。ほぼ無音の素材でも過検出しないための床。
    private static let openThresholdFloor: Float = 0.06
    /// 開きしきい値 = `max(openThresholdFloor, p90 * openThresholdRatio)`。
    private static let openThresholdRatio: Float = 0.35
    /// 閉じ（無音側に戻る）しきい値 = `open * closeThresholdRatio`。開きより低くしてヒステリシスを作る。
    private static let closeThresholdRatio: Float = 0.6
    /// これ未満の立ち上がりは声とみなさない（秒）。
    public static let minimumVoiceDuration: Double = 0.20
    /// 閉じしきい値を割っても、この秒数は「まだ有音」として保持する（秒）。
    public static let holdDuration: Double = 0.25
    /// この間隔以下の谷は 1 本の区間へ統合する（秒）。
    public static let mergeGap: Double = 0.35

    /// クリップが使う素材区間 `[clip.sourceStart, clip.sourceEnd)`（波形が覆う範囲にクランプ）
    /// の中で「声が鳴っている」と判定した区間を返す。
    ///
    /// - `waveform` が空、またはクリップの使用範囲が波形の覆う範囲と交差しなければ `[]`。
    public static func voiceRanges(waveform: AudioWaveform, clip: TimelineClip) -> [ClipDuckRange] {
        guard clip.sourceStart.isFinite, clip.sourceEnd.isFinite,
              clip.sourceStart < clip.sourceEnd, !waveform.isEmpty else { return [] }
        let windowStart = max(0, clip.sourceStart)
        let windowEnd = min(clip.sourceEnd, waveform.sourceDuration)
        guard windowStart < windowEnd else { return [] }

        let dt = 1 / AudioWaveform.peaksPerSecond
        var samples: [(time: Double, peak: Float)] = []
        var time = windowStart
        while time < windowEnd {
            samples.append((time, waveform.peak(atSourceTime: time)))
            time += dt
        }
        guard !samples.isEmpty else { return [] }

        let (open, close) = thresholds(samples: samples)
        let raw = rawIntervals(samples: samples, windowEnd: windowEnd, open: open, close: close)
        let voiced = raw.filter { $0.end - $0.start >= minimumVoiceDuration }
        let mergedIntervals = mergingNearbyIntervals(voiced)

        let ranges = mergedIntervals.compactMap { interval -> ClipDuckRange? in
            let start = max(windowStart, interval.start)
            let end = min(windowEnd, interval.end)
            guard start.isFinite, end.isFinite, start < end else { return nil }
            return ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: start, sourceEnd: end)
        }
        return ClipDuckGate.merged(ranges)
    }

    /// クリップ区間内のピーク分布から `(open, close)` しきい値を決める（相対しきい値の唯一の実体）。
    private static func thresholds(samples: [(time: Double, peak: Float)]) -> (open: Float, close: Float) {
        let sortedPeaks = samples.map(\.peak).sorted()
        let p90Index = min(sortedPeaks.count - 1, Int(Double(sortedPeaks.count) * 0.9))
        let p90 = sortedPeaks[p90Index]
        let open = max(openThresholdFloor, p90 * openThresholdRatio)
        return (open, open * closeThresholdRatio)
    }

    /// ヒステリシス + 保持（hold）付きの状態機械で、有音区間の候補を切り出す。
    ///
    /// `open` を跨いだ瞬間に開始し、`close` を `holdDuration` 秒連続して下回ったら終了する
    /// （閾値付近の振動でチャタらないようにするための唯一の実体）。
    private static func rawIntervals(samples: [(time: Double, peak: Float)], windowEnd: Double,
                                     open: Float, close: Float) -> [(start: Double, end: Double)] {
        var result: [(start: Double, end: Double)] = []
        var active = false
        var activeStart: Double = 0
        var lastAboveClose: Double = 0
        let dt = 1 / AudioWaveform.peaksPerSecond

        for sample in samples {
            if !active {
                guard sample.peak >= open else { continue }
                active = true
                activeStart = sample.time
                lastAboveClose = sample.time
                continue
            }
            if sample.peak >= close { lastAboveClose = sample.time }
            if sample.time - lastAboveClose >= holdDuration {
                result.append((activeStart, min(windowEnd, lastAboveClose + dt)))
                active = false
            }
        }
        if active { result.append((activeStart, windowEnd)) }
        return result
    }

    /// 谷が `mergeGap` 以下の区間どうしを 1 本へ統合する。
    private static func mergingNearbyIntervals(
        _ intervals: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [(start: Double, end: Double)] = []
        for interval in sorted {
            if let last = result.last, interval.start - last.end <= mergeGap {
                result[result.count - 1].end = max(last.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
