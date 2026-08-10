import Foundation

/// クリップ内で「声が鳴っている」と判定された素材時刻区間（半開区間 [sourceStart, sourceEnd)）。
///
/// **`ClipAudioMuteRange` と同じ「素材時刻アンカー ＋ clipID」で持つ**（`ClipAudioMuteRange` /
/// `MosaicApplyRange` 型の doc・S11 参照）。クリップの分割・削除・トリムに区間を書き換えずに
/// 自動追従させるための唯一の仕組みであり、BGM ダッキングだけの新しい追従機構は作らない
/// （`TimelineState.splittingEdit(at:)` / `removing(clipID:)` / `trimming(clipID:...)` が
/// `clipAudioMuteRanges` を付け替えている箇所に、`clipDuckRanges` も同じ規則で相乗りする）。
///
/// 生成は `AudioDuckingDetector`（波形からの検出）が担い、`ClipAudioMuteRange` と違って
/// ユーザーが手で追加・移動・端トリムする対話 API は無い（検出結果をそのまま保持するだけ）。
/// **区間が空でも「無音」と「まだ検出していない」を区別しない**（検出は都度やり直せるため、
/// 型としては単に「今わかっている声区間の集合」を表す）。
public struct ClipDuckRange: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// この区間が属するクリップの識別子（`TimelineClip.id`）。
    ///
    /// **既定値を置かないこと**（`ClipAudioMuteRange.clipID` の doc と同じ理由。渡し忘れを
    /// コンパイルエラーにする）。
    public let clipID: UUID
    /// 素材の識別子（`TimelineClip.sourceID` と同じ空間）。
    public let sourceID: UUID
    /// 素材内での声区間の開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での声区間の終了位置（秒）。この時刻ちょうどは区間外（半開区間）。
    public var sourceEnd: Double

    public init(id: UUID = UUID(), clipID: UUID, sourceID: UUID,
                sourceStart: Double, sourceEnd: Double) {
        self.id = id
        self.clipID = clipID
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

/// クリップ編集への声区間の**追従**。`ClipAudioMuteRangeFactory` / `ClipAudioMuteGate` と
/// 意図的に同じ形にしてある（同じ設計で読めるようにするため）。
public enum ClipDuckGate {
    /// 同一クリップ内の区間マージで「隣接」とみなす許容誤差（秒）。`ClipAudioMuteGate` と同値。
    private static let mergeTolerance: Double = 1e-9

    /// **交差判定の唯一の実体**（`ClipAudioMuteGate.clippedInterval` と同じ式）。
    static func clippedInterval(clip: TimelineClip,
                                range: ClipDuckRange) -> (start: Double, end: Double)? {
        guard clip.id == range.clipID, clip.sourceID == range.sourceID else { return nil }
        let start = max(range.sourceStart, clip.sourceStart)
        let end = min(range.sourceEnd, clip.sourceEnd)
        guard start.isFinite, end.isFinite, start < end else { return nil }
        return (start, end)
    }

    /// クリップ分割に区間を追従させる。`ClipAudioMuteGate.ranges(splittingClip:into:atSourceTime:isPhoto:existing:)`
    /// と同じ規則（境界 m を跨ぐ区間は 2 本に割る。写真は割らず前後へ `[0, sourceEnd)` を複製）。
    public static func ranges(splittingClip frontClip: TimelineClip,
                              into backClip: TimelineClip,
                              atSourceTime m: Double,
                              isPhoto: Bool,
                              existing: [ClipDuckRange]) -> [ClipDuckRange] {
        guard m.isFinite else { return existing }
        if isPhoto { return photoSplitRanges(front: frontClip, back: backClip, existing: existing) }
        return existing.flatMap { range -> [ClipDuckRange] in
            guard range.clipID == frontClip.id else { return [range] }
            if range.sourceEnd <= m {
                return [ClipDuckRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                                      sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            if range.sourceStart >= m {
                return [ClipDuckRange(id: range.id, clipID: backClip.id, sourceID: range.sourceID,
                                      sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            return [
                ClipDuckRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                             sourceStart: range.sourceStart, sourceEnd: m),
                ClipDuckRange(clipID: backClip.id, sourceID: range.sourceID,
                             sourceStart: m, sourceEnd: range.sourceEnd)
            ]
        }
    }

    /// 写真クリップの分割: 元の区間 1 本を前後の「全体を覆う区間」2 本へ置き換える。
    /// `ClipAudioMuteGate.photoSplitRanges` と同じ規則。区間が無いクリップには何も配らない。
    private static func photoSplitRanges(front: TimelineClip,
                                         back: TimelineClip,
                                         existing: [ClipDuckRange]) -> [ClipDuckRange] {
        var handled = false
        return existing.flatMap { range -> [ClipDuckRange] in
            guard range.clipID == front.id else { return [range] }
            guard !handled else { return [] }
            handled = true
            return [ClipDuckRange(id: range.id, clipID: front.id, sourceID: range.sourceID,
                                  sourceStart: 0, sourceEnd: front.sourceEnd),
                    ClipDuckRange(clipID: back.id, sourceID: range.sourceID,
                                 sourceStart: 0, sourceEnd: back.sourceEnd)]
                .filter { $0.sourceStart < $0.sourceEnd }
        }
    }

    /// **写真クリップ**のトリムに区間を追従させる（`sourceEnd` を引き直す）。
    /// 動画クリップは素材時刻アンカーが自動追従するので何もしない
    /// （`TimelineState.trimming` の doc 参照）。区間が無いクリップには何も作らない。
    public static func ranges(trimmingPhotoClip clip: TimelineClip,
                              existing: [ClipDuckRange]) -> [ClipDuckRange] {
        guard clip.sourceEnd.isFinite, clip.sourceEnd > 0 else { return existing }
        var handled = false
        return existing.flatMap { range -> [ClipDuckRange] in
            guard range.clipID == clip.id else { return [range] }
            guard !handled else { return [] }
            handled = true
            return [ClipDuckRange(id: range.id, clipID: clip.id, sourceID: range.sourceID,
                                  sourceStart: 0, sourceEnd: clip.sourceEnd)]
        }
    }

    /// クリップ削除に区間を追従させる（そのクリップの区間は消す。`clipID` は復活しないため）。
    public static func ranges(removingClipID clipID: UUID,
                              from ranges: [ClipDuckRange]) -> [ClipDuckRange] {
        ranges.filter { $0.clipID != clipID }
    }

    /// マージ中の 1 区間の作業状態。`ClipAudioMuteGate.MergeAccumulator` と同じ役割。
    private struct MergeAccumulator {
        var index: Int
        var id: UUID
        var sourceID: UUID
        var start: Double
        var end: Double
    }

    /// **同一 clipID** の重複・隣接区間をマージして正規化する。`ClipAudioMuteGate.merged` と同じ規則
    /// （グループキーは `sourceID` ではなく `clipID`。理由は同型のコメント参照）。
    static func merged(_ ranges: [ClipDuckRange]) -> [ClipDuckRange] {
        var order: [UUID] = []
        var groups: [UUID: [(index: Int, range: ClipDuckRange)]] = [:]
        for (index, range) in ranges.enumerated() {
            if groups[range.clipID] == nil { order.append(range.clipID) }
            groups[range.clipID, default: []].append((index, range))
        }
        var result: [ClipDuckRange] = []
        for clipID in order {
            guard let group = groups[clipID] else { continue }
            let sorted = group.sorted {
                $0.range.sourceStart == $1.range.sourceStart
                    ? $0.index < $1.index
                    : $0.range.sourceStart < $1.range.sourceStart
            }
            var current: MergeAccumulator?
            for member in sorted {
                if var accumulated = current, member.range.sourceStart <= accumulated.end + mergeTolerance {
                    accumulated.end = max(accumulated.end, member.range.sourceEnd)
                    if member.index < accumulated.index {
                        accumulated.index = member.index
                        accumulated.id = member.range.id
                    }
                    current = accumulated
                } else {
                    if let accumulated = current { result.append(flush(accumulated, clipID: clipID)) }
                    current = MergeAccumulator(index: member.index, id: member.range.id,
                                               sourceID: member.range.sourceID,
                                               start: member.range.sourceStart, end: member.range.sourceEnd)
                }
            }
            if let accumulated = current { result.append(flush(accumulated, clipID: clipID)) }
        }
        return result
    }

    private static func flush(_ accumulated: MergeAccumulator, clipID: UUID) -> ClipDuckRange {
        ClipDuckRange(id: accumulated.id, clipID: clipID, sourceID: accumulated.sourceID,
                     sourceStart: accumulated.start, sourceEnd: accumulated.end)
    }
}
