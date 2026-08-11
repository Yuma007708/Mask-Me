import MosaicCore
import SwiftUI

/// `EditorView` の下段（ドック）。**`EditorView.swift` の行数制限（500 行）を
/// 超えたので切り出した**——クロップ段と写真モードの道具列が同じ `dock` に
/// 積み上がったため。中身は移設しただけで 1 行も変えていない。
///
/// ここから見えるように、`EditorView` 側の `showPhotoColorGradeSheet` /
/// `showPhotoTextInputSheet` / `showPhotoRotateBar` は `private` を外してある
/// （`model` / `zoomSession` と同じ理由。`EditorView.swift` の doc 参照）。
extension EditorView {
    // MARK: - Dock（下段：顔サムネ / 調整バー / タブバー）

    /// 下段。**動画モードはここに何も置かない。**
    ///
    /// 動画モードのツールバーは `VideoControlsView` の中（タイムライン直下の
    /// `EditorDockView`）に 1 本だけあり、それが画面の最下段になる。ここに別の段を
    /// 置くと、道具と階層がまた 2 つの段に割れる（旧 UI の欠陥そのもの）。
    ///
    /// 写真モードは従来のまま（顔サムネ列・調整バー・タブバーを積む）。写真モードの
    /// UI 契約が `adjustmentBar` の構成に依存しているため、そちらは 1 行も変えない。
    @ViewBuilder
    var dock: some View {
        if model.mode == .photo {
            // クロップ段（`EditorDockRoute.crop`）に居る間は、通常の写真ドックの
            // 代わりに `CropControlBar` を出す。動画側（`EditorDockView`）が
            // `dockRoute` で中身を丸ごと入れ替えるのと同じ形——段の高さ・中身の
            // 入れ替え方を、モードをまたいで 1 つの流儀に揃える。
            if model.dockRoute == .crop {
                CropControlBar(model: model)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.surfaceDim)
            } else {
                photoDock
            }
        }
    }

    var photoDock: some View {
        VStack(spacing: 0) {
            // 顔タブ選択時のみ、対象の顔サムネイル列を表示。
            if model.activeTab == .face {
                FaceSelectorView(model: model)
                    .transition(.opacity)
            }

            // 調整バー：タブ選択中だけ下からスライドして表示。
            if model.activeTab != nil {
                adjustmentBar
                    .transition(.move(edge: .bottom))
            }

            // 回転（写真モード底上げ 第6段）。`.rotate` タップで出し入れするインラインの帯。
            if showPhotoRotateBar { PhotoRotateBar(model: model).transition(.move(edge: .bottom)) }

            // 色調補正（写真モード底上げ 第1段）。`EffectTabBar`（顔／背景の ON/OFF 効果）
            // とは別の道具列として横並びに置く（`PhotoTool` の doc 参照）。
            PhotoToolBar(model: model, showColorGradeSheet: $showPhotoColorGradeSheet,
                        showTextInputSheet: $showPhotoTextInputSheet, showRotateBar: $showPhotoRotateBar)
            EffectTabBar(model: model)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.surfaceDim)
        .clipped()
        .animation(.easeOut(duration: 0.25), value: model.activeTab)
    }

    var adjustmentBar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.35)

            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.35)

            Text("粗さ")
                .font(.footnote)
                .foregroundStyle(AppTheme.inkDim)

            Slider(
                value: Binding(get: { model.activeBlockSize }, set: { model.activeBlockSize = $0 }),
                in: 4...80
            )

            Button { model.confirmAdjustment() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
