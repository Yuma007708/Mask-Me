import Foundation

/// クリップ内の元音声を消音する素材時刻区間（半開区間 [sourceStart, sourceEnd)）。
///
/// **`MosaicApplyRange` と同じ「素材時刻アンカー ＋ clipID」で持つ**（`MosaicApplyRange` 型の
/// doc・S11 参照）。クリップの分割・並べ替え・トリムに区間を書き換えずに自動追従させるための
/// 唯一の仕組みであり、消音区間だけの新しい追従機構は作らない
/// （`TimelineState.splittingEdit(at:)` / `removing(clipID:)` / `trimming(clipID:...)` が
/// `applyRanges` を付け替えている箇所に、`clipAudioMuteRanges` も同じ規則で相乗りする）。
///
/// **意味は `MosaicApplyRange` と逆である**: **区間が空 = 消音なし**（全区間で元の音量が鳴る）。
/// `MosaicApplyRange`（S11 以降）は「空 = 全区間 OFF（モザイクなし）」だが、消音は
/// 「触っていなければ元の音声のまま」が既定であるべきで、新規クリップに対して
/// 自動で消音区間を生成する入口は存在しない（`MosaicApplyGate.fullCoverRange` に相当する
/// ファクトリを消音側には**意図的に置かない**）。
///
/// 区間内では音量 0、区間外ではクリップの `TimelineClip.originalAudioVolume` が鳴る
/// （`ClipAudioMuteGate.effectiveVolume(clip:sourceTime:ranges:)`）。アプリ層の
/// `AudioMixFactory` はこの純関数を通して音量を決めること（判定を Factory 側へ書き写さない）。
///
/// 写真クリップは `TimelineState.clampedSourceTime` が素材時刻を常に 0 へ丸めるため、
/// `MosaicApplyRange` と同じく**写真クリップの消音区間は `sourceStart == 0` で固定**する
/// （`TimelineState.validate()` が検査する）。写真に音声トラックが乗ることは実運用上稀だが、
/// 型の不変条件を `MosaicApplyRange` と揃えておくことで分割・トリムの追従ロジックを
/// そのまま使い回せる。
public struct ClipAudioMuteRange: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// この区間が属するクリップの識別子（`TimelineClip.id`）。
    ///
    /// **既定値を置かないこと**（`MosaicApplyRange.clipID` の doc と同じ理由。渡し忘れを
    /// コンパイルエラーにする）。
    public let clipID: UUID
    /// 素材の識別子（`TimelineClip.sourceID` と同じ空間）。
    public let sourceID: UUID
    /// 素材内での消音開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での消音終了位置（秒）。この時刻ちょうどは区間外（半開区間）。
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

/// クリップ内消音区間のゲート判定と区間編集の純関数群。
///
/// 交差判定・マージ・編集入口の形は `MosaicApplyGate` と意図的に揃えてある
/// （同じ設計で読めるようにするため）。写真の全体カバー生成器（`fullCoverRange`）だけは
/// 消音側には存在しない（型 doc 参照: 消音は「触らなければ空」が既定）。
public enum ClipAudioMuteGate {
    /// 同一クリップ内の区間マージで「隣接」とみなす許容誤差（秒）。`MosaicApplyGate` と同値。
    private static let mergeTolerance: Double = 1e-9

    /// **交差判定の唯一の実体**（`MosaicApplyGate.clippedInterval` と同じ式）。
    static func clippedInterval(clip: TimelineClip,
                                range: ClipAudioMuteRange) -> (start: Double, end: Double)? {
        guard clip.id == range.clipID, clip.sourceID == range.sourceID else { return nil }
        let start = max(range.sourceStart, clip.sourceStart)
        let end = min(range.sourceEnd, clip.sourceEnd)
        guard start.isFinite, end.isFinite, start < end else { return nil }
        return (start, end)
    }

    /// 指定したクリップ・素材時刻が消音区間内かを返す。
    ///
    /// `MosaicApplyGate.isActive(ranges:clipID:sourceID:sourceTime:)` と違い、**フェイル方向は
    /// 常に「消音しない」**（区間が空・`clipID` が写像不能・時刻が非有限のいずれでも false）。
    /// モザイクの安全側（過剰適用）とは逆に、**音声は消音し過ぎない方が安全側**
    /// （ユーザーが指定していない区間を無音にする事故を避ける）ため、フェイルオープンさせない。
    public static func isMuted(ranges: [ClipAudioMuteRange],
                               clipID: UUID?,
                               sourceID: UUID, sourceTime: Double) -> Bool {
        guard let clipID, sourceTime.isFinite, !ranges.isEmpty else { return false }
        return ranges.contains {
            $0.clipID == clipID && $0.sourceID == sourceID
                && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
        }
    }

    /// `isMuted` の結果を音量へ変換する（消音区間内は 0、外は `clip.originalAudioVolume`）。
    ///
    /// アプリ層 `AudioMixFactory` はこの関数を通して音量を決めること
    /// （判定ロジックを Factory 側へ書き写さない）。
    public static func effectiveVolume(ranges: [ClipAudioMuteRange],
                                       clip: TimelineClip,
                                       sourceTime: Double) -> Float {
        isMuted(ranges: ranges, clipID: clip.id, sourceID: clip.sourceID, sourceTime: sourceTime)
            ? 0 : clip.originalAudioVolume
    }

    /// UI が指定した合成時刻の区間 [from, to) を素材アンカーへ分解して `existing` に追加する。
    /// `MosaicApplyGate.ranges(addingCompositionInterval:to:mapping:existing:photoSourceIDs:)` と同じ規則。
    public static func ranges(addingCompositionInterval from: Double, to: Double,
                              mapping: TimelineMapping,
                              existing: [ClipAudioMuteRange],
                              photoSourceIDs: Set<UUID> = []) -> [ClipAudioMuteRange] {
        guard from < to else { return existing }
        var result = existing
        for span in mapping.clipSpans {
            guard let interval = sourceInterval(in: span, from: from, to: to,
                                                isPhoto: photoSourceIDs.contains(span.clip.sourceID))
            else { continue }
            result.append(ClipAudioMuteRange(clipID: span.clip.id, sourceID: span.clip.sourceID,
                                             sourceStart: interval.start, sourceEnd: interval.end))
        }
        return merged(result)
    }

    /// 掴んだセグメント（`rangeID` × `clipID`）の素材区間だけを差し替える（端ドラッグの確定）。
    /// `MosaicApplyGate.ranges(replacingRangeID:clipID:compositionInterval:mapping:existing:photoSourceIDs:)` と同じ規則。
    public static func ranges(replacingRangeID id: UUID,
                              clipID: UUID,
                              compositionInterval interval: CompositionInterval,
                              mapping: TimelineMapping,
                              existing: [ClipAudioMuteRange],
                              photoSourceIDs: Set<UUID> = []) -> [ClipAudioMuteRange] {
        guard interval.isValid,
              let index = existing.firstIndex(where: { $0.id == id }),
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }),
              existing[index].clipID == clipID,
              let replacement = sourceInterval(in: span, from: interval.start, to: interval.end,
                                               isPhoto: photoSourceIDs.contains(span.clip.sourceID))
        else { return existing }
        let range = existing[index]
        let occupiedStart = max(range.sourceStart, span.clip.sourceStart)
        let occupiedEnd = min(range.sourceEnd, span.clip.sourceEnd)
        var pieces: [(start: Double, end: Double)] = []
        if occupiedStart < occupiedEnd {
            if abs(occupiedStart - replacement.start) <= mergeTolerance,
               abs(occupiedEnd - replacement.end) <= mergeTolerance { return existing }
            if range.sourceStart < occupiedStart { pieces.append((range.sourceStart, occupiedStart)) }
            if occupiedEnd < range.sourceEnd { pieces.append((occupiedEnd, range.sourceEnd)) }
        } else {
            pieces.append((range.sourceStart, range.sourceEnd))
        }
        pieces.append(replacement)
        pieces.sort { $0.start < $1.start }
        let rebuilt = pieces.enumerated().map { offset, piece in
            ClipAudioMuteRange(id: offset == 0 ? range.id : UUID(),
                               clipID: range.clipID, sourceID: range.sourceID,
                               sourceStart: piece.start, sourceEnd: piece.end)
        }
        var result = existing
        result.replaceSubrange(index...index, with: rebuilt)
        return merged(result)
    }

    /// 掴んだセグメント（`rangeID` × `clipID`）を、同一クリップ内で合成時刻換算 `delta` 秒だけ動かす。
    /// `MosaicApplyGate.ranges(movingRangeID:clipID:byCompositionDelta:mapping:existing:photoSourceIDs:)` と同じ規則
    /// （`ranges(replacingRangeID:...)` への薄いラッパ）。
    public static func ranges(movingRangeID id: UUID,
                              clipID: UUID,
                              byCompositionDelta delta: Double,
                              mapping: TimelineMapping,
                              existing: [ClipAudioMuteRange],
                              photoSourceIDs: Set<UUID> = []) -> [ClipAudioMuteRange] {
        guard delta.isFinite, delta != 0,
              let index = existing.firstIndex(where: { $0.id == id }),
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }),
              existing[index].clipID == clipID,
              !photoSourceIDs.contains(span.clip.sourceID)
        else { return existing }
        let range = existing[index]
        let clip = span.clip
        let occupiedStart = max(range.sourceStart, clip.sourceStart)
        let occupiedEnd = min(range.sourceEnd, clip.sourceEnd)
        guard occupiedStart < occupiedEnd else { return existing }
        let compositionStart = span.start + (occupiedStart - clip.sourceStart) / clip.rate
        let compositionEnd = span.start + (occupiedEnd - clip.sourceStart) / clip.rate
        var newStart = compositionStart + delta
        var newEnd = compositionEnd + delta
        if newStart < span.start {
            let adjust = span.start - newStart
            newStart += adjust
            newEnd += adjust
        }
        if newEnd > span.end {
            let adjust = newEnd - span.end
            newStart -= adjust
            newEnd -= adjust
        }
        return ranges(replacingRangeID: id, clipID: clipID,
                      compositionInterval: CompositionInterval(start: newStart, end: newEnd),
                      mapping: mapping, existing: existing, photoSourceIDs: photoSourceIDs)
    }

    /// 指定した id の区間を取り除く。見つからない場合は変更なし。
    public static func removingRange(id: UUID, from ranges: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        ranges.filter { $0.id != id }
    }

    /// 合成時刻区間 [from, to) と 1 クリップの交差を素材時刻区間へ写す。
    /// `MosaicApplyGate.sourceInterval` と同じ規則。
    private static func sourceInterval(in span: TimelineMapping.ClipSpan,
                                       from: Double, to: Double,
                                       isPhoto: Bool) -> (start: Double, end: Double)? {
        let overlapStart = max(from, span.start)
        let overlapEnd = min(to, span.end)
        guard overlapStart < overlapEnd else { return nil }
        let clip = span.clip
        guard !isPhoto else { return clip.sourceEnd > 0 ? (0, clip.sourceEnd) : nil }
        let rawStart = clip.sourceStart + (overlapStart - span.start) * clip.rate
        let rawEnd = clip.sourceStart + (overlapEnd - span.start) * clip.rate
        let sourceStart = min(max(rawStart, clip.sourceStart), clip.sourceEnd)
        let sourceEnd = min(max(rawEnd, clip.sourceStart), clip.sourceEnd)
        guard sourceStart < sourceEnd else { return nil }
        return (sourceStart, sourceEnd)
    }

    /// マージ中の 1 区間の作業状態。`MosaicApplyGate.MergeAccumulator` と同じ役割。
    private struct MergeAccumulator {
        var index: Int
        var id: UUID
        var sourceID: UUID
        var start: Double
        var end: Double
    }

    /// **同一 clipID** の重複・隣接区間をマージして正規化する。`MosaicApplyGate.merged` と同じ規則
    /// （グループキーは `sourceID` ではなく `clipID`。理由は同型のコメント参照）。
    static func merged(_ ranges: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        var order: [UUID] = []
        var groups: [UUID: [(index: Int, range: ClipAudioMuteRange)]] = [:]
        for (index, range) in ranges.enumerated() {
            if groups[range.clipID] == nil { order.append(range.clipID) }
            groups[range.clipID, default: []].append((index, range))
        }
        var result: [ClipAudioMuteRange] = []
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

    private static func flush(_ accumulated: MergeAccumulator, clipID: UUID) -> ClipAudioMuteRange {
        ClipAudioMuteRange(id: accumulated.id, clipID: clipID, sourceID: accumulated.sourceID,
                           sourceStart: accumulated.start, sourceEnd: accumulated.end)
    }
}
