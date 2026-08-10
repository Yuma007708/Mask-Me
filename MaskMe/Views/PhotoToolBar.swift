import MosaicCore
import SwiftUI

/// 写真ドックの道具（色調補正など。今後拡張）。
///
/// **`MosaicEditorModel.EffectTab` とは別の型にする。** `EffectTab` は
/// 「ON/OFF と粗さを持つ効果」（顔・背景モザイク）の型で、色調補正は矩形と同じ理由
/// （`EditorDockRoute.colorGrade` の doc 参照）で ON/OFF フラグを持たない別の性質。
/// ここへ case を足すと `EffectTab.allCases` を並べている `EffectTabBar` の意味が壊れる。
enum PhotoTool: String, CaseIterable, Identifiable {
    case colorGrade
    /// クロップ（切り抜き）段への入口。**モード遷移ではない。** `EffectTab` の
    /// ON/OFF トグルとは性質が違う（`EditorDockRoute.crop` の doc 参照。動画側の
    /// `cropItem`＝`TimelineToolItem` と同じ「作品全体の設定」）ので、`EffectTab`
    /// ではなくこちらへ足す。押すと `model.enterDock(.crop)` を呼ぶだけで、
    /// 段の中身の入れ替えは `EditorView.dock` が持つ（`activate(_:)` 参照）。
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorGrade: return "フィルター"
        case .crop: return "切り抜き"
        }
    }

    var symbolName: String {
        switch self {
        case .colorGrade: return "slider.horizontal.3"
        case .crop: return "crop"
        }
    }
}

/// 写真ドックの色調補正入口。`EffectTabBar` と横並びに置く軽量な 1 行。
///
/// タップで詳細（4 スライダー + プリセット）を `TimelineColorGradeSheet`（既存・動画側と
/// 共通）で開く。写真は「クリップ」を持たないので、シートの「すべてのクリップに適用」は
/// 使わず、`onApply` と同じ 1 枚だけへの適用に揃える（呼び出し側の `EditorView` 参照）。
struct PhotoToolBar: View {
    @ObservedObject var model: MosaicEditorModel
    @Binding var showColorGradeSheet: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func toolButton(_ tool: PhotoTool) -> some View {
        let isActive = isOn(tool)
        return Button {
            activate(tool)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 20, weight: .regular))
                Text(tool.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(width: 74, height: 60)
            .foregroundStyle(isActive ? Color.accentColor : Color(uiColor: .secondaryLabel))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.photoTool.\(tool.rawValue)")
    }

    /// チップの点灯 = 無編集ではない（現在値がプリセット「なし」から動いている）。
    private func isOn(_ tool: PhotoTool) -> Bool {
        switch tool {
        case .colorGrade: return !model.photoEdit.colorGrade.isIdentity
        case .crop: return !model.timeline.crop.isFull
        }
    }

    private func activate(_ tool: PhotoTool) {
        switch tool {
        case .colorGrade: showColorGradeSheet = true
        case .crop: model.enterDock(.crop)
        }
    }
}
