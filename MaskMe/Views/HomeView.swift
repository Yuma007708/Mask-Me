import SwiftUI
import MosaicCore

/// ホーム（作品置き場）。上に「＋ 新しく作る」、下に作品のグリッド。
///
/// ## 入口を 1 つにまとめてある
///
/// 旧 UI は「写真」「動画」の 2 ボタン＋タブバー中央のカメラで、**新規作成の入口が
/// 3 か所に散っていた**。押す前に種類を決めさせられるうえ、カメラだけ別の場所にある。
/// ここでは `＋ 新しく作る` の 1 つに集約し、押した後のシートで
/// 写真／動画／カメラを選ばせる（一般的な編集アプリと同じ形）。
///
/// カメラは `MainTabView` が `fullScreenCover` で出す。ホームからは
/// `onRequestCamera` を通じて依頼するだけで、**ここでカメラ画面を持たない**
/// （同じ画面を 2 か所から出すと、撮影後の戻り先が二重になる）。
struct HomeView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var settingsStore: DetectionSettingsStore

    /// タブバー側にカメラを開いてもらう（この画面は撮影を持たない）。
    var onRequestCamera: () -> Void = {}

    @State private var showCreateSheet = false
    @State private var pickerFilter: MediaPicker.Filter?
    @State private var pickedMedia: PickedMedia?
    @State private var resumeContext: EditorView.ResumeContext?
    @State private var showEditor = false
    /// 取り込み失敗の文言（`MediaPicker` の `onFailure`）。ここには
    /// `MosaicEditorModel.errorMessage` が無いのでこの画面のアラートで伝える。
    @State private var pickerError: String?

    /// 初回案内（`OnboardingSheet`）を見たか。**判定はこの 1 つだけ**で決める
    /// （素材の有無や下書きの状態を条件に足すと「消したはずの案内がまた出る」
    /// 経路が作れてしまう）。
    @AppStorage("didSeeOnboarding") private var didSeeOnboarding = false
    @State private var showOnboarding = false

    private var showPickerError: Binding<Bool> {
        Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })
    }

    var body: some View {
        VStack(spacing: 18) {
            createButton
                .padding(.horizontal, 16)
                .padding(.top, 10)

            RecentItemsView(onResumeDraft: resume(_:))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
        .navigationTitle("Mask Me")
        .confirmationDialog("新しく作る", isPresented: $showCreateSheet, titleVisibility: .visible) {
            Button("写真を選ぶ") { pickerFilter = .images }
            Button("動画を選ぶ") { pickerFilter = .videos }
            Button("カメラで撮る") { onRequestCamera() }
            Button("キャンセル", role: .cancel) {}
        }
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet()
        }
        .onAppear {
            seedForUITestsIfNeeded()
            showOnboardingIfNeeded()
        }
    }

    /// 初回だけ案内を出す。
    ///
    /// **UI テストでは出さない。** 種の動画で編集画面へ直行する経路
    /// （`UITestBootstrap.isSeedingVideo`）に案内が重なると、全 UI テストが
    /// 最初のシートで止まる。`@AppStorage` は Simulator に残るので
    /// 「1 回目だけ落ちる」という再現性の低い失敗になり、原因も分かりにくい。
    private func showOnboardingIfNeeded() {
        guard !didSeeOnboarding, !UITestBootstrap.isSeedingVideo else { return }
        didSeeOnboarding = true
        showOnboarding = true
    }

    private var createButton: some View {
        Button { showCreateSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("新しく作る")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(AppTheme.onAccent)
            .background(AppTheme.accent,
                        in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.create")
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

    /// 「編集中」の下書きをタップしたら、元の素材＋保存パラメータで再開する。
    ///
    /// **写真と動画で素材の取り出し方が違う。** 動画は `sourceURL(for:)` が
    /// 素材コピーの URL を返すが、写真は JPEG として保存してあるので画像として
    /// 読み直す（`PickedMedia.image` を作る）。読めなければ何もしない——
    /// ここで空の編集画面へ進むと、保存した瞬間に下書きが空で上書きされる。
    ///
    /// v2 の動画下書きはタイムライン（複数クリップ・rate・トランジション）も復元する。
    private func resume(_ draft: EditingDraft) {
        let context = EditorView.ResumeContext(
            draftID: draft.id,
            faceMosaicOn: draft.faceMosaicOn,
            objectMosaicOn: draft.objectMosaicOn,
            backgroundMosaicOn: draft.backgroundMosaicOn,
            faceBlockSize: draft.faceBlockSize,
            backgroundBlockSize: draft.backgroundBlockSize,
            objectMasks: draft.objectMasks,
            legacyManualRects: draft.legacyManualRects,
            timeline: draft.timeline.clips.isEmpty ? nil : draft.timeline,
            sourceURLs: draftStore.sourceURLs(for: draft),
            primarySourceID: draft.primarySource?.id
        )

        if draft.kind == .photo {
            let url = draftStore.sourceURL(for: draft)
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                pickerError = "編集中の写真を読み込めませんでした。"
                return
            }
            pickedMedia = .image(image)
        } else {
            pickedMedia = .video(draftStore.sourceURL(for: draft))
        }
        resumeContext = context
        showEditor = true
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
