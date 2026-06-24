import SwiftUI

/// 編集画面：プレビュー（上）/ 調整バー（中・タブ選択でスライド表示）/
/// カスタムタブバー（下）の3段構成。
struct EditorView: View {
    let media: PickedMedia
    /// 再開する下書きのパラメータ（新規編集なら nil）。
    private let resume: ResumeContext?

    @StateObject private var model: MosaicEditorModel
    @EnvironmentObject private var draftStore: DraftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// 写真編集中フラグ。OS は強制終了時にこれを破棄するため、写真下書きの
    /// 「強制終了で破棄／復帰では保持」の判別に使う。
    @SceneStorage("photoEditingActive") private var photoEditingActive = false

    @State private var showDiscardConfirm = false
    /// 動画下書きの更新先 ID（同一セッションは上書き保存）。
    @State private var videoDraftID: UUID?

    struct ResumeContext {
        let draftID: UUID
        let faceMosaicOn: Bool
        let backgroundMosaicOn: Bool
        let faceBlockSize: Float
        let backgroundBlockSize: Float
        let manualRects: [CGRect]
    }

    init(media: PickedMedia, recents: RecentItemsStore, resume: ResumeContext? = nil,
         settings: DetectionSettings = DetectionSettings()) {
        self.media = media
        self.resume = resume
        let mode: MosaicEditorModel.Mode = {
            if case .video = media { return .video }
            return .photo
        }()
        _model = StateObject(wrappedValue: MosaicEditorModel(mode: mode, recents: recents, settings: settings))
        _videoDraftID = State(initialValue: resume?.draftID)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            if model.mode == .video {
                VideoControlsView(model: model)
            }
            dock
        }
        .navigationTitle(model.mode == .photo ? "写真編集" : "動画編集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { loadMedia() }
        .overlay { exportOverlay }
        .onAppear {
            if model.mode == .photo { photoEditingActive = true }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { persistDraft() }
        }
        .confirmationDialog(
            "編集を破棄して戻りますか？",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("破棄して戻る", role: .destructive) {
                draftStore.deletePhotoDraft()
                photoEditingActive = false
                dismiss()
            }
            Button("編集を続ける", role: .cancel) {}
        }
        .alert("保存しました", isPresented: $model.didSave) {
            Button("OK", role: .cancel) {}
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black

            if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if model.isLoading {
                ProgressView().tint(.white)
            }

            RectangleDrawingOverlay(model: model)

            if model.mode == .video {
                VStack {
                    HStack {
                        Spacer()
                        TrackingBadge(status: model.status)
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
    }

    // MARK: - Dock（下段：顔サムネ / 調整バー / タブバー）

    private var dock: some View {
        VStack(spacing: 0) {
            // 顔タブ選択時のみ、対象の顔サムネイル列を表示。
            if model.activeTab == .face {
                FaceSelectorView(model: model)
                    .transition(.opacity)
            }

            // 調整バー：タブ選択中だけ下からスライドして表示。
            if model.activeTab != nil {
                adjustmentBar
                    .transition(.move(edge: .bottom))
            }

            EffectTabBar(model: model)
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .clipped()
        .animation(.easeOut(duration: 0.25), value: model.activeTab)
    }

    private var adjustmentBar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.35)

            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.35)

            Text("粗さ")
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .secondaryLabel))

            Slider(
                value: Binding(get: { model.activeBlockSize }, set: { model.activeBlockSize = $0 }),
                in: 4...80
            )

            Button { model.confirmAdjustment() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                handleBack()
            } label: {
                Label("戻る", systemImage: "chevron.backward")
            }
            .disabled(model.exportProgress != nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(model.mode == .photo ? "保存" : "エクスポート") {
                Task { await runAction() }
            }
            .disabled(model.previewImage == nil || model.exportProgress != nil)
        }
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if let progress = model.exportProgress {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView(value: progress).frame(width: 200)
                    Text("エクスポート中… \(Int(progress * 100))%").font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Actions

    private func loadMedia() {
        switch media {
        case .image(let image): model.load(image: image)
        case .video(let url): model.load(videoURL: url)
        }
        if let resume {
            model.applyRestoredParameters(
                faceMosaicOn: resume.faceMosaicOn,
                backgroundMosaicOn: resume.backgroundMosaicOn,
                faceBlockSize: resume.faceBlockSize,
                backgroundBlockSize: resume.backgroundBlockSize,
                manualRects: resume.manualRects
            )
        }
    }

    private func runAction() async {
        switch model.mode {
        case .photo:
            await model.savePhoto()
            if model.didSave {
                draftStore.deletePhotoDraft()
                photoEditingActive = false
            }
        case .video:
            await model.exportVideo()
            if model.didSave, let id = videoDraftID {
                if let draft = draftStore.videoDrafts.first(where: { $0.id == id }) {
                    draftStore.removeVideoDraft(draft)
                }
                videoDraftID = nil
            }
        }
    }

    // MARK: - 戻る・状態保持

    private func handleBack() {
        switch model.mode {
        case .photo:
            showDiscardConfirm = true
        case .video:
            persistDraft()
            dismiss()
        }
    }

    private func persistDraft() {
        switch model.mode {
        case .photo:
            guard let image = model.photoSourceImage else { return }
            draftStore.savePhotoDraft(
                existing: nil,
                image: image,
                faceMosaicOn: model.faceMosaicOn,
                backgroundMosaicOn: model.backgroundMosaicOn,
                faceBlockSize: model.faceBlockSize,
                backgroundBlockSize: model.backgroundBlockSize,
                manualRects: model.manualRects
            )
            photoEditingActive = true
        case .video:
            guard let sourceURL = model.sourceVideoURL else { return }
            let draft = draftStore.saveVideoDraft(
                existing: videoDraftID,
                sourceURL: sourceURL,
                faceMosaicOn: model.faceMosaicOn,
                backgroundMosaicOn: model.backgroundMosaicOn,
                faceBlockSize: model.faceBlockSize,
                backgroundBlockSize: model.backgroundBlockSize,
                manualRects: model.manualRects,
                thumbnail: model.previewImage
            )
            videoDraftID = draft?.id
        }
    }
}
