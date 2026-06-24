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
                value: $store.settings.minSpan
            )
            DetectionSlider(
                label: "目の位置（下限）",
                tip: "顔の幅に対する目の間隔の比率の下限。横向きや斜め顔を検出したい場合は低くします。",
                value: $store.settings.eyeWidthRatioMin
            )
            DetectionSlider(
                label: "目の位置（上限）",
                tip: "顔の幅に対する目の間隔の比率の上限。通常は変更不要です。",
                value: $store.settings.eyeWidthRatioMax
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
            Slider(value: $value, in: 0...1)
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
                .presentationCompactAdaptation(.popover)
        }
    }
}
