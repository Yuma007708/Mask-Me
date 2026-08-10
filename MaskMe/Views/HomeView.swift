import SwiftUI
import MosaicCore

/// Landing screen: two side-by-side entry buttons (写真 / 動画) on top,
/// the recent-items list below.
struct HomeView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var settingsStore: DetectionSettingsStore

    @State private var pickerFilter: MediaPicker.Filter?
    @State private var pickedMedia: PickedMedia?
    @State private var resumeContext: EditorView.ResumeContext?
    @State private var showEditor = false
    /// 取り込み失敗の文言（`MediaPicker` の `onFailure`）。ここには
    /// `MosaicEditorModel.errorMessage` が無いのでこの画面のアラートで伝える。
    @State private var pickerError: String?

    private var showPickerError: Binding<Bool> {
        Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })
    }

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
            // ここは**新規編集セッションの開始**なので 1 件のまま（既定値）。
            // 複数選択はタイムラインへの素材追加（VideoTimelineView）だけが使う。
            MediaPicker(filter: filter,
                        onFailure: { pickerError = $0 },
                        onPick: { picked in
                            pickerFilter = nil
                            guard let media = picked.first else { return }
                            pickedMedia = media
                            resumeContext = nil
                            showEditor = true
                        })
                .ignoresSafeArea()
        }
        .alert("読み込みに失敗しました", isPresented: showPickerError) {
            Button("OK", role: .cancel) { pickerError = nil }
        } message: {
            Text(pickerError ?? "")
        }
        .navigationDestination(isPresented: $showEditor) {
            if let pickedMedia {
                EditorView(media: pickedMedia, recents: recents, resume: resumeContext,
                           settings: settingsStore.settings)
            }
        }
        .onAppear { seedForUITestsIfNeeded() }
    }

    /// UI テスト起動時だけ、合成した動画で編集画面へ直行する（`UITestBootstrap` の doc）。
    /// 通常起動では `isSeedingVideo` が false なので何もしない。
    private func seedForUITestsIfNeeded() {
        guard UITestBootstrap.isSeedingVideo, pickedMedia == nil else { return }
        Task {
            guard let url = await UITestBootstrap.seedVideoURL() else { return }
            pickedMedia = .video(url)
            resumeContext = nil
            showEditor = true
        }
    }

    /// 動画の「編集中」下書きをタップしたら、元動画＋保存パラメータで再開する。
    /// v2 下書きはタイムライン（複数クリップ・rate・トランジション）も復元する。
    private func resume(_ draft: EditingDraft) {
        pickedMedia = .video(draftStore.sourceURL(for: draft))
        resumeContext = EditorView.ResumeContext(
            draftID: draft.id,
            faceMosaicOn: draft.faceMosaicOn,
            backgroundMosaicOn: draft.backgroundMosaicOn,
            faceBlockSize: draft.faceBlockSize,
            backgroundBlockSize: draft.backgroundBlockSize,
            objectMasks: draft.objectMasks,
            legacyManualRects: draft.legacyManualRects,
            timeline: draft.timeline.clips.isEmpty ? nil : draft.timeline,
            sourceURLs: draftStore.sourceURLs(for: draft),
            primarySourceID: draft.primarySource?.id
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
        case .videosAndImages: return 2
        }
    }
}
