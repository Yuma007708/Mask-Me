import MosaicCore

/// 写真モードの編集（`MosaicEditorModel.photoEdit`）の入口。
///
/// **`applyTimelineEdit`（`MosaicEditorModel+Timeline.swift`）と同じ骨格。** 動画側は
/// `commitEdit()` を `applyEditResult` が呼び、`renderPreview()` は Composition 再構築の
/// 非同期完了（`MosaicPreviewController`）が担うため 2 箇所に分かれているが、写真は
/// 合成タイムラインを持たず `sourceTexture` 1 枚を即座に描き直せるので、
/// `applyPhotoEdit` **1 本**へ `commitEdit()` + `renderPreview()` + `editVersion` の
/// 発火点を閉じている（`commitEdit()` が `editVersion` を進める）。
///
/// **写真編集の setter は必ずこの関数を経由すること。** `photoEdit` へ直接代入すると
/// `renderPreview()` が呼ばれず「スライダーを動かしても絵が変わらない」事故になり、
/// `commitEdit()` も呼ばれないため undo に積まれない
/// （`PhotoEditWiringTests.testEveryMutatorGoesThroughApplyPhotoEdit` が機械的に固定している）。
extension MosaicEditorModel {
    /// 写真編集ラッパを適用し、変化があればプレビューを再描画して編集履歴に確定する。
    ///
    /// 変化が無い場合は何もしない（`applyTimelineEdit` の「失敗時は self を返す」契約と同じ）。
    func applyPhotoEdit(_ edit: (PhotoEditState) -> PhotoEditState) {
        let next = edit(photoEdit)
        guard next != photoEdit else { return }
        photoEdit = next
        renderPreview()
        commitEdit()
    }

    /// 色調補正（明るさ・コントラスト・彩度・暖かみ）を設定する。
    public func setPhotoColorGrade(_ colorGrade: ColorGrade) {
        applyPhotoEdit { state in
            var next = state
            next.colorGrade = colorGrade
            return next
        }
    }
}
