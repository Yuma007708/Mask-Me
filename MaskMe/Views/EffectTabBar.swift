import SwiftUI

/// 横スクロール可能なカスタムタブバー（顔／背景）。
/// タブ自体がトグル：タップで選択＋効果ON、選択中タブの再タップで効果OFF。
/// はっきりした境目は設けず、下部ドックにシームレスに収める。
struct EffectTabBar: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // **この段が上の道具列と別物であることを一言で示す。**
            // 上は「押すと何かが開く道具」、ここは「押すと効果が ON/OFF に切り替わる
            // トグル」で性質が違うのに、見た目が同じアイコン列なので区別が付かなかった。
            Text("モザイクを掛ける対象")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.inkDim)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MosaicEditorModel.EffectTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    /// 見た目の文法は写真の道具列（`PhotoToolBar`）・動画のツールバーと揃える:
    /// **色は絵だけに載せ、文字は白のまま。** 色はモザイクの道具なので
    /// `AppTheme.ToolAccent.mask`（`AppTheme` の doc: 道具の色の表は 1 つ）。
    /// ON のときだけ絵の背景を濃くして、トグルの状態を色の濃さで示す。
    private func tabButton(_ tab: MosaicEditorModel.EffectTab) -> some View {
        let isActive = model.activeTab == tab
        return Button {
            model.tapTab(tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol(for: tab))
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(AppTheme.ToolAccent.mask)
                    .frame(width: 38, height: 32)
                    .background(AppTheme.ToolAccent.mask.opacity(isActive ? 0.34 : 0.16),
                                in: RoundedRectangle(cornerRadius: AppTheme.chipRadius,
                                                     style: .continuous))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
            }
            .frame(width: 74, height: 62)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.effectTab.\(tab.rawValue)")
    }

    private func symbol(for tab: MosaicEditorModel.EffectTab) -> String {
        EffectTabSymbol.name(for: tab)
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
