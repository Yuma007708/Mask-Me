import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DetectionSettingsStore
    @EnvironmentObject private var captureStore: CaptureSettingsStore
    /// 端末カメラの対応組み合わせ（非対応の解像度 × fps は選択肢に出さない）。
    private let supportedCaptureCombinations = CaptureCapabilities.supportedCombinations()

    /// Pro の状態。`Entitlements.shared` は読み取り専用なので、変化は publisher で受ける。
    @State private var isPro = Entitlements.shared.isPro
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                proSection
                presetsSection
                captureSection
                parametersSection
                resetSection
            }
            .appSheetBackground()
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
            .onReceive(Entitlements.shared.isProPublisher) { isPro = $0 }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    // MARK: - Pro

    /// **購入画面への常設の導線。** 制限に当たったときのアラートだけを入口にすると、
    /// 「一度断ったらもう買えない」状態になる。加えて `PaywallView` には購入の復元が
    /// あるので、機種変更したユーザーがここから辿れる必要がある（復元手段が
    /// 見つからないのは App Store のリジェクト理由）。
    private var proSection: some View {
        Section {
            Button {
                showPaywall = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isPro ? "Mask Me Pro をご利用中" : "Mask Me Pro")
                            .font(.headline)
                        Text(isPro
                             ? "透かしなし・制限なしで書き出せます。"
                             : "透かしなし・長さと画質の制限なしで書き出せます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isPro ? "checkmark.seal.fill" : "chevron.right")
                        .foregroundStyle(isPro ? AppTheme.accent : .secondary)
                }
            }
            .accessibilityIdentifier("settings.pro")
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

    // MARK: - 撮影画質

    /// 対応している解像度と、選択中の解像度で対応している fps だけを出す。
    private var captureSection: some View {
        Section("撮影画質") {
            let resolutions = CaptureResolution.allCases.filter { res in
                supportedCaptureCombinations.contains { $0.resolution == res }
            }
            Picker("解像度", selection: $captureStore.settings.resolution) {
                ForEach(resolutions) { res in
                    Text(res.label).tag(res)
                }
            }
            let frameRates = supportedCaptureCombinations
                .filter { $0.resolution == captureStore.settings.resolution }
                .map(\.fps)
            Picker("フレームレート", selection: $captureStore.settings.fps) {
                ForEach(frameRates, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
            .onChange(of: captureStore.settings.resolution) { newValue in
                // 解像度変更で fps が非対応になったら対応値へ丸める
                let rates = supportedCaptureCombinations
                    .filter { $0.resolution == newValue }.map(\.fps)
                if !rates.contains(captureStore.settings.fps), let first = rates.first {
                    captureStore.settings.fps = first
                }
            }
            Text("アプリ内カメラ（リアルタイムモザイク撮影）の画質です。高いほど発熱・電池消費が増えます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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

            // 補助顔検出器の選択。FaceDetector と YuNet の個別トグル（デフォルト両方 ON）。
            // 検出精度は無料でも全力（課金方針）なので、ここは Pro 権限で施錠しない。
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("補助検出器", systemImage: "wand.and.stars")
                        .layoutPriority(1)
                    Spacer()
                    TipButton(text: "MediaPipe が取り逃した顔を別の検出器で見つけ、その領域を MediaPipe で再検出して補完します。OFF にすると処理は軽くなりますが検出率が下がります。")
                }
                AuxDetectorToggle(
                    title: "MediaPipe Face Detector",
                    subtitle: "BlazeFace。軽量・標準的な顔をカバー",
                    isOn: $store.settings.useFaceDetector,
                    isLocked: false
                )
                AuxDetectorToggle(
                    title: "YuNet",
                    subtitle: "Core ML。小顔・横顔に強い",
                    isOn: $store.settings.useYunet,
                    isLocked: false
                )
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

/// 補助検出器の ON/OFF トグル。Pro 機能でロックされている時は鍵アイコンを表示し操作を無効化する。
private struct AuxDetectorToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let isLocked: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(isLocked)
        }
        .padding(.vertical, 2)
    }
}

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
