import Foundation

/// 合成タイムライン上の時刻と、素材内の時刻を相互変換する。
///
/// この変換を一箇所に閉じ込めることで、既存の時刻ベース API
/// （`lookupFaces(at:)` など）の呼び出し側の構造を変えずに済む。
public struct TimelineMapping: Sendable {
    /// 合成時刻がどのクリップのどの素材時刻に対応するかを表す。
    public struct SourceLocation: Equatable, Sendable {
        public let clipID: UUID
        public let sourceID: UUID
        /// 素材内での時刻（秒）。
        public let time: Double

        public init(clipID: UUID, sourceID: UUID, time: Double) {
            self.clipID = clipID
            self.sourceID = sourceID
            self.time = time
        }
    }

    /// クリップと、その合成タイムライン上の開始位置。
    private struct Entry {
        let clip: TimelineClip
        let start: Double
    }

    private let entries: [Entry]
    public let totalDuration: Double

    public init(clips: [TimelineClip]) {
        var acc = 0.0
        var built: [Entry] = []
        built.reserveCapacity(clips.count)
        for clip in clips {
            built.append(Entry(clip: clip, start: acc))
            acc += clip.duration
        }
        self.entries = built
        self.totalDuration = acc
    }

    /// 合成時刻 → 素材内の位置。範囲外なら nil。
    ///
    /// クリップ境界は次のクリップに属する（半開区間 [start, end)）。
    /// 合成時刻内オフセットに再生倍率を掛けて素材時刻へ写す
    /// （2x のクリップでは合成 1 秒が素材 2 秒に対応する）。
    ///
    /// rate ≠ 1 では乗算の丸め上がりで計算値が `sourceEnd`（半開区間の外）に
    /// 達し得るため、返却値を [sourceStart, sourceEnd.nextDown] にクランプして
    /// 「区間内の合成時刻は必ず区間内の素材時刻に写る」契約を守る。
    public func sourceLocation(at compositionTime: Double) -> SourceLocation? {
        guard compositionTime >= 0, compositionTime < totalDuration else { return nil }
        for entry in entries {
            let end = entry.start + entry.clip.duration
            if compositionTime < end {
                let offset = compositionTime - entry.start
                let raw = entry.clip.sourceStart + offset * entry.clip.rate
                let time = max(entry.clip.sourceStart, min(raw, entry.clip.sourceEnd.nextDown))
                return SourceLocation(clipID: entry.clip.id,
                                      sourceID: entry.clip.sourceID,
                                      time: time)
            }
        }
        return nil
    }

    /// 素材内の時刻 → 合成時刻。素材時刻オフセットを再生倍率で割って写す。
    /// そのクリップの使用範囲外の素材時刻を渡した場合は nil。
    /// `sourceLocation` と対称に、クリップの使用範囲は素材時刻の半開区間 [sourceStart, sourceEnd)
    /// として扱う（終端ちょうどの素材時刻は次のクリップ側に属するため nil）。
    ///
    /// 除算の丸め上がりで計算値がクリップの合成終端（次クリップ側）に達し得るため、
    /// 返却値をクリップの合成区間の終端手前（`.nextDown`）にクランプする。
    public func compositionTime(clipID: UUID, sourceTime: Double) -> Double? {
        guard let entry = entries.first(where: { $0.clip.id == clipID }) else { return nil }
        guard sourceTime >= entry.clip.sourceStart, sourceTime < entry.clip.sourceEnd else { return nil }
        let raw = entry.start + (sourceTime - entry.clip.sourceStart) / entry.clip.rate
        return min(raw, (entry.start + entry.clip.duration).nextDown)
    }

    /// クリップの合成タイムライン上の開始位置。
    public func clipStartTime(clipID: UUID) -> Double? {
        entries.first(where: { $0.clip.id == clipID })?.start
    }
}
