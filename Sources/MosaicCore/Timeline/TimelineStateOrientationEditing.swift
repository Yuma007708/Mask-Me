import Foundation

/// クリップの**向き**（90 度単位の回転 + 左右反転）編集。
///
/// `TimelineState.swift` 本体から分離してあるのは、あちらが `file_length`（500 行）の
/// 上限に張り付いているため（`TimelineStateDuplication` / `TimelineStateFreeze` と同じ分け方。
/// `clipAudioMuteRanges` の追加で押し出された）。
extension TimelineState {
    /// 指定したクリップの向き（90 度単位の回転 + 左右反転）を設定する。
    ///
    /// **`normalizingTransitions()` は通さない**（`settingVolume` と同じ理由。向きは
    /// 合成尺 `duration` を一切変えないので、トランジションのクランプ条件に影響しない）。
    /// 適用区間・消音区間にも何もしない（素材時刻アンカーなので、向きを変えても「素材のどこに
    /// モザイクを掛けるか／どこを消音するか」は変わらない。変わるのは**画面のどこに出るか**だけで、
    /// それは `TimelineRenderLayout` の写像が担当する）。
    public func settingOrientation(clipID: UUID, orientation: ClipOrientation) -> TimelineState {
        let newClips = TimelineEditOperations.setOrientation(
            clips: clips, clipID: clipID, orientation: orientation)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
    }

    /// 指定したクリップを**画面で見て**反時計回りに 90 度回す。
    public func rotatingClipLeft(clipID: UUID) -> TimelineState {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return self }
        return settingOrientation(clipID: clipID, orientation: clip.orientation.rotatedLeft())
    }

    /// 指定したクリップを**画面で見て**時計回りに 90 度回す。
    public func rotatingClipRight(clipID: UUID) -> TimelineState {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return self }
        return settingOrientation(clipID: clipID, orientation: clip.orientation.rotatedRight())
    }

    /// 指定したクリップを**画面で見て**左右反転する
    /// （`ClipOrientation.flippedHorizontally()` の doc 参照。回転も逆向きになる）。
    public func flippingClipHorizontally(clipID: UUID) -> TimelineState {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return self }
        return settingOrientation(clipID: clipID,
                                  orientation: clip.orientation.flippedHorizontally())
    }
}
