import AVKit
import SwiftUI

#if canImport(Metal)

/// リアルタイムモザイク撮影画面。プレビューには常にモザイクが掛かった状態で表示され、
/// 保存されるのは焼き込み済みのメディアのみ（原本は残らない）。
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CameraViewModel

    init(captureSettings: CaptureSettings, detectionSettings: DetectionSettings) {
        _model = StateObject(wrappedValue: CameraViewModel(
            captureSettings: captureSettings, detectionSettings: detectionSettings))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.permission {
            case .checking:
                ProgressView().tint(.white)
            case .denied:
                permissionDeniedView
            case .granted:
                previewLayer
                controlsOverlay
            }
        }
        .statusBarHidden()
        .task { await model.start() }
        .onDisappear { model.stop() }
        // 撮影結果の確認プレビュー（保存 or 破棄するまで閉じない）
        .fullScreenCover(isPresented: showsConfirmation) {
            CaptureConfirmationView(model: model)
        }
        .alert("エラー", isPresented: showsError) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var showsConfirmation: Binding<Bool> {
        Binding(
            get: { model.pendingPhoto != nil || model.pendingVideoURL != nil },
            set: { if !$0 { model.discardPending() } }
        )
    }

    private var showsError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - プレビュー

    private var previewLayer: some View {
        GeometryReader { geo in
            ZStack {
                if let image = model.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        // フロントは表示だけ鏡像（保存は非鏡像 = iOS 標準）
                        .scaleEffect(x: model.isMirrored ? -1 : 1, y: 1)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location, in: geo.size)
            }
        }
    }

    /// タップ位置を「非ミラーのフレーム内正規化座標」へ変換して顔 ON/OFF を切り替える。
    /// aspect-fit の余白と、フロントカメラの表示鏡像を打ち消す。
    private func handleTap(at location: CGPoint, in viewSize: CGSize) {
        guard let image = model.previewImage, image.size.width > 0 else { return }
        let scale = min(viewSize.width / image.size.width,
                        viewSize.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (viewSize.width - drawn.width) / 2,
                             y: (viewSize.height - drawn.height) / 2)
        var normalized = CGPoint(x: (location.x - origin.x) / drawn.width,
                                 y: (location.y - origin.y) / drawn.height)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return }
        if model.isMirrored { normalized.x = 1 - normalized.x }
        model.toggleFace(atNormalized: normalized)
    }

    // MARK: - 操作 UI

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
            if !model.isRecording {
                blockSizeSlider
            }
            bottomBar
        }
        .padding()
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.4), in: Circle())
            }
            Spacer()
            if model.isRecording {
                recordingBadge
            } else if model.unmaskedCount > 0 {
                Text("モザイク OFF: \(model.unmaskedCount)人")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
            }
            Spacer()
            Button {
                model.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .disabled(model.isRecording)
            .opacity(model.isRecording ? 0.4 : 1)
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(timeString(model.recordingSeconds))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
    }

    private var blockSizeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3")
                .foregroundStyle(.white.opacity(0.8))
            Slider(value: $model.blockSize, in: 4...80)
            Image(systemName: "square.fill")
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.4), in: Capsule())
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if !model.isRecording {
                Picker("撮影モード", selection: $model.mode) {
                    ForEach(CameraViewModel.CaptureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Button {
                model.shutterTapped()
            } label: {
                shutterLabel
            }
            .disabled(model.isFinishingVideo)

            Text("タップした顔のモザイクを ON/OFF できます（映った人は自動で ON）")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var shutterLabel: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 74, height: 74)
            if model.mode == .video {
                RoundedRectangle(cornerRadius: model.isRecording ? 6 : 31)
                    .fill(.red)
                    .frame(width: model.isRecording ? 30 : 62,
                           height: model.isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.15), value: model.isRecording)
            } else {
                Circle().fill(.white).frame(width: 62, height: 62)
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text("カメラを利用できません")
                .font(.headline)
                .foregroundStyle(.white)
            Text("設定アプリで Mask Me のカメラへのアクセスを許可してください")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("閉じる") { dismiss() }
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(32)
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 撮影結果の確認プレビュー。保存 or 破棄を選ぶまで戻れない
/// （焼き込み済みメディアの取り扱いを明示的に確定させる）。
private struct CaptureConfirmationView: View {
    @ObservedObject var model: CameraViewModel
    @State private var isSaving = false
    @State private var savedFeedback = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                if let photo = model.pendingPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                } else if let url = model.pendingVideoURL {
                    VideoPlayer(player: AVPlayer(url: url))
                        .aspectRatio(9 / 16, contentMode: .fit)
                }
                Spacer()
                HStack(spacing: 40) {
                    Button {
                        model.discardPending()
                    } label: {
                        Label("破棄", systemImage: "trash")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.15), in: Capsule())
                    }
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                    }
                    .disabled(isSaving)
                }
                .padding(.bottom, 32)
            }
            if isSaving {
                ProgressView().tint(.white)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            if model.pendingPhoto != nil {
                await model.savePendingPhoto()
            } else {
                await model.savePendingVideo()
            }
            isSaving = false
        }
    }
}
#endif
