import Foundation

/// クリップの**変形**（拡大縮小・位置）編集。
///
/// `TimelineState.swift` 本体から分離してあるのは、あちらが `file_length`（500 行）の
/// 上限に張り付いているため（`TimelineStateOrientationEditing` / `TimelineStateColorGradeEditing`
/// と同じ分け方）。
extension TimelineState {
    /// 指定したクリップの変形（拡大縮小・位置）を設定する。
    ///
    /// クランプは `ClipTransform` 自身が担う（`init` / `didSet` / `init(from:)` の 3 経路）
    /// ので、ここでは何もクランプしない。**`normalizingTransitions()` は通さない**
    /// （`settingOrientation` / `settingColorGrade` と同じ理由。変形は合成尺 `duration` を
    /// 一切変えないので、トランジションのクランプ条件に影響しない）。適用区間・消音区間にも
    /// 何もしない（素材時刻アンカーなので、変形を変えても「素材のどこにモザイクを
    /// 掛けるか／どこを消音するか」は変わらない。変わるのは**画面のどこに・どれだけの
    /// 大きさで出るか**だけで、それは `VideoCompositionFactory.make` の配置矩形計算が
    /// 担当する）。
    public func settingClipTransform(clipID: UUID, transform: ClipTransform) -> TimelineState {
        let newClips = TimelineEditOperations.setTransform(
            clips: clips, clipID: clipID, transform: transform)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
    }
}
