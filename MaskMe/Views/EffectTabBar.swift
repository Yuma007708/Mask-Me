import SwiftUI

/// 写真モードの道具の段。**1 段だけで、横スクロールする。**
///
/// ## なぜ 1 段か
///
/// 以前は「モザイクの対象（顔／背景）」と「加工の道具（フィルター・切り抜き・
/// テキスト・ステッカー・回転）」を上下 2 段に分けていた。段が 2 つあると
/// プレビューの高さがそのぶん削られ、道具を探すのに縦方向も見ることになる。
/// 動画モードは既に 1 段（`TimelineToolbarView`）なので、**モードをまたいで
/// 道具の探し方を 1 つに揃える**意味もある。
///
/// 性質の違い（対象＝ON/OFF のトグル、道具＝押すと何かが開く）は、見出しの代わりに
/// **並びと色と仕切り線**で示す: 先頭にモザイクの対象を青で置き、細い縦線を挟んで
/// 加工の道具を役割の色で並べる。色の表は `AppTheme.ToolAccent`（道具の色の表は
/// アプリ全体で 1 つ。`AppTheme` の doc 参照）。
///
/// 型名を `EffectTabBar` のままにしてあるのは、写真ドックの組み立て
/// （`EditorView.photoDock`）から見た役割が変わっていないため。
struct EffectTabBar: View {
    @ObservedObject var model: MosaicEditorModel
    @Binding var showColorGradeSheet: Bool
    @Binding var showTextInputSheet: Bool
    @Binding var showRotateBar: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MosaicEditorModel.EffectTab.allCases) { tab in
                    tabButton(tab)
                }
                divider
                ForEach(PhotoTool.allCases) { tool in
                    PhotoToolButton(tool: tool, isActive: isOn(tool)) { activate(tool) }
                }
            }
            .padding(.horizontal, 14)
        }
        // 段そのものに識別子を付ける。**UI テストが「右端の道具まで手が届くか」を
        // 確かめるために、この段を掴んで払う必要がある**（1 段に集約した結果、
        // 画面幅に収まらない道具が出る。それが横スクロールの前提）。
        .accessibilityIdentifier("editor.photoDock")
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    /// 対象と道具の境目。**見出しの代わり**なので、押せる物と紛れない細さにする。
    private var divider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(AppTheme.line)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    /// 見た目の文法は加工の道具（`PhotoToolButton`）・動画のツールバーと揃える:
    /// **色は絵だけに載せ、文字は白のまま。** 色はモザイクの道具なので
    /// `AppTheme.ToolAccent.mask`。ON のときだけ絵の背景を濃くして、
    /// トグルの状態を色の濃さで示す。
    private func tabButton(_ tab: MosaicEditorModel.EffectTab) -> some View {
        let isActive = model.activeTab == tab
        return Button {
            model.tapTab(tab)
        } label: {
            PhotoDockChip(symbolName: EffectTabSymbol.name(for: tab),
                          title: tab.title,
                          accent: AppTheme.ToolAccent.mask,
                          isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.effectTab.\(tab.rawValue)")
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

/// 効果タブのアイコン名（写真モードの `EffectTabBar` と動画モードの
/// `EditorDockView` で同じ絵を使うための共有）。
enum EffectTabSymbol {
    static func name(for tab: MosaicEditorModel.EffectTab) -> String {
        switch tab {
        case .face: return "face.smiling"
        case .background: return "photo"
        }
    }
}
