import MosaicCore
import SwiftUI

/// クロップ段（`EditorDockRoute.crop`）の中身: `[取消][比率▾][リセット][確定]`。
///
/// **シートでプレビューを覆うとクロップ操作ができない**（iOS 16 が下限なので
/// `presentationBackgroundInteraction`(16.4+) は使えない）ため、この段はシートではなく
/// `EditorDockView` の通常のドック段として出す。高さは他の段と同じ
/// `EditorDockView.height`（52pt）——階層で段の高さを変えない契約
/// （`EditorDockView` の型 doc）に従う。
///
/// 取消・確定は `model.dockBack()` / `model.dockDone()` と同じ意味
/// （`MosaicEditorModel+Dock.swift` の `dockBack` / `dockDone` が `crop` 段だけ
/// `cancelCropEditing` / `commitCropEditing` を呼んでから段を戻す）。ヘッダの汎用
/// `‹` / 「完了」からも同じ操作ができるが、クロップは操作の意味が読み取りづらいので
/// 段の中身にも明示のボタンを置く。
struct CropControlBar: View {
    @ObservedObject var model: MosaicEditorModel
    @State private var showCropSheet = false

    var body: some View {
        HStack(spacing: 6) {
            button(title: "取消", systemImage: "xmark") {
                model.dockBack()
            }
            .accessibilityIdentifier("editor.crop.cancel")
            button(title: "比率", systemImage: "aspectratio") {
                showCropSheet = true
            }
            .accessibilityIdentifier("editor.crop.aspectRatio")
            button(title: "リセット", systemImage: "arrow.counterclockwise") {
                model.updateCropDraft(.full)
            }
            .accessibilityIdentifier("editor.crop.reset")
            Spacer(minLength: 0)
            confirmButton
        }
        .sheet(isPresented: $showCropSheet) {
            CropSheet(model: model, onClose: { showCropSheet = false })
        }
    }

    private var confirmButton: some View {
        Button {
            model.dockDone()
        } label: {
            Text("確定")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.crop.confirm")
    }

    private func button(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 56, height: 42)
            .foregroundStyle(Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
