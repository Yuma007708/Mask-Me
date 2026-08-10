import Foundation

/// トランジション（クリップ境界の切り替え効果）の編集 API（S9）。
///
/// `TimelineState.swift` 本体が file_length の閾値に張り付いているため分冊した
/// （`TimelineStateDuckFollow.swift` / `TimelineStateAudioMuteEditing.swift` と同じ理由）。
extension TimelineState {
    /// クリップ境界に設定できるトランジションの最大 duration（秒）。
    ///
    /// `= min(両クリップ合成尺)/2`。設定できない境界（`clipID` が不在・末尾クリップ・
    /// 上限が `TransitionSpec.minimumDuration` 未満）では nil を返す。
    /// UI はこれをスライダーの上限に使い、「設定したのに黙って消える」状態を避ける。
    public func maximumTransitionDuration(afterClipID clipID: UUID) -> Double? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }), index + 1 < clips.count else { return nil }
        let cap = min(clips[index].duration, clips[index + 1].duration) / 2
        guard cap.isFinite, cap >= TransitionSpec.minimumDuration else { return nil }
        return cap
    }

    /// 指定した先行クリップの直後の境界にトランジションを設定する（種類・長さの変更も同じ入口）。
    ///
    /// duration は `maximumTransitionDuration(afterClipID:)` へクランプする。
    /// クランプ後に `TransitionSpec.minimumDuration` を下回る境界では設定せず self を返す
    /// （他の編集操作と同じ「失敗時は self」契約）。
    public func settingTransition(afterClipID clipID: UUID,
                                  kind: TransitionKind,
                                  duration: Double) -> TimelineState {
        guard let cap = maximumTransitionDuration(afterClipID: clipID), duration.isFinite else { return self }
        let clamped = min(max(duration, TransitionSpec.minimumDuration), cap)
        var result = self
        result.transitions[clipID] = TransitionSpec(kind: kind, duration: clamped)
        return result
    }

    /// 指定した先行クリップの直後の境界からトランジションを取り除く。
    /// 設定が無ければ self を返す。
    public func removingTransition(afterClipID clipID: UUID) -> TimelineState {
        guard transitions[clipID] != nil else { return self }
        var result = self
        result.transitions.removeValue(forKey: clipID)
        return result
    }
}
