import SwiftUI

/// 編集画面：プレビュー + 顔選択 + コントロール + 保存/エクスポート。
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
        let blockSize: Float
        let faceEnabled: Bool
        let manualRects: [CGRect]
    }

    init(media: PickedMedia, recents: RecentItemsStore, resume: ResumeContext? = nil) {
        self.media = media
        self.resume = resume
        let mode: MosaicEditorModel.Mode = {
            if case .video = media { return .video }
            return .photo
        }()
        _model = StateObject(wrappedValue: MosaicEditorModel(mode: mode, recents: recents))
        _videoDraftID = State(initialValue: resume?.draftID)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            if model.mode == .video {
                VideoControlsView(model: model)
            }
            bottomSheet
        }
        .navigationTitle(model.mode == .photo ? "写真編集" : "動画編集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { loadMedia() }
        .overlay { exportOverlay }
        .onAppear {
            // 写真は「強制終了で破棄／復帰では保持」を判別するための在席トークン。
            if model.mode == .photo { photoEditingActive = true }
        }
        .onChange(of: scenePhase) { phase in
            // アプリを離れた時は写真・動画とも編集中の状態を保持（下書き保存）。
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

            // 矩形描画オーバーレイ（常時有効）
            RectangleDrawingOverlay(model: model)

            // 動画: 追従バッジ
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

    // MARK: - Bottom sheet

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(uiColor: .systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // 顔サムネイル選択
            FaceSelectorView(model: model)
            Divider().padding(.horizontal, 16)

            // 顔モザイク ON/OFF
            Toggle("顔をモザイク", isOn: $model.faceEnabled.animation())
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            Divider().padding(.horizontal, 18)

            // 粗さスライダー
            sliderRow("粗さ", value: $model.blockSize, range: 4...80)
                .padding(.horizontal, 18)

            // 矩形追加ボタン
            HStack {
                Label("画面をドラッグして矩形を追加", systemImage: "rectangle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.manualRegions.isEmpty {
                    Button("クリア") {
                        withAnimation { model.manualRegions.removeAll() }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(width: 36, alignment: .leading)
            Slider(value: value, in: range)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
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
        // 下書きから再開した場合はパラメータ（粗さ・顔ON/OFF・手動矩形）を復元。
        if let resume {
            model.applyRestoredParameters(
                blockSize: resume.blockSize,
                faceEnabled: resume.faceEnabled,
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
                // エクスポート完了で下書きは不要に。
                if let draft = draftStore.videoDrafts.first(where: { $0.id == id }) {
                    draftStore.removeVideoDraft(draft)
                }
                videoDraftID = nil
            }
        }
    }

    // MARK: - 戻る・状態保持

    /// 戻るボタン：写真は破棄確認、動画は下書き保存して戻る。
    private func handleBack() {
        switch model.mode {
        case .photo:
            showDiscardConfirm = true
        case .video:
            persistDraft()
            dismiss()
        }
    }

    /// 編集中の状態を下書きとして保存する（離脱時・動画の戻る時に共通利用）。
    private func persistDraft() {
        switch model.mode {
        case .photo:
            guard let image = model.photoSourceImage else { return }
            draftStore.savePhotoDraft(
                existing: nil,
                image: image,
                blockSize: model.blockSize,
                faceEnabled: model.faceEnabled,
                manualRects: model.manualRects
            )
            photoEditingActive = true
        case .video:
            guard let sourceURL = model.sourceVideoURL else { return }
            let draft = draftStore.saveVideoDraft(
                existing: videoDraftID,
                sourceURL: sourceURL,
                blockSize: model.blockSize,
                faceEnabled: model.faceEnabled,
                manualRects: model.manualRects,
                thumbnail: model.previewImage
            )
            videoDraftID = draft?.id
        }
    }
}
