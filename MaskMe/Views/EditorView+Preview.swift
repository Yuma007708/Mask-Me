import SwiftUI

/// エディタ上段（プレビュー）の組み立て。
///
/// `EditorView` 本体から切り出してあるのは `file_length` / `type_body_length` の
/// 都合（`EditorTextStyleSheetModifier` を分けたときと同じ理由）。ここは重ね順が
/// そのまま操作の優先順位になる場所なので、**並びを入れ替えるときは各要素の
/// コメントに書いてある理由を先に読むこと。**
extension EditorView {
    var previewArea: some View {
        ZStack {
            Color.black

            if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if model.isLoading {
                ProgressView().tint(.white)
            }

            // 顔の枠は矩形より**下**に置く。重なったときは矩形の枠と ✕ を
            // 優先させる（矩形は自分で置いたものなので、消せなくなると困る）。
            FacePickOverlay(model: model)
            RectangleDrawingOverlay(model: model)

            // テキストの当たり判定は物体マスクと同じ理由でさらに**上**に置く
            // （`TextOverlayEditView` の doc 参照。矩形の新規作成ドラッグより
            // テキストの選択・移動を優先する）。動画モード限定はビュー内部で判定する。
            if model.mode == .video {
                TextOverlayEditView(model: model, styleSheetItemID: $textStyleItemID)
            }

            if model.mode == .video {
                VStack {
                    HStack {
                        Spacer()
                        TrackingBadge(status: model.status)
                            .padding(12)
                    }
                    Spacer()
                }
            }

            // 合成の作り直しが長引いているときだけ出す待ち表示。
            //
            // 画面比率の変更や素材の追加は composition を丸ごと組み直すため、
            // 押してから絵が変わるまでに間があく。何も出さないと「押したのに
            // 変わらない」と読まれて連打され、そのたびに再構築が積まれる。
            // 一瞬で終わる編集では立たない（`MosaicEditorModel.rebuildIndicatorDelay`）。
            if model.isRebuildingComposition {
                rebuildIndicator
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
    }

    /// 再構築中の待ち表示。**操作は塞がない**（`allowsHitTesting(false)`）。
    /// 塞ぐと、再構築が長引いたときに取り消しすらできなくなる。
    private var rebuildIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("更新中…")
                .font(.footnote)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityLabel("プレビューを更新しています")
    }
}
