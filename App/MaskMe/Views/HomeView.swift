import SwiftUI

/// Landing screen: two side-by-side entry buttons (写真編集 / 動画編集) on top,
/// the recent-items list below.
struct HomeView: View {
    @EnvironmentObject private var recents: RecentItemsStore

    @State private var pickerFilter: MediaPicker.Filter?
    @State private var pickedMedia: PickedMedia?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                entryCard(
                    title: "写真編集",
                    systemImage: "photo",
                    tint: .blue
                ) { pickerFilter = .images }

                entryCard(
                    title: "動画編集",
                    systemImage: "video",
                    tint: .purple
                ) { pickerFilter = .videos }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            RecentItemsView()
        }
        .navigationTitle("Mask Me")
        .sheet(item: $pickerFilter) { filter in
            MediaPicker(filter: filter) { media in
                pickerFilter = nil
                pickedMedia = media
                showEditor = true
            }
            .ignoresSafeArea()
        }
        .navigationDestination(isPresented: $showEditor) {
            if let pickedMedia {
                EditorView(media: pickedMedia, recents: recents)
            }
        }
    }

    private func entryCard(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .semibold))
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .foregroundStyle(.white)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

// Lets `MediaPicker.Filter` drive a `.sheet(item:)`.
extension MediaPicker.Filter: Identifiable {
    var id: Int {
        switch self {
        case .images: return 0
        case .videos: return 1
        }
    }
}
