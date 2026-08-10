import SwiftUI
import MosaicCore

/// エディタ上段（プレビュー）の組み立て。
///
/// `EditorView` 本体から切り出してあるのは `file_length` / `type_body_length` の
/// 都合（`EditorTextStyleSheetModifier` を分けたときと同じ理由）。ここは重ね順が
/// そのまま操作の優先順位になる場所なので、**並びを入れ替えるときは各要素の
/// コメントに書いてある理由を先に読むこと。**
///
/// ## `PreviewImageGeometry` を作るのはここ 1 箇所だけ
///
/// 画像も 3 つのオーバーレイ（`FacePickOverlay` / `RectangleDrawingOverlay` /
/// `TextOverlayEditView`）も、ここで作った 1 個の `geometry` の従属変数として描く。
/// 「等比フィットの修飾子」+「拡大の修飾子」+ `.offset` で絵を動かし、枠を数式で
/// 動かす形にすると、絵と枠が食い違う経路が 2 本できてしまう（`.offset` はレイアウトと
/// 当たり判定を動かさないという、`dev-patterns` の `ui-state.md` に前科のある罠）。
/// 画像を `imageRect` から直接 `.frame` + `.position` で描くことで、この食い違いが
/// 定義上あり得なくなる。**この一本化を崩さないこと**（`.swiftlint.yml` の
/// `preview_geometry_single_construction` / `preview_image_uses_geometry_rect` が
/// 機械的に番をしている）。
extension EditorView {
    var previewArea: some View {
        GeometryReader { geo in
            // **表示する画像も、その `crop` も `model` の 1 箇所（`croppedPreviewImage` /
            // `previewGeometryCrop`）から取る。** 動画はどちらも「クロップなし」に
            // 揃う（動画は AVFoundation 段で既に切られており、`croppedPreviewImage` も
            // `previewGeometryCrop` も動画モードでは常に「そのまま」を返す）。写真は
            // `croppedPreviewImage` が `timeline.crop` でピクセルを実際に切り、
            // `previewGeometryCrop` が同じ crop を返してオーバーレイ側の正規化座標
            // （切る前の全画素基準）を切った後の画像へ写し直す（両者が食い違うと
            // 「顔タップが別人を指す」——モザイクを減らす方向の欠陥になる）。
            // クロップ編集中（`cropDraft != nil`）はどちらも「クロップなし」に倒れる
            // （`MosaicEditorModel+Crop.swift` 型 doc 参照）。
            let geometry = PreviewImageGeometry(containerSize: geo.size,
                                                imageSize: model.croppedPreviewImage?.size,
                                                zoom: zoomSession.zoom,
                                                crop: model.previewGeometryCrop)
            ZStack {
                Color.black

                if let image = model.croppedPreviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geometry.imageRect.width, height: geometry.imageRect.height)
                        .position(x: geometry.imageRect.midX, y: geometry.imageRect.midY)
                } else if model.isLoading {
                    ProgressView().tint(.white)
                }

                // 顔の枠は矩形より**下**に置く。重なったときは矩形の枠と ✕ を
                // 優先させる（矩形は自分で置いたものなので、消せなくなると困る）。
                FacePickOverlay(model: model, geometry: geometry)
                RectangleDrawingOverlay(model: model, geometry: geometry,
                                        isZoomGestureActive: isPinchZooming)

                // テキストの当たり判定は物体マスクと同じ理由でさらに**上**に置く
                // （`TextOverlayEditView` の doc 参照。矩形の新規作成ドラッグより
                // テキストの選択・移動を優先する）。動画モード限定はビュー内部で判定する。
                if model.mode == .video {
                    TextOverlayEditView(model: model, styleSheetItemID: $textStyleItemID,
                                        geometry: geometry)
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

                // クロップ編集中の暗幕＋ハンドル。**一番上に置く**——クロップ編集中は
                // `PreviewInteractionPolicy` が他の操作面（顔ピック・矩形・テキスト・
                // ピンチズーム）をすべて止める設計だが、重ね順でも当たり判定を
                // 一番手前で確実に奪う（`CropOverlay` 自身は `allowsCropHandles` が
                // false のときは `allowsHitTesting(false)` で透過する）。
                if let cropDraft = model.cropDraft {
                    CropOverlay(model: model, geometry: geometry, cropDraft: cropDraft)
                }

                // ズームの探針。UI テストが読む値（`VideoControlsView.swift` の
                // `editor.currentTime` と同じ流儀）。**独立した葉要素にする** —
                // コンテナへ素で `accessibilityIdentifier` を置くと子孫へ配ってしまう
                // 罠（`ui-state.md`）があるため、単体の `Color.clear` にする。
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("editor.previewZoom")
                    .accessibilityValue(String(format: "%.3f", zoomSession.zoom.scale))
            }
            // 拡大した絵がドック／タイムラインへはみ出さないようにする。
            .clipped()
            // UI テストがピンチ位置を計算するための土台。**`.contain` を先に置く**——
            // これが無いと、コンテナに付けた識別子が子孫（顔の枠・矩形・テキスト）へ
            // 配られ、それぞれが持つ `editor.facePick` / `editor.objectMask` 等を
            // 上書きする（`editor.objectMask` の doc に同じ注意がある）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.previewArea")
            // **2 本指＝ズーム／パン、1 本指＝編集。** `.simultaneousGesture` で付ける。
            // `.highPriorityGesture` は使わない — 親に付けると子（矩形ドラッグ・
            // テキスト移動）より先に成立し、1 本指の編集を全部先取りしてしまう
            // （`ui-state.md` の前科）。
            .simultaneousGesture(pinchPanGesture(fittedSize: geometry.fittedRect.size,
                                                  containerSize: geo.size))
            .simultaneousGesture(doubleTapZoomGesture(fittedSize: geometry.fittedRect.size,
                                                       containerSize: geo.size))
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        // 画面比率変更・素材切替・読み込み完了・写真クロップの確定を 1 本の条件で覆う
        // （`croppedPreviewImage` はクロップ後の実寸なので、クロップで縦横比が変わった
        // ときもズームを正しくリセットする）。
        .onChange(of: model.croppedPreviewImage?.size) { _ in zoomSession.reset() }
    }

    /// ピンチズーム＋パンの合成ジェスチャ。
    ///
    /// iOS 16 が下限なので `MagnifyGesture`（位置付き、17+ 限定）は使えず
    /// `MagnificationGesture` を使う（`TimelineScrollContainer.pinchGesture` と同じ理由）。
    /// パンは `DragGesture(minimumDistance: 0)` との `.simultaneously(with:)` 合成で持ち、
    /// **`value.first`（Magnification 側）が実際に成立しているときだけ** translation を
    /// 採用する。1 本指だけの操作では `value.first` が nil のままなので、この関数は
    /// 何もせず `zoomSession` にも触れない——1 本指の矩形ドラッグ・回転・テキスト移動を
    /// 構造的に奪わない理由はここにある。
    private func pinchPanGesture(fittedSize: CGSize, containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            // **`isPinchZooming` はここでだけ更新する。** `@GestureState` はジェスチャが
            // 途中でキャンセルされても自動で `false` に戻るため、`zoomSession.isActive`
            // （手動管理・キャンセルで戻らない）よりこちらを 1 本指編集の可否に使う。
            .updating($isPinchZooming) { value, state, _ in
                state = value.first != nil
            }
            .onChanged { value in
                // クロップ編集中はピンチズームも止める（`PreviewInteractionPolicy` の
                // 排他。クロップ枠のドラッグと取り合いにしない）。
                guard model.previewInteraction.allowsPinchZoom else { return }
                guard let magnification = value.first else { return }
                if !zoomSession.isActive {
                    // アンカーは iOS 16 に位置付きジェスチャが無いため、合成した
                    // `DragGesture` の `startLocation` で近似する（`began` 自体は
                    // 現状アンカーを使わないが、将来の拡張へシグネチャを揃えるため渡す）。
                    let start = value.second?.startLocation ?? CGPoint(x: containerSize.width / 2,
                                                                        y: containerSize.height / 2)
                    let anchor = CGSize(width: start.x - containerSize.width / 2,
                                        height: start.y - containerSize.height / 2)
                    zoomSession.began(anchorFromCenter: anchor)
                }
                let translation = value.second?.translation ?? .zero
                zoomSession.changed(magnification: magnification, translation: translation,
                                    fittedSize: fittedSize, containerSize: containerSize)
            }
            .onEnded { value in
                guard value.first != nil else { return }
                zoomSession.ended()
            }
    }

    /// ダブルタップでリセット（1 倍 ↔ 3 倍のトグルは `PreviewZoomSession.doubleTapped` 側）。
    /// タップ位置をアンカーに使うため `SpatialTapGesture`（iOS 16+）を使う——
    /// `.onTapGesture` は位置を返さない。
    private func doubleTapZoomGesture(fittedSize: CGSize, containerSize: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                let anchor = CGSize(width: value.location.x - containerSize.width / 2,
                                    height: value.location.y - containerSize.height / 2)
                zoomSession.doubleTapped(anchorFromCenter: anchor, fittedSize: fittedSize,
                                         containerSize: containerSize)
            }
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
