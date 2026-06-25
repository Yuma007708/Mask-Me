import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DetectionSettingsStore

    var body: some View {
        NavigationStack {
            Form {
                presetsSection
                parametersSection
                resetSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - プリセット

    private var presetsSection: some View {
        Section("プリセット") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DetectionSettings.presets, id: \.id) { preset in
                        let isSelected = store.settings.matchingPresetID == preset.id
                        Button {
                            store.settings = preset.settings
                        } label: {
                            Text(preset.name)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                    ? Color.accentColor
                                    : Color(.secondarySystemGroupedBackground)
                                )
                                .foregroundStyle(isSelected ? .white : .primary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(
                                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    if store.settings.matchingPresetID == nil {
                        Text("カスタム")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Text("設定はメディアを開くときに適用されます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - パラメーター

    private var parametersSection: some View {
        Section("検出パラメーター") {
            DetectionSlider(
                label: "検出感度",
                tip: "顔として検出するための信頼度のしきい値。低いほど暗所や小さな顔も拾えますが、誤検出が増えます。",
                value: Binding(
                    get: { Double(store.settings.minFaceDetectionConfidence) },
                    set: { store.settings.minFaceDetectionConfidence = Float($0) }
                )
            )
            DetectionSlider(
                label: "存在確信度",
                tip: "顔がフレーム内に存在すると判断するしきい値。動画で顔が一時的に隠れたときの再検出感度に影響します。",
                value: Binding(
                    get: { Double(store.settings.minFacePresenceConfidence) },
                    set: { store.settings.minFacePresenceConfidence = Float($0) }
                )
            )
            DetectionSlider(
                label: "追跡確信度",
                tip: "動画で前のフレームから顔を追い続ける感度。低いほど動きが速くても追跡しやすくなります。",
                value: Binding(
                    get: { Double(store.settings.minTrackingConfidence) },
                    set: { store.settings.minTrackingConfidence = Float($0) }
                )
            )
            DetectionSlider(
                label: "最小顔サイズ",
                tip: "検出対象とする顔の最小サイズ（画像の幅または高さに対する割合）。遠くの小さな顔を拾うには低くします。",
                value: $store.settings.minSpan,
                range: 0...1
            )

            // 最大検出数（Stepper）
            HStack {
                Label("最大検出数", systemImage: "person.2")
                    .layoutPriority(1)
                Spacer()
                TipButton(text: "1フレームで同時に検出する顔の最大数。増やすと処理が重くなります。")
                Spacer()
                Stepper("\(store.settings.numFaces) 人",
                        value: $store.settings.numFaces, in: 1...Int.max)
                    .fixedSize()
            }

            // 補助顔検出器のバックエンド選択（実機専用）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("補助検出器", systemImage: "wand.and.stars")
                        .layoutPriority(1)
                    Spacer()
                    TipButton(text: "MediaPipe が取り逃した顔を別の検出器で見つけ、その領域を MediaPipe で再検出して補完します。Apple Vision は実機専用、Face Detector (BlazeFace) と YuNet (OpenCV) はシミュレータでも動作。「全部」は 3 つを並走させて検出率最大、処理時間も最大（約 3 倍）。")
                }
                Picker("", selection: $store.settings.faceDetectorBackend) {
                    Text("使わない").tag(FaceDetectorBackend.off)
                    Text("Vision").tag(FaceDetectorBackend.vision)
                    Text("Face Det.").tag(FaceDetectorBackend.faceDetector)
                    Text("YuNet").tag(FaceDetectorBackend.yunet)
                    Text("全部").tag(FaceDetectorBackend.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - リセット

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                store.settings = DetectionSettings()
            } label: {
                Label("標準設定に戻す", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

// MARK: - サブビュー

private struct DetectionSlider: View {
    let label: String
    let tip: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.01...1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: "slider.horizontal.3")
                    .layoutPriority(1)
                Spacer()
                TipButton(text: tip)
                Text("\(Int(value * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            Slider(value: $value, in: range)
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
    }
}

private struct TipButton: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button {
            show = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .top) {
            Text(text)
                .font(.footnote)
                .padding(12)
                .frame(maxWidth: 260)
                .modifier(CompactPopoverModifier())
        }
    }
}

/// iOS 16.4 以降ではポップオーバーをコンパクト表示（吹き出し）にする。
/// それ以前では popover が自動的に sheet になる。
private struct CompactPopoverModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }
}
