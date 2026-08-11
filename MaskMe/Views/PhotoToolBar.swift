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
    /// テキスト・ステッカーの追加（写真モード底上げ 第2段）。**入口は 1 個に相乗りさせる。**
    /// 動画側は文字とステッカーで同じシート（`TimelineTextInputSheet`）を共有しており
    /// （`Mode` の Picker で切り替える）、写真も同じ流儀に揃える。ここに `.sticker` を
    /// 別 case として持つのは、道具列のボタンとしては見た目を分けたいため
    /// （タップした瞬間にどちらの意図か伝わるほうが良い）だが、開くシートは同じ。
    case text
    case sticker
    /// 回転（写真モード底上げ 第6段）。タップで `PhotoRotateBar` を出し入れする
    /// （シートは開かない——`colorGrade`/`text`/`sticker` と違い、回転は
    /// ワンタップの即時操作 3 個の並びなので、写真.app に合わせてインラインの帯にする）。
    case rotate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorGrade: return "フィルター"
        case .crop: return "切り抜き"
        case .text: return "テキスト"
        case .sticker: return "ステッカー"
        case .rotate: return "回転"
        }
    }

    /// 道具の役割（色分けの表は `AppTheme.ToolAccent`）。**動画側の同じ道具と同じ色に
    /// する**——「フィルター」「テキスト」は動画のツールバーでも `decorate`、
    /// 「切り抜き」「回転」は `shape`。写真と動画で同じ道具の色が違うと、色分けが
    /// 意味を失う（`AppTheme` の doc: 道具の表とタイムラインの帯の表は 1 つに保つ）。
    var accent: Color {
        switch self {
        case .colorGrade, .text, .sticker: return AppTheme.ToolAccent.decorate
        case .crop, .rotate: return AppTheme.ToolAccent.shape
        }
    }

    var symbolName: String {
        switch self {
        case .colorGrade: return "slider.horizontal.3"
        case .crop: return "crop"
        case .text: return "textformat"
        // **`face.smiling` は使わない。** 同じ段の下にある「顔」（モザイクを掛ける
        // 対象）が同じ絵で、色だけ違う状態になっていた。意味の違う 2 つが同じ絵だと
        // 色分けの効果が消える。
        case .sticker: return "sparkles"
        case .rotate: return "rotate.left"
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
    /// テキスト・ステッカー入力シート（既存 `TimelineTextInputSheet`）の提示条件。
    /// 文字・ステッカーどちらのボタンから開いても同じシートを共有する
    /// （`PhotoTool.text` / `.sticker` の doc 参照）。
    @Binding var showTextInputSheet: Bool
    /// `PhotoRotateBar`（左90°／右90°／左右反転の3ボタン）の表示・非表示（写真モード底上げ 第6段）。
    @Binding var showRotateBar: Bool

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
            // **色は絵だけに載せ、文字は白のまま**（動画側 `TimelineToolbarView.button`
            // と同じ流儀。両方を色にすると読みにくくなる）。編集済みの道具は
            // 絵の背景を濃くして「触ってある」ことを示す。
            VStack(spacing: 6) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(tool.accent)
                    .frame(width: 38, height: 32)
                    .background(tool.accent.opacity(isActive ? 0.34 : 0.16),
                                in: RoundedRectangle(cornerRadius: AppTheme.chipRadius,
                                                     style: .continuous))
                Text(tool.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
            }
            .frame(width: 74, height: 62)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.photoTool.\(tool.rawValue)")
    }

    /// チップの点灯 = 無編集ではない（現在値がプリセット「なし」から動いている）。
    /// **テキスト・ステッカーは「1件でも置いてあるか」で点灯を決める**
    /// （個別の役割では判定しない。ボタンを分けたのは入口の見た目だけで、
    /// 状態としては 1 本の `photoEdit.texts` を共有するため）。
    private func isOn(_ tool: PhotoTool) -> Bool {
        switch tool {
        case .colorGrade: return !model.photoEdit.colorGrade.isIdentity
        case .crop: return !model.timeline.crop.isFull
        case .text, .sticker: return !model.photoEdit.texts.isEmpty
        case .rotate: return !model.photoEdit.orientation.isIdentity
        }
    }

    private func activate(_ tool: PhotoTool) {
        switch tool {
        case .colorGrade: showColorGradeSheet = true
        case .crop: model.enterDock(.crop)
        case .text, .sticker: showTextInputSheet = true
        case .rotate: showRotateBar.toggle()
        }
    }
}
