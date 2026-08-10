import Foundation

/// クリップ内消音区間（`ClipAudioMuteRange`）の編集 API。
///
/// `TimelineStateApplyRangeEditing.swift` と対になるファイル。合成時刻 → 素材時刻アンカーへの
/// 分解・マージは `ClipAudioMuteGate` が一手に担うため、この層は「入口を 1 つに絞る」ための
/// 薄いラッパである（合成時刻のまま保存する誤実装を UI 側で書けないようにする）。
extension TimelineState {
    /// 合成時刻の区間 [from, to) を消音区間として追加する。
    public func addingClipAudioMuteRange(fromCompositionTime from: Double, to: Double) -> TimelineState {
        guard from.isFinite, to.isFinite, from < to else { return self }
        var result = self
        result.clipAudioMuteRanges = ClipAudioMuteGate.ranges(
            addingCompositionInterval: from, to: to, mapping: mapping,
            existing: clipAudioMuteRanges, photoSourceIDs: photoSourceIDs)
        return result
    }

    /// 指定した消音区間を取り除く。
    public func removingClipAudioMuteRange(id: UUID) -> TimelineState {
        let newRanges = ClipAudioMuteGate.removingRange(id: id, from: clipAudioMuteRanges)
        guard newRanges.count != clipAudioMuteRanges.count else { return self }
        var result = self
        result.clipAudioMuteRanges = newRanges
        return result
    }

    /// 掴んだセグメント（`id` の消音区間 × `clipID` のクリップ）を、新しい合成区間で
    /// 置き換える（端ドラッグの確定）。`replacingApplyRange(id:clipID:compositionInterval:)` と
    /// 同じ規則。
    public func replacingClipAudioMuteRange(id: UUID,
                                            clipID: UUID,
                                            compositionInterval interval: CompositionInterval) -> TimelineState {
        let newRanges = ClipAudioMuteGate.ranges(replacingRangeID: id, clipID: clipID,
                                                 compositionInterval: interval,
                                                 mapping: mapping, existing: clipAudioMuteRanges,
                                                 photoSourceIDs: photoSourceIDs)
        guard newRanges != clipAudioMuteRanges else { return self }
        var result = self
        result.clipAudioMuteRanges = newRanges
        return result
    }

    /// 掴んだセグメント（`id` の消音区間 × `clipID` のクリップ）を、同一クリップ内で
    /// 合成時刻換算 `delta` 秒だけ動かす。`movingApplyRange(id:clipID:byCompositionDelta:)` と
    /// 同じ規則（クリップを跨がずクランプ、写真クリップは no-op）。
    public func movingClipAudioMuteRange(id: UUID,
                                         clipID: UUID,
                                         byCompositionDelta delta: Double) -> TimelineState {
        let newRanges = ClipAudioMuteGate.ranges(movingRangeID: id, clipID: clipID,
                                                 byCompositionDelta: delta,
                                                 mapping: mapping, existing: clipAudioMuteRanges,
                                                 photoSourceIDs: photoSourceIDs)
        guard newRanges != clipAudioMuteRanges else { return self }
        var result = self
        result.clipAudioMuteRanges = newRanges
        return result
    }

    /// 全ての消音区間を取り除く（元の音声を全区間で鳴らす状態に戻す）。
    /// 区間が元々無ければ self を返す（他の編集操作と同じ「失敗時は無変更」契約）。
    public func clearingClipAudioMuteRanges() -> TimelineState {
        guard !clipAudioMuteRanges.isEmpty else { return self }
        var result = self
        result.clipAudioMuteRanges = []
        return result
    }
}
