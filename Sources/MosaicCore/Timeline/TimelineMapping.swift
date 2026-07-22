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
    public func sourceLocation(at compositionTime: Double) -> SourceLocation? {
        guard compositionTime >= 0, compositionTime < totalDuration else { return nil }
        for entry in entries {
            let end = entry.start + entry.clip.duration
            if compositionTime < end {
                let offset = compositionTime - entry.start
                return SourceLocation(clipID: entry.clip.id,
                                      sourceID: entry.clip.sourceID,
                                      time: entry.clip.sourceStart + offset)
            }
        }
        return nil
    }

    /// 素材内の時刻 → 合成時刻。
    /// そのクリップの使用範囲外の素材時刻を渡した場合は nil。
    public func compositionTime(clipID: UUID, sourceTime: Double) -> Double? {
        guard let entry = entries.first(where: { $0.clip.id == clipID }) else { return nil }
        let offset = sourceTime - entry.clip.sourceStart
        guard offset >= 0, offset < entry.clip.duration else { return nil }
        return entry.start + offset
    }

    /// クリップの合成タイムライン上の開始位置。
    public func clipStartTime(clipID: UUID) -> Double? {
        entries.first(where: { $0.clip.id == clipID })?.start
    }
}
