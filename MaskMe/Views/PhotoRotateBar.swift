import SwiftUI

/// 写真の回転（写真モード底上げ 第6段）。左90°／右90°／左右反転の3ボタン
/// （写真.app 準拠——回転はワンタップの即時操作で、シートは開かない）。
///
/// タップは `MosaicEditorModel.rotatePhotoLeft()` / `rotatePhotoRight()` /
/// `flipPhotoHorizontally()` を直接呼ぶだけ。どれも `applyPhotoEdit` 経由なので
/// プレビュー再描画・undo 履歴への確定は呼び出し先が担う（このビューは何も持たない）。
struct PhotoRotateBar: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        HStack(spacing: 24) {
            button(systemName: "rotate.left", accessibilityID: "rotateLeft") {
                model.rotatePhotoLeft()
            }
            button(systemName: "rotate.right", accessibilityID: "rotateRight") {
                model.rotatePhotoRight()
            }
            button(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                  accessibilityID: "flipHorizontal") {
                model.flipPhotoHorizontally()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.surfaceDim)
        .accessibilityIdentifier("editor.photoRotateBar")
    }

    private func button(systemName: String, accessibilityID: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Circle().fill(AppTheme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.photoRotateBar.\(accessibilityID)")
    }
}
