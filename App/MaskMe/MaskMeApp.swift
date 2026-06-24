import SwiftUI

@main
struct MaskMeApp: App {
    @StateObject private var recents = RecentItemsStore()
    @StateObject private var draftStore = DraftStore()
    @StateObject private var settingsStore = DetectionSettingsStore()
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
            .onAppear {
                // 強制終了なら写真下書きは破棄、通常の復帰なら保持（動画は常に保持）。
                draftStore.reconcile(photoSessionActive: photoEditingActive)
            }
        }
    }
}
