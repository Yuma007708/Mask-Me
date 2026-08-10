import CoreGraphics
import Foundation
import MosaicCore

#if canImport(Metal)

/// クロップ編集の下書きライフサイクル（S4）。
///
/// **クロップ編集中はプレビュー合成を `crop = .full` で組み直し、切り落とし予定の
/// 領域は `CropOverlay` の暗幕で表現する。確定時に本物の `crop` で組み直す。**
///
/// 理由: 動画のクロップは AVFoundation 段（Metal より前）で効くため、
/// `timeline.crop` が入った状態のプレビューフレームは**既に切られており**、
/// 切り落とした外側は存在しない。その上に切り抜き枠を出すと「一度縮めたら
/// 二度と広げられない」UI になる。全面で組み直すことで:
/// - 編集中は全面フレームなので、ライブ検出は**切り落とし予定の領域も検出し続ける**
/// - **クロップは検出キャッシュを一切消さない・事前走査の範囲を狭めない**
///   （`test_クロップを変えても検出キャッシュが消えず座標も変わらない` が番人）
extension MosaicEditorModel {
    /// プレビュー上の操作モード。`cropDraft` の有無だけから導く（二重管理しない）。
    public var interactionMode: EditorInteractionMode {
        cropDraft != nil ? .crop : .normal
    }

    /// プレビュー上の各操作面がいま触れるかの真理値表（`PreviewInteractionPolicy`）。
    /// `activeTab == nil`（どのタブも選んでいない）は `.background` へ寄せて渡す——
    /// この関数の `allowsFacePick` は `activeTab == .face` の一致でしか true にならないため、
    /// `.face` 以外へ寄せれば「顔タブではない」を正しく表せる（`isRectangleToolActive` は
    /// 独立の引数なので、この寄せ方は他の判定に影響しない）。
    public var previewInteraction: PreviewInteractionPolicy {
        PreviewInteractionPolicy.make(
            mode: interactionMode,
            editorMode: mode == .video ? .video : .photo,
            activeTab: activeTab == .face ? .face : .background,
            isRectangleToolActive: isRectangleToolActive)
    }

    /// クロップ編集の幾何（`CropHandleMath` / `CropAspectLock`）が `inFrame:` に渡す
    /// 出力枠のピクセルサイズ。編集中は必ず `crop = .full` の合成なので、
    /// `outputRenderSize` がそのまま「クロップ前の出力枠」を表す。
    public var cropEditingFrameSize: CGSize {
        outputRenderSize ?? .zero
    }

    /// クロップ編集を始める。
    ///
    /// **`commitEdit()` を呼ばない。** 編集を始めただけではまだ何も確定していない
    /// （取消で無かったことにできる）ので、undo 履歴には積まない。
    public func beginCropEditing() {
        cropBeforeEditing = timeline.crop
        cropDraft = timeline.crop
        cropAspectLock = .free
        replaceTimeline(timeline.settingCrop(.full))
    }

    /// ハンドルのドラッグ結果を下書きへ反映する。
    ///
    /// **`cropDraft` だけを更新する。composition には一切触らない。**
    /// ここで `replaceTimeline` / `applyTimelineEdit` を呼ぶと、指を動かすたびに
    /// Composition の再構築（非同期・重い）が走り、60fps のドラッグに追従できない
    /// （`test_ドラッグ中は合成を組み直さない` が番人）。
    public func updateCropDraft(_ crop: CropRect) {
        cropDraft = crop
    }

    /// 取消。下書きを破棄し、編集開始前のクロップへ戻す。
    ///
    /// `applyTimelineEdit`（＝`commitEdit`）を通さない `replaceTimeline` 直呼びなので、
    /// undo/redo の履歴は一切増えない。
    public func cancelCropEditing() {
        if let before = cropBeforeEditing {
            replaceTimeline(timeline.settingCrop(before))
        }
        cropDraft = nil
        cropBeforeEditing = nil
    }

    /// 確定。
    ///
    /// 一旦 `cropBeforeEditing` へ戻してから `setCrop(cropDraft)` を呼ぶ。
    ///
    /// **この戻しは公開 API から観測できない（＝落ちるテストが書けない）。**
    /// 親が変異検証で確かめた事実: この行を外しても `MosaicEditorModelCropTests` は
    /// 8 件とも緑のまま通る。`commitEdit()` 自身が `guard now != lastCommitted` を
    /// 持っているため、`timeline` が `lastCommitted` から浮いていても、確定後の
    /// スナップショットが一致すれば履歴は増えないから。
    ///
    /// **undo の正しさを実際に守っているのは「`beginCropEditing()` が `commitEdit()` を
    /// 呼ばないこと」の方**（そちらを壊すと `test_取消で編集前のクロップへ戻り履歴が
    /// 増えない` / `test_値を変えずに確定しても履歴が増えない` / `test_確定はundo1回で
    /// 編集前へ戻る` の 3 件が落ち、最後の 1 件は「undo 1 回でクロップ無しへ飛ぶ」現象
    /// そのものを捕まえる）。
    ///
    /// この行は、その不変条件が将来崩れたときに `timeline` と `lastCommitted` の
    /// ずれを持ち込ませないための多重防御として残す（`validateColorGrades()` /
    /// `validateClipTransforms()` と同じ立て付け——落ちるテストが書けない安全網は、
    /// **書けないことを明記した上で**置く）。
    public func commitCropEditing() {
        guard let before = cropBeforeEditing else {
            cropDraft = nil
            return
        }
        replaceTimeline(timeline.settingCrop(before))
        let draft = cropDraft
        cropDraft = nil
        cropBeforeEditing = nil
        if let draft {
            setCrop(draft)
        }
    }
}

#endif
