import SwiftUI

@main
struct MaskMeApp: App {
    @StateObject private var recents = RecentItemsStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .environmentObject(recents)
        }
    }
}
