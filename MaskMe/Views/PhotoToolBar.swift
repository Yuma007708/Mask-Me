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
        // **`face.smiling` は使わない。** 同じ段に並ぶ「顔」（モザイクを掛ける
        // 対象）が同じ絵で、色だけ違う状態になっていた。意味の違う 2 つが同じ絵だと
        // 色分けの効果が消える。
        case .sticker: return "sparkles"
        case .rotate: return "rotate.left"
        }
    }
}

/// 写真ドックのチップ 1 個ぶんの見た目。
///
/// **モザイクの対象（`EffectTabBar.tabButton`）と加工の道具（`PhotoToolButton`）で
/// 共有する。** 同じ段に並ぶ以上、大きさ・文字・色の載せ方が少しでも違うと
/// 段が揃って見えない。見た目を変えるならここ 1 か所を変える。
///
/// **色は絵だけに載せ、文字は白のまま**（動画側 `TimelineToolbarView.button` と
/// 同じ流儀。両方を色にすると読みにくくなる）。`isActive` のときは絵の背景を
/// 濃くして「触ってある／ON である」ことを示す。
struct PhotoDockChip: View {
    let symbolName: String
    let title: String
    let accent: Color
    let isActive: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 38, height: 32)
                .background(accent.opacity(isActive ? 0.34 : 0.16),
                            in: RoundedRectangle(cornerRadius: AppTheme.chipRadius,
                                                 style: .continuous))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.ink)
        }
        .frame(width: 74, height: 62)
    }
}

/// 加工の道具 1 個ぶんのボタン。並べるのは `EffectTabBar`（写真ドックの唯一の段）。
///
/// 押した結果（シートを開く・段を降りる・帯を出す）は呼び出し側が持つ。
/// ここは見た目と識別子だけを受け持つ。
struct PhotoToolButton: View {
    let tool: PhotoTool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PhotoDockChip(symbolName: tool.symbolName, title: tool.title,
                          accent: tool.accent, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.photoTool.\(tool.rawValue)")
    }
}
