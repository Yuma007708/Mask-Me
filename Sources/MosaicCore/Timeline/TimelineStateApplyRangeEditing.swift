import Foundation

/// モザイク適用区間（`MosaicApplyRange`）の編集 API（S9）。
///
/// クリップ列そのものを変える編集（`TimelineState.swift`）と違い、ここは区間だけを
/// 差し替える。合成時刻 → 素材時刻アンカーへの分解・マージは `MosaicApplyGate` が
/// 一手に担うため、この層は「入口を 1 つに絞る」ためだけの薄いラッパである。
extension TimelineState {
    // MARK: - モザイク適用区間の編集（S9）

    /// 合成時刻の区間 [from, to) をモザイク適用区間として追加する。
    ///
    /// 素材時刻アンカーへの分解・重複マージは `MosaicApplyGate` が行う
    /// （合成時刻のまま保存する誤実装を UI 側で書けないようにするための唯一の入口）。
    public func addingApplyRange(fromCompositionTime from: Double, to: Double) -> TimelineState {
        guard from.isFinite, to.isFinite, from < to else { return self }
        var result = self
        result.applyRanges = MosaicApplyGate.ranges(addingCompositionInterval: from, to: to,
                                                    mapping: mapping, existing: applyRanges,
                                                    photoSourceIDs: photoSourceIDs)
        return result
    }

    /// 指定した適用区間を取り除く。
    public func removingApplyRange(id: UUID) -> TimelineState {
        let newRanges = MosaicApplyGate.removingRange(id: id, from: applyRanges)
        guard newRanges.count != applyRanges.count else { return self }
        var result = self
        result.applyRanges = newRanges
        return result
    }

    /// 掴んだセグメント（`id` の適用区間 × `clipID` のクリップ）を、新しい合成区間で
    /// 置き換える（端ドラッグの確定）。
    ///
    /// **差し替えは素材時刻で行う**（`MosaicApplyGate.ranges(replacingRangeID:...)`）。
    /// 当該クリップが使っている素材区間だけが置き換わり、クリップ使用範囲外の素材区間は
    /// 温存されるため、UI は掴んだセグメントの情報だけを渡せばよい。
    /// 「合成時刻の区間列から作り直す」旧実装が構造的に落としていた区間の詳細は
    /// `MosaicApplyRange` 型の doc を参照。
    ///
    /// 縮める操作も表現できる。差し替え結果が現状と同じ（ドラッグ量 0）なら self を返す。
    /// マージで id が変わり得るので、UI は id を保持し続けず編集後に引き直すこと。
    public func replacingApplyRange(id: UUID,
                                    clipID: UUID,
                                    compositionInterval interval: CompositionInterval) -> TimelineState {
        let newRanges = MosaicApplyGate.ranges(replacingRangeID: id, clipID: clipID,
                                               compositionInterval: interval,
                                               mapping: mapping, existing: applyRanges,
                                               photoSourceIDs: photoSourceIDs)
        guard newRanges != applyRanges else { return self }
        var result = self
        result.applyRanges = newRanges
        return result
    }
}
