import MosaicCore
import SwiftUI

// タイムライン下部のツールバー（編集項目・ズーム項目）とその活性判定。
// 「前へ / 後へ」の並べ替えもツールバーからの操作なのでここに同居させている。
// 本体（`VideoTimelineView.swift`）はレイアウトとジェスチャ確定に専念させ、
// file / type の行数上限に余裕を持たせるための分割である。

extension VideoTimelineView {
    // MARK: - ツールバー

    var toolItems: [TimelineToolItem] {
        [
            TimelineToolItem(title: "分割", systemImage: "scissors", isEnabled: canSplit) {
                guard let id = selectedClipID else { return }
                model.splitClip(id: id)
            },
            TimelineToolItem(title: "削除", systemImage: "trash", isEnabled: canRemoveClip) {
                guard let id = selectedClipID else { return }
                selectedClipID = nil
                model.removeClip(id: id)
            },
            TimelineToolItem(title: "速度", systemImage: "speedometer", isEnabled: selectedClip != nil) {
                speedSheetClipID = selectedClipID
            },
            TimelineToolItem(title: "音量", systemImage: "speaker.wave.2", isEnabled: canSetVolume) {
                volumeSheetClipID = selectedClipID
            },
            // 長押し並べ替えの代替。画面外のクリップとも入れ替えられる
            // （ドラッグは同時に見えている範囲＋自動スクロールの届く範囲に限られる）。
            TimelineToolItem(title: "前へ", systemImage: "arrow.left",
                             isEnabled: canMoveClip(by: -1)) { moveSelectedClip(by: -1) },
            TimelineToolItem(title: "後へ", systemImage: "arrow.right",
                             isEnabled: canMoveClip(by: 1)) { moveSelectedClip(by: 1) },
            TimelineToolItem(title: "素材追加", systemImage: "photo.on.rectangle",
                             isEnabled: !model.timeline.clips.isEmpty) {
                showMediaPicker = true
            },
            TimelineToolItem(title: "モザイク区間", systemImage: "plus.rectangle.on.rectangle",
                             isEnabled: canAddApplyRange, separatorBefore: true) {
                addApplyRangeAtPlayhead()
            },
            TimelineToolItem(title: "区間削除", systemImage: "minus.rectangle",
                             isEnabled: selectedRangeID != nil) {
                guard let id = selectedRangeID else { return }
                selectedRangeID = nil
                model.removeMosaicApplyRange(id: id)
            }
        ]
    }

    /// ツールバー右端に固定する項目（横スクロールしない）。
    ///
    /// 編集項目と同じ横スクロールに並べると、概算 434pt に対し iPhone 16 の 393pt では
    /// **初期表示で画面外**に出る。ピンチズームを入れた後もボタンは残す
    /// （アクセシビリティと、段の再現性 = 同じ倍率へ確実に戻せること）。
    var zoomItems: [TimelineToolItem] {
        [
            TimelineToolItem(title: "縮小", systemImage: "minus.magnifyingglass",
                             isEnabled: geometry.zoomedOut() != geometry) {
                geometry = geometry.zoomedOut()
            },
            TimelineToolItem(title: "拡大", systemImage: "plus.magnifyingglass",
                             isEnabled: geometry.zoomedIn() != geometry) {
                geometry = geometry.zoomedIn()
            }
        ]
    }

    /// 分割の活性判定。**実行と同じ純関数**（`TimelineState.canSplit`）を使う。
    ///
    /// 帯の区間（`spanStart`/`spanEnd`）で自前判定すると、トランジションの重なり区間で
    /// 「押せる/押せない」と「実際に割れるクリップ」が別の規則で決まってしまう。
    private var canSplit: Bool {
        guard let selectedClipID else { return false }
        return model.timeline.canSplit(clipID: selectedClipID, atDisplayTime: playheadTime)
    }

    private var canRemoveClip: Bool { selectedClip != nil && model.timeline.clips.count > 1 }

    /// 音量の活性判定。**写真クリップは除く**（判定の理由は
    /// `TimelineVolumeAvailability` の doc 参照。純関数側に置いてテストで固定してある）。
    private var canSetVolume: Bool {
        TimelineVolumeAvailability.isEnabled(timeline: model.timeline, clipID: selectedClipID)
    }

    private var canAddApplyRange: Bool {
        !model.timeline.clips.isEmpty && totalDuration > 0 && playheadTime < totalDuration
    }
}

// MARK: - クリップの並べ替え（ボタン操作）

/// 長押しドラッグの代替経路。ドラッグは「同時に見えている範囲 + 自動スクロールが
/// 届く範囲」でしか届かないうえ、`scrollTo` がドラッグ中の `UIScrollView` に効くかは
/// 環境依存なので、**確実に動く手段**として 1 つずつ動かすボタンを併置してある。
private extension VideoTimelineView {
    func canMoveClip(by offset: Int) -> Bool {
        guard let index = selectedClipIndex else { return false }
        let target = index + offset
        return target >= 0 && target < model.timeline.clips.count
    }

    func moveSelectedClip(by offset: Int) {
        guard let id = selectedClipID, let index = selectedClipIndex else { return }
        model.moveClip(id: id, toIndex: index + offset)
    }

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return nil }
        return model.timeline.clips.firstIndex { $0.id == selectedClipID }
    }
}
