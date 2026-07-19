import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab: Tab = .edit
    @State private var showsCamera = false
    @EnvironmentObject private var detectionStore: DetectionSettingsStore
    @EnvironmentObject private var captureStore: CaptureSettingsStore

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
            AppTabBar(selected: $selectedTab, cameraTapped: { showsCamera = true })
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraView(captureSettings: captureStore.settings,
                       detectionSettings: detectionStore.settings)
        }
    }
}

private struct AppTabBar: View {
    @Binding var selected: MainTabView.Tab
    let cameraTapped: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tabButton(icon: "square.and.pencil", label: "編集", tab: .edit)

            // リアルタイムモザイク撮影（中央・大きめ）
            Button(action: cameraTapped) {
                Image(systemName: "camera.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)
            }
            .frame(maxWidth: .infinity)

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
        // 一部のシンボル（例: square.and.pencil）には .fill 版が存在しないため、
        // 実在するときだけ .fill に切り替える。存在しない名前を渡すと赤ログが出る。
        let filled = icon + ".fill"
        let symbolName = (isSelected && UIImage(systemName: filled) != nil) ? filled : icon
        Button {
            selected = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbolName)
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
