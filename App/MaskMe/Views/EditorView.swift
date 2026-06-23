import SwiftUI

/// The editing screen: live mosaic preview with a tracking badge on top,
/// the mosaic controls below, and a save / export action in the toolbar.
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
            bottomSheet
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
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    // MARK: - Bottom sheet

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(uiColor: .systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)
            faceToggle
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            Divider()
                .padding(.horizontal, 18)
            sliders
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Face toggle

    private var faceToggle: some View {
        Toggle("顔をモザイク", isOn: $model.faceEnabled.animation(.easeInOut(duration: 0.2)))
            .font(.subheadline.weight(.medium))
    }

    // MARK: - Sliders

    private var sliders: some View {
        VStack(spacing: 0) {
            sliderRow("粗さ", value: $model.blockSize, range: 4...80)
            sliderRow("ふち", value: $model.edgeSoftness, range: 0.05...1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
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
        .overlay(alignment: .bottom) {
            Divider()
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
