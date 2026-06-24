import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .edit

    enum Tab { case edit, settings }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .edit:     HomeView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            AppTabBar(selected: $selectedTab)
        }
    }
}

private struct AppTabBar: View {
    @Binding var selected: MainTabView.Tab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(icon: "square.and.pencil", label: "編集", tab: .edit)

            // カメラボタン（中央・大きめ・未実装）
            Button(action: {}) {
                Image(systemName: "camera.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)   // 未実装

            tabButton(icon: "gearshape", label: "設定", tab: .settings)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func tabButton(icon: String, label: String, tab: MainTabView.Tab) -> some View {
        let isSelected = selected == tab
        Button {
            selected = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? icon + ".fill" : icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
