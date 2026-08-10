import Foundation
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

    // MARK: - テキスト・ステッカー（写真モード底上げ 第2段）

    /// テキストを 1 本追加する（UI からの入口）。既定の位置・見た目で置く。
    public func addPhotoText(_ text: String,
                             center: NormalizedPoint = .center,
                             style: TextStyle = TextStyle()) {
        applyPhotoEdit { $0.addingText(text, center: center, style: style) }
    }

    /// ステッカー（絵文字 1 個）を 1 本追加する（UI からの入口）。
    public func addPhotoSticker(_ emoji: String, center: NormalizedPoint = .center) {
        applyPhotoEdit { $0.addingSticker(emoji, center: center) }
    }

    /// 指定したテキスト/ステッカーを取り除く。
    public func removePhotoText(id: UUID) {
        applyPhotoEdit { $0.removingText(id: id) }
    }

    /// 文面を書き換える（空文字にはできない。役割違い〈ステッカー〉は no-op）。
    public func setPhotoText(id: UUID, text: String) {
        applyPhotoEdit { $0.settingText(id: id, text: text) }
    }

    /// 画面上の位置（正規化座標）を差し替える（プレビュー上のドラッグの確定）。
    public func setPhotoTextCenter(id: UUID, center: NormalizedPoint) {
        applyPhotoEdit { $0.settingTextCenter(id: id, center: center) }
    }

    /// 見た目（フォント・色・縁取り・背景帯）を差し替える。
    public func setPhotoTextStyle(id: UUID, style: TextStyle) {
        applyPhotoEdit { $0.settingTextStyle(id: id, style: style) }
    }

    // MARK: - 回転（写真モード底上げ 第4段）
    //
    // 角度の式はここには書かない。`ClipOrientation.rotatedLeft()` / `rotatedRight()` /
    // `flippedHorizontally()` を呼ぶだけ（クリップ側の `rotateClipLeft` 等と同じ流儀）。

    /// **画面で見て**反時計回りに 90 度回す。
    public func rotatePhotoLeft() {
        applyPhotoEdit { state in
            var next = state
            next.orientation = state.orientation.rotatedLeft()
            return next
        }
    }

    /// **画面で見て**時計回りに 90 度回す。
    public func rotatePhotoRight() {
        applyPhotoEdit { state in
            var next = state
            next.orientation = state.orientation.rotatedRight()
            return next
        }
    }

    /// 左右反転する。
    public func flipPhotoHorizontally() {
        applyPhotoEdit { state in
            var next = state
            next.orientation = state.orientation.flippedHorizontally()
            return next
        }
    }
}
