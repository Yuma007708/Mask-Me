import MosaicCore
import SwiftUI

// 下部ツールバーの `root` 段に並べる編集項目と、その活性判定。
// 「前へ / 後へ」の並べ替えもツールバーからの操作なのでここに同居させている。
// 本体（`VideoTimelineView.swift`）はレイアウトとジェスチャ確定に専念させ、
// file / type の行数上限に余裕を持たせるための分割である。

extension VideoTimelineView {
    // MARK: - `root` 段の項目

    /// 下部ツールバーの `root` 段の中身。**選んでいるものに応じて中身が入れ替わる。**
    ///
    /// ## 「並びは選択状態で変えない」という以前の決定を、意図的に覆している
    ///
    /// 旧方針は「位置を固定して活性だけ変える。同じ位置のボタンが別の操作に化けると、
    /// 狙って押すのに毎回読み直しになる」だった。項目が 5〜7 個で**全部見えていた**
    /// 頃はそのとおりだったが、E1〜E3 と回転・複製で 13 個まで増えた結果、
    /// **6 個目以降は横スクロールの向こう側**にいる。位置が固定でもその位置が画面外なら、
    /// 固定であることの利点は無い（実測: 回転・反転は 8〜10 番目 ＝ x が 428〜608pt で、
    /// iPhone の幅 390pt を大きく超える。「機能が無い」のと同じ状態だった）。
    ///
    /// 一般的な動画編集アプリ（CapCut / VLLO / iMovie）はいずれも
    /// **クリップを選ぶと下の段がそのクリップへの操作に変わる**。旧方針が心配していた
    /// 「同じ位置が別の操作に化ける」は、タイムラインで選んだ帯が目立って光るので
    /// 「いまクリップを選んでいる」状態が見た目で分かり、実害になりにくい。
    ///
    /// ## 段の中身
    ///
    /// | 選択 | 並び |
    /// |---|---|
    /// | 無し | モザイク / テキスト / 音楽 / 比率 / 追加 |
    /// | クリップ | 分割 / 複製 / フィルター / 速度 / 変形 / 音量 / 削除 |
    /// | 加工レイヤー（テキスト・BGM・モザイク区間） | 削除 |
    ///
    /// **「回転」「反転」は「変形」1 つに畳んである（P4）。** 以前「左回転」「右回転」を
    /// 1 ボタンへ畳んだのと同じ理由（枠が足りない）。「フィルター」を足すぶんの枠を
    /// ここで作った。段の中身（回転・反転の実ボタン）は `EditorDockView.transformButtons`
    /// （`EditorDockRoute.transform`）にある。
    ///
    /// ズームは**どの段でも末尾に置く**（ピンチが使えないときの代替という
    /// アクセシビリティ上の役割があり、落とせない。`zoomItems` の doc 参照）。
    var toolItems: [TimelineToolItem] {
        selectionToolItems + zoomItems
    }

    /// 選択状態で入れ替わる部分（ズームを除く）。
    ///
    /// **`private` を外していない理由が無くなったので `private` を外してある。**
    /// テスト（`ToolbarItemCountTests`）が「クリップ選択時は 7 個以下」を数えるために
    /// `@testable import` 経由で直接読む。活性判定・並びは実行と同じこの 1 箇所が
    /// 唯一の情報源（`splitItem` 等の doc と同じ理由）。
    var selectionToolItems: [TimelineToolItem] {
        if selectedClip != nil {
            return [splitItem, duplicateItem, filterItem, speedItem,
                    transformItem, volumeItem, removeItem]
        }
        if selectedLayer != nil {
            // 加工レイヤーは中身の編集をプレビュー・帯側が持っているので、
            // 段に出すのは削除だけでよい（音量は BGM を選んだときだけ意味がある）。
            return canSetVolume ? [volumeItem, removeItem] : [removeItem]
        }
        return [mosaicItem, addTextItem, addAudioItem, aspectRatioItem, addMediaItem]
    }

    /// クリップの向き（回転・反転）の段へ降りる入口（P4）。
    ///
    /// **回転・反転は「変形」1 つに畳んである**（押すたびに実行する即時ボタンではなく、
    /// `EditorDockRoute.transform` の段を開く形にした）。以前の「左回転」「右回転」
    /// 1 ボタン統合と同じ判断（枠が足りない）。実ボタンは `EditorDockView.transformButtons`。
    private var transformItem: TimelineToolItem {
        TimelineToolItem(title: "変形", systemImage: "rotate.right",
                         isEnabled: selectedClip != nil, separatorBefore: true) {
            model.enterDock(.transform)
        }
    }

    /// 色調補正の段へ降りる入口（P4）。
    private var filterItem: TimelineToolItem {
        TimelineToolItem(title: "フィルター", systemImage: "camera.filters",
                         isEnabled: selectedClip != nil) {
            model.enterDock(.colorGrade)
        }
    }

    /// 選んでいるものを消す。**クリップと加工レイヤーで同じボタン**（`removeSelection` が
    /// 種で振り分ける）。
    private var removeItem: TimelineToolItem {
        TimelineToolItem(title: "削除", systemImage: "trash",
                         isEnabled: canRemoveSelection, separatorBefore: true) {
            removeSelection()
        }
    }

    /// 出力の画面比率。**作品全体の設定**なので、何も選んでいないときの段に置く。
    ///
    /// 以前は再生行（`VideoControlsView.transportRow`）にあったが、そこは
    /// コマ戻し・再生・コマ送り・時刻・出力解像度・取り消し・やり直しで 8 要素あり、
    /// iPhone の幅では確実に潰れる。比率はクリップ操作ではないので、
    /// 「素材を足す」と同じ段が意味の上でも自然。
    private var aspectRatioItem: TimelineToolItem {
        TimelineToolItem(title: "比率", systemImage: "aspectratio",
                         isEnabled: !model.timeline.clips.isEmpty) {
            showAspectRatioSheet = true
        }
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

    private var speedItem: TimelineToolItem {
        TimelineToolItem(title: "速度", systemImage: "speedometer",
                         isEnabled: selectedClip != nil) {
            speedSheetClipID = selectedClipID
        }
    }

    /// 音量シートを開く。**消音中はアイコンで分かるようにする。**
    ///
    /// 音量は開かないと分からない設定で、しかも 0 にすると波形も出ない（無音素材と
    /// 見分けがつかない）。「音が出ないのは自分で消したからだ」を思い出す手がかりが
    /// 段の上に無いと、素材や書き出しの不具合を疑って時間を溶かす。一般的な編集アプリも
    /// 消音中はスピーカーに斜線を出す。
    private var volumeItem: TimelineToolItem {
        let muted = isSelectedAudioMuted
        return TimelineToolItem(title: muted ? "消音中" : "音量",
                                systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2",
                                isEnabled: canSetVolume) {
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

    /// 選択中のクリップを直後に複製する。**活性判定は「クリップを選択しているとき」**
    /// （`speedItem` / `mosaicItem` と同じ規則: `selectedClipID`/`selectedClip` が
    /// 選択状態の唯一の情報源であり、活性判定と実行の両方がそこから対象を読む）。
    private var duplicateItem: TimelineToolItem {
        TimelineToolItem(title: "複製", systemImage: "plus.square.on.square",
                         isEnabled: selectedClip != nil) {
            guard let id = selectedClipID else { return }
            model.duplicateClip(id: id)
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

    /// いま音量ボタンが指している対象が消音されているか（判定は純関数側）。
    private var isSelectedAudioMuted: Bool {
        TimelineVolumeAvailability.isMuted(timeline: model.timeline,
                                           selection: model.timelineSelection)
    }

}
