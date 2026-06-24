import SwiftUI

/// 横スクロール可能なカスタムタブバー（顔／背景、今後拡張）。
/// タブ自体がトグル：タップで選択＋効果ON、選択中タブの再タップで効果OFF。
/// はっきりした境目は設けず、下部ドックにシームレスに収める。
struct EffectTabBar: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MosaicEditorModel.EffectTab.allCases) { tab in
                    tabButton(tab)
                }
                futurePlaceholder
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private func tabButton(_ tab: MosaicEditorModel.EffectTab) -> some View {
        let isActive = model.activeTab == tab
        return Button {
            model.tapTab(tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol(for: tab))
                    .font(.system(size: 20, weight: .regular))
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(width: 74, height: 60)
            .foregroundStyle(isActive ? Color.white : Color(uiColor: .secondaryLabel))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var futurePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
            Text("追加予定")
                .font(.system(size: 11.5, weight: .medium))
        }
        .frame(width: 62, height: 60)
        .foregroundStyle(Color(uiColor: .tertiaryLabel))
    }

    private func symbol(for tab: MosaicEditorModel.EffectTab) -> String {
        switch tab {
        case .face: return "face.smiling"
        case .background: return "photo"
        }
    }
}
