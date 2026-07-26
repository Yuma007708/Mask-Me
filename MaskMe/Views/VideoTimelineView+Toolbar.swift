import MosaicCore
import SwiftUI

// タイムライン下部のツールバー（編集項目・ズーム項目）とその活性判定。
// 「前へ / 後へ」の並べ替えもツールバーからの操作なのでここに同居させている。
// 本体（`VideoTimelineView.swift`）はレイアウトとジェスチャ確定に専念させ、
// file / type の行数上限に余裕を持たせるための分割である。

extension VideoTimelineView {
    // MARK: - ツールバー（文脈依存）

    /// いま何を選んでいるかで**中身ごと差し替える**ツールバー項目。
    ///
    /// 9 項目を常時並べていた版は、押せない項目が `opacity 0.3` で居座るうえ
    /// 3 項目が初期表示で画面外に出ていた。選択状態ごとに 4〜6 項目へ絞ると
    /// iPhone 16 の幅に収まり、隠れボタンと「押せないボタン」が同時に消える。
    var toolItems: [TimelineToolItem] {
        if selectedRangeID != nil { return rangeToolItems }
        if selectedClipID != nil { return clipToolItems }
        return idleToolItems
    }

    /// 何も選んでいないとき。**分割は選択なしでも押せる**（対象はプレイヘッド直下）。
    /// ズームはここに置く（クリップ選択中はピンチで代替できるため項目数を優先した）。
    private var idleToolItems: [TimelineToolItem] {
        [splitItem, addMediaItem, addApplyRangeItem] + zoomItems
    }

    /// クリップを選んでいるとき（そのクリップに対する操作だけ）。
    private var clipToolItems: [TimelineToolItem] {
        [
            splitItem,
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
                             isEnabled: canMoveClip(by: 1)) { moveSelectedClip(by: 1) }
        ]
    }

    /// モザイク適用区間を選んでいるとき。
    private var rangeToolItems: [TimelineToolItem] {
        [
            TimelineToolItem(title: "区間削除", systemImage: "minus.rectangle",
                             isEnabled: selectedRangeID != nil) {
                guard let id = selectedRangeID else { return }
                selectedRangeID = nil
                model.removeMosaicApplyRange(id: id)
            },
            addMediaItem
        ]
    }

    private var splitItem: TimelineToolItem {
        TimelineToolItem(title: "分割", systemImage: "scissors", isEnabled: canSplit) {
            guard let id = splitTargetClipID else { return }
            model.splitClip(id: id)
        }
    }

    private var addMediaItem: TimelineToolItem {
        TimelineToolItem(title: "素材追加", systemImage: "photo.on.rectangle",
                         isEnabled: !model.timeline.clips.isEmpty) {
            showMediaPicker = true
        }
    }

    private var addApplyRangeItem: TimelineToolItem {
        TimelineToolItem(title: "モザイク区間", systemImage: "plus.rectangle.on.rectangle",
                         isEnabled: canAddApplyRange) {
            addApplyRangeAtPlayhead()
        }
    }

    /// ズーム項目。ピンチズームを入れた後もボタンは残す
    /// （アクセシビリティと、段の再現性 = 同じ倍率へ確実に戻せること）。
    var zoomItems: [TimelineToolItem] {
        [
            TimelineToolItem(title: "縮小", systemImage: "minus.magnifyingglass",
                             isEnabled: geometry.zoomedOut() != geometry,
                             separatorBefore: true) {
                geometry = geometry.zoomedOut()
            },
            TimelineToolItem(title: "拡大", systemImage: "plus.magnifyingglass",
                             isEnabled: geometry.zoomedIn() != geometry) {
                geometry = geometry.zoomedIn()
            }
        ]
    }

    /// 分割対象のクリップ。**選択が無ければプレイヘッド直下**を対象にする。
    ///
    /// `MosaicEditorModel.splitAtCurrentPosition()` は使わない（トランジションの
    /// 重なり区間で「選択したクリップ」と「実際に割れるクリップ」が食い違うため、
    /// UI からの使用が doc で禁止されている）。ここで id を解決して `splitClip(id:)`
    /// へ渡すことで、判定・実行・見た目がすべて同じ 1 本のクリップを指す。
    private var splitTargetClipID: UUID? { selectedClipID ?? playheadClipID }

    /// 分割の活性判定。**実行と同じ純関数**（`TimelineState.canSplit`）を使う。
    ///
    /// 帯の区間（`spanStart`/`spanEnd`）で自前判定すると、トランジションの重なり区間で
    /// 「押せる/押せない」と「実際に割れるクリップ」が別の規則で決まってしまう。
    private var canSplit: Bool {
        guard let id = splitTargetClipID else { return false }
        return model.timeline.canSplit(clipID: id, atDisplayTime: playheadTime)
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
