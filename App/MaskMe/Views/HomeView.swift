import SwiftUI

/// Landing screen: two side-by-side entry buttons (写真 / 動画) on top,
/// the recent-items list below.
struct HomeView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @EnvironmentObject private var draftStore: DraftStore

    @State private var pickerFilter: MediaPicker.Filter?
    @State private var pickedMedia: PickedMedia?
    @State private var resumeContext: EditorView.ResumeContext?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                mediaButton(title: "写真", systemImage: "photo", isPrimary: false) {
                    pickerFilter = .images
                }
                mediaButton(title: "動画", systemImage: "video", isPrimary: true) {
                    pickerFilter = .videos
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            RecentItemsView(onResumeDraft: resume(_:))
        }
        .navigationTitle("Mask Me")
        .sheet(item: $pickerFilter) { filter in
            MediaPicker(filter: filter) { media in
                pickerFilter = nil
                pickedMedia = media
                resumeContext = nil
                showEditor = true
            }
            .ignoresSafeArea()
        }
        .navigationDestination(isPresented: $showEditor) {
            if let pickedMedia {
                EditorView(media: pickedMedia, recents: recents, resume: resumeContext)
            }
        }
    }

    /// 動画の「編集中」下書きをタップしたら、元動画＋保存パラメータで再開する。
    private func resume(_ draft: EditingDraft) {
        pickedMedia = .video(draftStore.sourceURL(for: draft))
        resumeContext = EditorView.ResumeContext(
            draftID: draft.id,
            faceMosaicOn: draft.faceMosaicOn,
            backgroundMosaicOn: draft.backgroundMosaicOn,
            faceBlockSize: draft.faceBlockSize,
            backgroundBlockSize: draft.backgroundBlockSize,
            manualRects: draft.manualRects
        )
        showEditor = true
    }

    private func mediaButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(.white)
                .background(
                    isPrimary ? Color.accentColor : Color(uiColor: .systemGray5),
                    in: RoundedRectangle(cornerRadius: 13)
                )
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
