import Foundation

/// タイムライン編集の単一情報源となる状態（クリップ列 + トランジション + モザイク適用範囲）。
///
/// 編集操作は `TimelineEditOperations` を内部で呼びつつ、クリップ列の変化に合わせて
/// トランジションの整合（付け替え・破棄・duration クランプ）を保つラッパとして提供する。
/// 各操作は失敗時に self をそのまま返す（`TimelineEditOperations` の契約を透過するため、
/// 呼び出し側は「変更されたかどうか」を状態比較だけで判定できる）。
public struct TimelineState: Codable, Equatable, Sendable {
    public var clips: [TimelineClip]
    /// クリップ境界のトランジション。キーは**先行（outgoing）クリップの id**。
    public var transitions: [UUID: TransitionSpec]
    /// モザイク適用範囲（素材時刻アンカー）。空なら全区間適用。
    public var applyRanges: [MosaicApplyRange]

    public init(clips: [TimelineClip] = [],
                transitions: [UUID: TransitionSpec] = [:],
                applyRanges: [MosaicApplyRange] = []) {
        self.clips = clips
        self.transitions = transitions
        self.applyRanges = applyRanges
    }

    /// この状態に対応する写像（トランジションの重なりを含む）。
    public var mapping: TimelineMapping { TimelineMapping(clips: clips, transitions: transitions) }

    // MARK: - 編集操作

    /// 表示タイムライン（トランジションの重なり込み = `mapping` の合成時刻）の時刻で
    /// クリップを 2 分割する。UI が再生位置などの表示時刻から分割するときはこちらを使う。
    ///
    /// 内部で `TimelineMapping.editTime(forDisplayTime:)` により編集タイムラインの時刻へ
    /// 変換してから `splitting(at:)` を呼ぶ（重なり内の帰属は incoming 側）。
    /// 範囲外の時刻では self をそのまま返す。
    public func splitting(atDisplayTime displayTime: Double) -> TimelineState {
        guard let editTime = mapping.editTime(forDisplayTime: displayTime) else { return self }
        return splitting(at: editTime)
    }

    /// **編集タイムライン**（重なりを含まない = `TimelineMapping(clips:)` の写像）の
    /// 合成時刻でクリップを 2 分割する。
    ///
    /// 注意: この時刻は `mapping`（重なり込みの表示タイムライン）の合成時刻とはトランジションの
    /// 合計 duration 分ずれる。表示時刻から分割する場合は `splitting(atDisplayTime:)` を使うこと。
    /// 分割対象クリップが先行側だったトランジションは**後半クリップの id に付け替える**
    /// （その境界は後半と次クリップの間に残るため）。前半と後半の間には新規トランジションを付けない。
    /// 分割で短くなったクリップに対しては duration 制約のクランプ/破棄も適用される。
    public func splitting(at compositionTime: Double) -> TimelineState {
        let newClips = TimelineEditOperations.split(clips: clips, at: compositionTime)
        guard newClips != clips else { return self }
        let oldIDs = Set(clips.map(\.id))
        guard let backIndex = newClips.firstIndex(where: { !oldIDs.contains($0.id) }),
              backIndex > 0 else { return self }
        var newTransitions = transitions
        if let spec = newTransitions.removeValue(forKey: newClips[backIndex - 1].id) {
            newTransitions[newClips[backIndex].id] = spec
        }
        return TimelineState(clips: newClips, transitions: newTransitions, applyRanges: applyRanges)
            .normalizingTransitions()
    }

    /// 指定したクリップを取り除く。
    ///
    /// 削除クリップが先行側・後続側どちらであったトランジションも破棄する
    /// （削除で新たに隣接するペアへ引き継がない）。
    public func removing(clipID: UUID) -> TimelineState {
        let newClips = TimelineEditOperations.remove(clips: clips, clipID: clipID)
        guard newClips != clips else { return self }
        var newTransitions = transitions
        newTransitions.removeValue(forKey: clipID)
        if let index = clips.firstIndex(where: { $0.id == clipID }), index > 0 {
            newTransitions.removeValue(forKey: clips[index - 1].id)
        }
        return TimelineState(clips: newClips, transitions: newTransitions, applyRanges: applyRanges)
    }

    /// 指定したクリップを `toIndex` の位置へ並べ替える。
    ///
    /// 移動によって隣接ペアが分離したトランジションは全て破棄し、
    /// 移動後も「同じ先行→同じ後続」の隣接が保たれたものだけを残す。
    public func moving(clipID: UUID, toIndex: Int) -> TimelineState {
        let newClips = TimelineEditOperations.move(clips: clips, clipID: clipID, toIndex: toIndex)
        guard newClips != clips else { return self }
        var newTransitions: [UUID: TransitionSpec] = [:]
        for (key, spec) in transitions {
            guard let oldIndex = clips.firstIndex(where: { $0.id == key }), oldIndex + 1 < clips.count,
                  let newIndex = newClips.firstIndex(where: { $0.id == key }), newIndex + 1 < newClips.count,
                  newClips[newIndex + 1].id == clips[oldIndex + 1].id else { continue }
            newTransitions[key] = spec
        }
        return TimelineState(clips: newClips, transitions: newTransitions, applyRanges: applyRanges)
    }

    /// 指定したクリップの素材使用範囲を変更する。
    ///
    /// クリップ尺が縮んだ結果 `duration > min(両クリップ合成尺)/2` を破るトランジションは
    /// duration をクランプし、クランプ後 `TransitionSpec.minimumDuration` 未満になるものは破棄する。
    public func trimming(clipID: UUID, sourceStart: Double, sourceEnd: Double) -> TimelineState {
        let newClips = TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: sourceStart, sourceEnd: sourceEnd)
        guard newClips != clips else { return self }
        return TimelineState(clips: newClips, transitions: transitions, applyRanges: applyRanges)
            .normalizingTransitions()
    }

    /// 指定したクリップの再生倍率を設定する。トランジションのクランプ規則は `trimming` と同じ。
    public func settingRate(clipID: UUID, rate: Double) -> TimelineState {
        let newClips = TimelineEditOperations.setRate(clips: clips, clipID: clipID, rate: rate)
        guard newClips != clips else { return self }
        return TimelineState(clips: newClips, transitions: transitions, applyRanges: applyRanges)
            .normalizingTransitions()
    }

    // MARK: - 不変条件

    /// 不変条件を満たしているかを返す（デバッグ/テスト用）。
    ///
    /// - transitions のキーが実在する**非末尾**クリップであること
    /// - 各トランジションが有限の `0 < duration <= min(両クリップ合成尺)/2`（浮動小数点誤差は許容）
    /// - applyRanges が全て有限の `sourceStart < sourceEnd`
    ///   （NaN は比較を素通りしてゲート判定を黙って全滅させるため、ここで明示的に弾く）
    public func validate() -> Bool {
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }), index + 1 < clips.count,
                  spec.duration.isFinite, spec.duration > 0,
                  spec.duration <= min(clips[index].duration, clips[index + 1].duration) / 2 + 1e-9
            else { return false }
        }
        for range in applyRanges
        where !range.sourceStart.isFinite || !range.sourceEnd.isFinite || range.sourceStart >= range.sourceEnd {
            return false
        }
        return true
    }

    /// トランジションを duration 制約に合わせて正規化する。
    ///
    /// ペアが実在しない（キーが末尾または不在の）ものは破棄、
    /// `duration > min(両クリップ合成尺)/2` はクランプ、
    /// クランプ後 `TransitionSpec.minimumDuration` 未満になるものは破棄する。
    private func normalizingTransitions() -> TimelineState {
        var newTransitions: [UUID: TransitionSpec] = [:]
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }),
                  index + 1 < clips.count else { continue }
            var adjusted = spec
            adjusted.duration = min(spec.duration, min(clips[index].duration, clips[index + 1].duration) / 2)
            guard adjusted.duration >= TransitionSpec.minimumDuration else { continue }
            newTransitions[key] = adjusted
        }
        var result = self
        result.transitions = newTransitions
        return result
    }
}
