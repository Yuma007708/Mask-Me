import SwiftUI

@main
struct MaskMeApp: App {
    @StateObject private var recents = RecentItemsStore()
    @StateObject private var draftStore = DraftStore()
    @StateObject private var settingsStore = DetectionSettingsStore()
    @StateObject private var captureSettingsStore = CaptureSettingsStore()
    /// 写真編集の在席トークン。OS は強制終了時にこれを破棄するので、起動時に
    /// 「写真下書きが残っているのにトークンが無い＝強制終了」を判別できる。
    @SceneStorage("photoEditingActive") private var photoEditingActive = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MainTabView()
            }
            .environmentObject(recents)
            .environmentObject(draftStore)
            .environmentObject(settingsStore)
            .environmentObject(captureSettingsStore)
            .onAppear {
                // 強制終了なら写真下書きは破棄、通常の復帰なら保持（動画は常に保持）。
                draftStore.reconcile(photoSessionActive: photoEditingActive)
                // tmp の中間ファイル（picked-*/photoclip-*/mosaic-*）を age ベースで掃除する。
                // ディレクトリ列挙と削除は同期 IO なので、起動パスを塞がないよう
                // バックグラウンドへ逃がす（結果は UI に影響しない）。
                Task.detached(priority: .background) { TempMediaJanitor.sweep() }
            }
        }
    }
}
