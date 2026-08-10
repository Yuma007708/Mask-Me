import MosaicCore
import SwiftUI

// 下部ツールバーの `root` 段に並べる編集項目と、その活性判定。
// 「前へ / 後へ」の並べ替えもツールバーからの操作なのでここに同居させている。
// 本体（`VideoTimelineView.swift`）はレイアウトとジェスチャ確定に専念させ、
// file / type の行数上限に余裕を持たせるための分割である。

extension VideoTimelineView {
    // MARK: - `root` 段の項目

    /// 並びは**選択状態で変えない**。変わるのは
    /// 「押せるかどうか」と「5 番目が追加か削除か」だけ。
    ///
    /// 選択のたびに項目そのものを入れ替えていた版は、同じ位置のボタンが別の操作に
    /// 化けるため、狙って押すには毎回読み直す必要があった。位置を固定して活性だけ
    /// 変えると、押せない理由が「今それを選んでいないから」だと見た目で分かる。
    ///
    /// 末尾の項目（前へ／後へ／ズーム／モザイク区間）は幅に収まらないので
    /// 横スクロールの向こう側に置く。**落とさずに残してある**理由は各項目の doc 参照。
    var toolItems: [TimelineToolItem] {
        [splitItem, mosaicItem, speedItem, volumeItem, addOrRemoveItem]
            + [addTextItem, addAudioItem] + zoomItems
    }

    /// テキストを足す。**段の「＋」チップは置かない**（アイコン列に小さなボタンを
    /// 重ねると、段を選ぶつもりの指が追加を押す）。追加の入口はツールバーに 1 本だけ。
    private var addTextItem: TimelineToolItem {
        TimelineToolItem(title: "テキスト", systemImage: "textformat",
                         isEnabled: canAddTimedItem, separatorBefore: true) {
            showTextInputSheet = true
        }
    }

    /// BGM を足す。テキストと同じ理由でツールバーに置く。
    private var addAudioItem: TimelineToolItem {
        TimelineToolItem(title: "音楽", systemImage: "music.note",
                         isEnabled: canAddTimedItem) {
            showAudioPicker = true
        }
    }

    /// 合成時刻アンカーのアイテム（テキスト・BGM）を足せるか。
    ///
    /// **プレイヘッドの位置に置く**ので、置ける時刻が無い（クリップが無い・
    /// 終端にいる）ときは押せない。判定を追加処理と揃えておかないと
    /// 「押せるのに何も起きない」になる。
    private var canAddTimedItem: Bool {
        !model.timeline.clips.isEmpty && totalDuration > 0 && playheadTime < totalDuration
    }

    /// モザイクの階層へ降りる入口。**ここが唯一の入口**
    /// （旧 UI は画面最下部の別ドックが持っていた）。
    private var mosaicItem: TimelineToolItem {
        TimelineToolItem(title: "モザイク", systemImage: "squareshape.split.3x3",
                         isEnabled: !model.timeline.clips.isEmpty) {
            model.enterDock(.mosaic)
        }
    }

    /// 5 番目の枠。何も選んでいなければ素材追加、選んでいればそれを削除。
    ///
    /// 削除の対象は**いま選んでいるもの**（クリップでも加工レイヤーでも同じボタン）。
    /// 対象ごとにボタンを分けると、選択のたびに並びが動く。
    private var addOrRemoveItem: TimelineToolItem {
        guard selectedLayer != nil || selectedClipID != nil else { return addMediaItem }
        return TimelineToolItem(title: "削除", systemImage: "trash",
                                isEnabled: canRemoveSelection) {
            removeSelection()
        }
    }

    private var speedItem: TimelineToolItem {
        TimelineToolItem(title: "速度", systemImage: "speedometer",
                         isEnabled: selectedClip != nil) {
            speedSheetClipID = selectedClipID
        }
    }

    private var volumeItem: TimelineToolItem {
        TimelineToolItem(title: "音量", systemImage: "speaker.wave.2", isEnabled: canSetVolume) {
            // **活性判定と同じ純関数で対象を決める**（別々に書くと「押せるのに
            // 何も起きない」が作れる）。
            volumeSheetTarget = TimelineVolumeAvailability.target(
                timeline: model.timeline, selection: model.timelineSelection)
        }
    }

    private var splitItem: TimelineToolItem {
        TimelineToolItem(title: "分割", systemImage: "scissors", isEnabled: canSplit) {
            guard let id = splitTargetClipID else { return }
            model.splitClip(id: id)
        }
    }

    private var addMediaItem: TimelineToolItem {
        TimelineToolItem(title: "追加", systemImage: "photo.on.rectangle",
                         isEnabled: !model.timeline.clips.isEmpty) {
            showMediaPicker = true
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

    /// 削除の活性判定。**最後の 1 本のクリップは消せない**（空のタイムラインを作らない）。
    /// 加工レイヤーの削除にはその制約が無い。
    private var canRemoveSelection: Bool {
        if selectedLayer != nil { return true }
        return selectedClip != nil && model.timeline.clips.count > 1
    }

    /// 選択しているものを消す。**選択解除は書かない**
    /// （`model.timeline` の didSet が消えたものを刈る。二重管理にしない）。
    ///
    /// **種ごとの `switch` で全 case を網羅し、`default` は書かない**
    /// （`TimelineSelection.prune` と同じ理由。E2 で音声の種が増えたとき、
    /// ここを書き忘れると削除ボタンが黙って何もしない操作に化ける）。
    private func removeSelection() {
        if let layer = selectedLayer {
            switch layer.kind {
            case .mosaic:
                model.removeMosaicApplyRange(id: layer.id)
            case .audio:
                model.removeAudioItem(id: layer.id)
            case .text:
                model.removeTextItem(id: layer.id)
            }
        } else if let id = selectedClipID {
            model.removeClip(id: id)
        }
    }

    /// 音量の活性判定。**写真クリップは除く**（判定の理由は
    /// `TimelineVolumeAvailability` の doc 参照。純関数側に置いてテストで固定してある）。
    private var canSetVolume: Bool {
        TimelineVolumeAvailability.target(timeline: model.timeline,
                                         selection: model.timelineSelection) != nil
    }

}
