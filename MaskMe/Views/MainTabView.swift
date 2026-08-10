import SwiftUI
import UIKit

/// アプリの根。下段のタブで「作品／撮る／設定」を切り替える。
///
/// ## 名前を実態に合わせてある
///
/// 旧 UI のタブは「編集／設定」で、中央にカメラの丸ボタンが浮いていた。だが
/// 「編集」タブが実際に見せていたのは**作品置き場**（下書きと書き出し済みの一覧）で、
/// 編集画面はそこから遷移した先にある。名前と中身が食い違うと、戻ってきたときに
/// 「編集を押したのに編集画面が出ない」と読める。
///
/// ## カメラはここが持つ
///
/// 撮影は `fullScreenCover` で全面に出す。**`HomeView` からもカメラを開けるが、
/// 画面を持つのはここ 1 箇所だけ**（`onRequestCamera` で依頼を受ける）。
/// 2 か所から出すと、撮影後の戻り先が二重になる。
struct MainTabView: View {
    @State private var selectedTab: Tab = .library
    @State private var showsCamera = false
    @EnvironmentObject private var detectionStore: DetectionSettingsStore
    @EnvironmentObject private var captureStore: CaptureSettingsStore

    enum Tab { case library, settings }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .library:  HomeView(onRequestCamera: { showsCamera = true })
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AppTabBar(selected: $selectedTab, cameraTapped: { showsCamera = true })
        }
        .background(AppTheme.background)
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
            tabButton(icon: "square.stack", label: "作品", tab: .library)

            // リアルタイムモザイク撮影（中央・大きめ）。ここは「作品／設定」と
            // 並ぶタブではなく**その場で始める操作**なので、選択状態を持たない。
            Button(action: cameraTapped) {
                VStack(spacing: 3) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.onAccent)
                        .frame(width: 50, height: 50)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                        .shadow(color: AppTheme.accent.opacity(0.45), radius: 8, y: 3)
                    Text("撮る")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.inkDim)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("tab.camera")

            tabButton(icon: "gearshape", label: "設定", tab: .settings)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            AppTheme.surfaceDim
                .overlay(alignment: .top) { AppTheme.line.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
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
                    .font(.system(size: 21))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.inkDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("tab.\(label)")
    }
}
