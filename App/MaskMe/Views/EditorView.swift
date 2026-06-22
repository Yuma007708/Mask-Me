import SwiftUI

/// The editing screen: live mosaic preview with a tracking badge on top, the
/// mosaic controls below, and a save / export action in the toolbar.
struct EditorView: View {
    let media: PickedMedia
    @StateObject private var model: MosaicEditorModel

    init(media: PickedMedia, recents: RecentItemsStore) {
        self.media = media
        let mode: MosaicEditorModel.Mode
        if case .video = media {
            mode = .video
        } else {
            mode = .photo
        }
        _model = StateObject(wrappedValue: MosaicEditorModel(mode: mode, recents: recents))
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            controls
        }
        .navigationTitle(model.mode == .photo ? "写真編集" : "動画編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { loadMedia() }
        .overlay { exportOverlay }
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

    private var preview: some View {
        ZStack {
            Color.black
            if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if model.isLoading {
                ProgressView()
                    .tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    TrackingBadge(status: model.status)
                        .padding(12)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section("モザイクの粗さ") {
                slider("顔", value: $model.faceBlock, range: 4...60)
                slider("目元", value: $model.eyeBlock, range: 2...30)
                slider("口元", value: $model.mouthBlock, range: 2...30)
                slider("ふち", value: $model.edgeSoftness, range: 0.05...1)
            }
            Section("対象") {
                Toggle("顔全体", isOn: $model.faceEnabled)
                Toggle("目元", isOn: $model.eyesEnabled)
                Toggle("口元", isOn: $model.mouthEnabled)
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
            Slider(value: value, in: range)
        }
    }

    // MARK: - Toolbar / overlay

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("エクスポート中… \(Int(progress * 100))%")
                        .font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Actions

    private func loadMedia() {
        switch media {
        case .image(let image):
            model.load(image: image)
        case .video(let url):
            model.load(videoURL: url)
        }
    }

    private func runAction() async {
        switch model.mode {
        case .photo:
            await model.savePhoto()
        case .video:
            await model.exportVideo()
        }
    }
}
