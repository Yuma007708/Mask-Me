import Foundation

/// クリップ編集（分割・削除・写真トリム）への消音区間の**追従**。
///
/// `MosaicApplyRangeFactory.swift` と対になるファイル。**新規クリップに対する
/// 全体カバー生成器はここにも置かない**（`ClipAudioMuteRange` 型 doc: 消音は
/// 「触らなければ空」が既定であり、`MosaicApplyGate.fullCoverRange` に相当するものは無い）。
extension ClipAudioMuteGate {
    /// クリップ分割に区間を追従させる。`MosaicApplyGate.ranges(splittingClip:into:atSourceTime:isPhoto:existing:)`
    /// と同じ規則（境界 m を跨ぐ区間は 2 本に割る。写真は割らず前後へ `[0, sourceEnd)` を複製）。
    public static func ranges(splittingClip frontClip: TimelineClip,
                              into backClip: TimelineClip,
                              atSourceTime m: Double,
                              isPhoto: Bool,
                              existing: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        guard m.isFinite else { return existing }
        if isPhoto { return photoSplitRanges(front: frontClip, back: backClip, existing: existing) }
        return existing.flatMap { range -> [ClipAudioMuteRange] in
            guard range.clipID == frontClip.id else { return [range] }
            if range.sourceEnd <= m {
                return [ClipAudioMuteRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                                           sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            if range.sourceStart >= m {
                return [ClipAudioMuteRange(id: range.id, clipID: backClip.id, sourceID: range.sourceID,
                                           sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            return [
                ClipAudioMuteRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                                   sourceStart: range.sourceStart, sourceEnd: m),
                ClipAudioMuteRange(clipID: backClip.id, sourceID: range.sourceID,
                                   sourceStart: m, sourceEnd: range.sourceEnd)
            ]
        }
    }

    /// 写真クリップの分割: 元の区間 1 本を前後の「全体を覆う区間」2 本へ置き換える。
    /// `MosaicApplyRangeFactory.photoSplitRanges` と同じ規則。区間が無いクリップには何も配らない。
    private static func photoSplitRanges(front: TimelineClip,
                                         back: TimelineClip,
                                         existing: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        var handled = false
        return existing.flatMap { range -> [ClipAudioMuteRange] in
            guard range.clipID == front.id else { return [range] }
            guard !handled else { return [] }
            handled = true
            return [ClipAudioMuteRange(id: range.id, clipID: front.id, sourceID: range.sourceID,
                                       sourceStart: 0, sourceEnd: front.sourceEnd),
                    ClipAudioMuteRange(clipID: back.id, sourceID: range.sourceID,
                                       sourceStart: 0, sourceEnd: back.sourceEnd)]
                .filter { $0.sourceStart < $0.sourceEnd }
        }
    }

    /// **写真クリップ**のトリムに区間を追従させる（`sourceEnd` を引き直す）。
    /// 動画クリップは素材時刻アンカーが自動追従するので何もしない
    /// （`TimelineState.trimming` の doc 参照）。区間が無いクリップには何も作らない。
    public static func ranges(trimmingPhotoClip clip: TimelineClip,
                              existing: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        guard clip.sourceEnd.isFinite, clip.sourceEnd > 0 else { return existing }
        var handled = false
        return existing.flatMap { range -> [ClipAudioMuteRange] in
            guard range.clipID == clip.id else { return [range] }
            guard !handled else { return [] }
            handled = true
            return [ClipAudioMuteRange(id: range.id, clipID: clip.id, sourceID: range.sourceID,
                                       sourceStart: 0, sourceEnd: clip.sourceEnd)]
        }
    }

    /// クリップ削除に区間を追従させる（そのクリップの区間は消す。`clipID` は復活しないため）。
    public static func ranges(removingClipID clipID: UUID,
                              from ranges: [ClipAudioMuteRange]) -> [ClipAudioMuteRange] {
        ranges.filter { $0.clipID != clipID }
    }
}
