import Foundation

/// クリップの**複製**（`TimelineState.duplicating` / `duplicatingEdit`）。
///
/// `TimelineState.swift` 本体から分離してあるのは、あちらが `file_length`（500 行）の
/// 上限に張り付いているため（`TimelineStateApplyRangeEditing` / `TimelineStateAudioEditing`
/// と同じ分け方）。
extension TimelineState {
    /// 指定したクリップを複製し、その**直後**に同じ設定（トリム範囲・速度・音量）の
    /// クリップとして挿入する（複製の唯一の入口）。
    ///
    /// **トランジションの扱い**: 複製クリップは元クリップと後続クリップの間に割り込むため、
    /// 元クリップが後続との境界に持っていた outgoing トランジション（`transitions[clipID]`）は
    /// **複製先へ付け替える**（境界そのものが複製先と後続の間へ移動するため）。
    /// 元クリップと複製先の**新しい**境界にはトランジションを追加しない。これは
    /// `splitting(at:)` が front/back の新しい境界に何も追加しないのと同じ規則で、
    /// 「新しく生まれた境界にはユーザーが明示的に設定するまでトランジションを置かない」という
    /// 既存の一貫性を保つ。
    ///
    /// **適用区間の扱い**: `MosaicApplyRange` は `clipID` でスコープされる（型の doc 参照）ため、
    /// 元クリップの `clipID` に紐づく区間をそのまま流用すると複製先には一切効かない
    /// （＝複製したのにモザイク設定が引き継がれない）。そこで元クリップの区間を
    /// 複製先の `clipID` で複製し、既存区間に追加する。素材時刻アンカー
    /// （`sourceID`/`sourceStart`/`sourceEnd`）は元と同じ値のまま引き継ぐ
    /// （複製先の素材使用範囲も元と同一なので、写真クリップの `sourceStart == 0` 不変条件も
    /// そのまま保たれる）。
    ///
    /// **BGM・テキスト（`audioItems`/`textItems`）には触れない**（意図的）。両者は
    /// クリップの編集に追従しない合成時刻アンカーで、`trimming` がクリップ尺を伸縮させても
    /// 同じく追従させていない（型 doc 参照）。複製は「尺が伸びる」点で trimming と同種の
    /// 影響しか持たないため、既存の規則（BGM/テキストはクリップ編集に追従しない）をそのまま
    /// 適用し、新しい追従経路を作らない。
    ///
    /// `clipID` が見つからない場合は self を返す（他の編集操作と同じ「失敗時は無変更」契約）。
    public func duplicating(clipID: UUID) -> TimelineState {
        duplicatingEdit(clipID: clipID).state
    }

    /// `duplicating(clipID:)` に**血統**（`ClipLineage`）を添えた版（複製の実装本体）。
    ///
    /// **物体マスク（`ObjectMask`）の複製にはこの血統が要る。** 複製先は「元クリップの直後・
    /// 同じ `sourceID`・元は編集前から存在」という分割の後半と同じ見た目になるため、
    /// 差分から推測すると必ず分割として処理され、元クリップのマスクが潰れる
    /// （`ClipLineage` の doc に経緯）。
    public func duplicatingEdit(clipID: UUID) -> TimelineEdit {
        let newClips = TimelineEditOperations.duplicate(clips: clips, clipID: clipID)
        guard newClips != clips else { return TimelineEdit(self) }
        let oldIDs = Set(clips.map(\.id))
        guard let copy = newClips.first(where: { !oldIDs.contains($0.id) }) else {
            return TimelineEdit(self)
        }

        var newTransitions = transitions
        if let spec = newTransitions.removeValue(forKey: clipID) {
            newTransitions[copy.id] = spec
        }

        let copiedRanges = applyRanges.filter { $0.clipID == clipID }.map {
            MosaicApplyRange(clipID: copy.id, sourceID: $0.sourceID,
                             sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd)
        }
        let newRanges = applyRanges + copiedRanges

        // 消音区間も適用区間と同じ理由で `clipID` スコープなので、複製先の `clipID` で複製する
        // （`ClipAudioMuteRange` 型 doc 参照。複製したのに消音設定が引き継がれない事故を防ぐ）。
        let copiedMuteRanges = clipAudioMuteRanges.filter { $0.clipID == clipID }.map {
            ClipAudioMuteRange(clipID: copy.id, sourceID: $0.sourceID,
                               sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd)
        }
        let newMuteRanges = clipAudioMuteRanges + copiedMuteRanges

        // 声区間（ダッキングの根拠）も同じ `clipID` スコープなので、まったく同じ規則で複製する。
        //
        // **ここを忘れると `validate()` が落ちる**（複製先のクリップには区間が無いのに、
        // 元クリップの区間だけが残る形自体は不正ではないが、`fuzz` が示したとおり
        // 後続の分割・削除と組み合わさると実在しないクリップを指す孤児が生まれる）。
        // `orientation` を複製が引き継がずマージで欠落した前科、`clipAudioMuteRanges` を
        // 追加したときにここへ足した経緯と同じ。**クリップに `clipID` スコープの
        // 付随データを足したら、必ずこの関数へ足すこと。**
        let copiedDuckRanges = clipDuckRanges.filter { $0.clipID == clipID }.map {
            ClipDuckRange(clipID: copy.id, sourceID: $0.sourceID,
                          sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd)
        }
        let newDuckRanges = clipDuckRanges + copiedDuckRanges

        let state = replacing(clips: newClips, transitions: newTransitions, applyRanges: newRanges,
                              clipAudioMuteRanges: newMuteRanges,
                              clipDuckRanges: newDuckRanges)
            .normalizingTransitions()
        return TimelineEdit(state, lineage: [.duplicate(original: clipID, copy: copy.id)])
    }
}
