import MosaicCore
import SwiftUI

// `TimelineEditSheets.swift` が file_length の閾値に張り付いているため分けてある
// （`TimelineTextStyleSheet.swift` と同じ理由）。

/// クリップ音量の活性判定（View から切り出した純ロジック）。
///
/// **写真クリップを除く**のが本体。写真素材（`TimelineSource.Kind.photo`）は
/// `PhotoClipEncoder` が音声トラック無しの静止 mp4 を作るので、`AudioMixFactory` の
/// `placement.audioTrack` が nil になり音量設定が丸ごと無視される。押せるのに何も
/// 起きないボタンを出さないため、選択中でも活性にしない。
enum TimelineVolumeAvailability {
    /// 音量 UI の対象。**選択しているものによって切り替わる**（ユーザー決定 2026-08-02:
    /// 「どちらも既存の音量ボタンから」）。
    enum Target: Equatable {
        /// クリップの元音声（`TimelineClip.originalAudioVolume`）。
        case clip(UUID)
        /// BGM（`AudioItem.volume`）。
        case audio(UUID)
    }

    /// 指定クリップで音量 UI を出してよいか（未選択・存在しない ID・写真クリップは false）。
    static func isEnabled(timeline: TimelineState, clipID: UUID?) -> Bool {
        guard let clipID, let clip = timeline.clips.first(where: { $0.id == clipID }) else { return false }
        return timeline.sourceKind(of: clip.sourceID) != .photo
    }

    /// 選択状態から音量 UI の対象を決める唯一の入口（E2）。
    ///
    /// **BGM の選択を優先する。** レイヤーとクリップは相互排他で選ばれる
    /// （`TimelineSelection`）ので実際には同時に立たないが、順序を決めておかないと
    /// 「BGM を選んだのにクリップの音量が出る」形の取り違えが将来生まれる。
    ///
    /// 判定を View に書かず純関数へ置くのは、活性判定（ボタンを押せるか）と
    /// 実行（どちらの音量を変えるか）が**必ず同じ規則**であることを担保するため。
    /// 別々に書くと「押せるのに何も起きない」が作れてしまう。
    static func target(timeline: TimelineState,
                       selection: TimelineSelection) -> Target? {
        if let layer = selection.layer, layer.kind == .audio,
           timeline.audioItems.contains(where: { $0.id == layer.id }) {
            return .audio(layer.id)
        }
        guard isEnabled(timeline: timeline, clipID: selection.clipID),
              let clipID = selection.clipID else { return nil }
        return .clip(clipID)
    }

    /// いま音量 UI が指している対象が消音されているか（ツールバーのアイコン用）。
    ///
    /// **対象の決定は `target(timeline:selection:)` を通すこと。** 別に書くと
    /// 「クリップを選んでいるのに BGM の消音状態でアイコンが変わる」形の取り違えが
    /// 生まれる（この型の他の判定と同じ理由）。対象が無いときは false
    /// （ボタン自体が非活性なので、消音の見た目にはしない）。
    static func isMuted(timeline: TimelineState, selection: TimelineSelection) -> Bool {
        switch target(timeline: timeline, selection: selection) {
        case .clip(let id):
            guard let clip = timeline.clips.first(where: { $0.id == id }) else { return false }
            return TimelineClip.clampedVolume(clip.originalAudioVolume) <= 0
        case .audio(let id):
            guard let item = timeline.audioItems.first(where: { $0.id == id }) else { return false }
            return TimelineClip.clampedVolume(item.volume) <= 0
        case nil:
            return false
        }
    }
}

/// クリップ音量シート（0〜100% の**線形**スライダー + ミュートトグル）。
///
/// 速度（`TimelineSpeedSheet`）と違って対数にする必然性がないので線形にしてある
/// （50% が「半分」として素直に読める）。値のクランプは `TimelineClip.clampedVolume`
/// が唯一の実装で、View は算術を持たない。
///
/// 適用はスライダー確定時（`onEditingChanged` の false）とプリセット・ミュートの
/// タップ時だけ。`TimelineSpeedSheet` と同じ理由で、連続適用すると 1 ドラッグで
/// composition の再構築が何十回も走る。
struct TimelineVolumeSheet: View {
    /// BGM だけが持つフェード設定（E2-2）。クリップの元音声にはフェードが無いので
    /// `nil` のときはこのシートにフェード UI を出さない。
    ///
    /// **上限は呼び出し側（`TimelineEditSheetsModifier`）が BGM の再生尺から
    /// `duration / 2` を渡すこと。** 丸めそのものは `AudioItem.clampedFade` /
    /// `TimelineState.settingAudioFade` が最終防御として行うので、ここでの上限は
    /// スライダーの見た目の範囲を決めるだけで安全性の根拠ではない。
    struct FadeConfig {
        let initialFadeIn: Double
        let initialFadeOut: Double
        let maximumFade: Double
        let onApply: (Double, Double) -> Void
    }

    let initialVolume: Float
    let onApply: (Float) -> Void
    let fadeConfig: FadeConfig?

    @Environment(\.dismiss) private var dismiss
    @State private var sliderValue: Double
    /// ミュート解除で戻す音量。0 を渡されたときは 100% を既定にする
    /// （復帰先が 0 だと「ミュート解除」が無反応になる）。
    @State private var volumeBeforeMute: Double
    @State private var fadeIn: Double
    @State private var fadeOut: Double

    private static let presets: [Float] = [0.25, 0.5, 0.75, 1]

    init(initialVolume: Float, fadeConfig: FadeConfig? = nil, onApply: @escaping (Float) -> Void) {
        self.initialVolume = initialVolume
        self.fadeConfig = fadeConfig
        self.onApply = onApply
        let clamped = Double(TimelineClip.clampedVolume(initialVolume))
        _sliderValue = State(initialValue: clamped)
        _volumeBeforeMute = State(initialValue: clamped > 0 ? clamped : 1)
        _fadeIn = State(initialValue: fadeConfig?.initialFadeIn ?? 0)
        _fadeOut = State(initialValue: fadeConfig?.initialFadeOut ?? 0)
    }

    private var volume: Float { TimelineClip.clampedVolume(Float(sliderValue)) }
    private var isMuted: Bool { volume <= 0 }
    private var percentText: String { "\(Int((Double(volume) * 100).rounded()))%" }

    private var sliderRange: ClosedRange<Double> {
        Double(TimelineClip.volumeRange.lowerBound)...Double(TimelineClip.volumeRange.upperBound)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(fadeConfig != nil ? "BGM 音量" : "クリップ音量")
                .font(.headline)

            Text(isMuted ? "ミュート" : percentText)
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .foregroundStyle(isMuted ? Color.secondary : Color.primary)

            HStack {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $sliderValue, in: sliderRange) { editing in
                    if !editing { apply(volume) }
                }
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button { toggleMute() } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.footnote.weight(.medium))
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)
                .tint(isMuted ? .red : .accentColor)
                .accessibilityLabel(isMuted ? "ミュートを解除" : "ミュート")
                ForEach(Self.presets, id: \.self) { preset in
                    Button("\(Int(preset * 100))%") { select(preset) }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.bordered)
                }
            }

            if let fadeConfig {
                fadeSection(fadeConfig)
            }

            Text(fadeConfig != nil
                 ? "BGM だけに掛かります（元動画の音声・モザイク区間は変わりません）"
                 : "元素材の音声だけに掛かります（合成尺・モザイク区間は変わりません）")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("完了") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.height(fadeConfig != nil ? 460 : 320)])
    }

    /// フェードイン／アウトのスライダー（E2-2）。BGM のときだけ出す。
    ///
    /// **確定はスライダーを離したときだけ**（`sliderValue` の音量スライダーと同じ流儀。
    /// 連続適用すると 1 ドラッグで composition の再構築が何十回も走る）。
    @ViewBuilder
    private func fadeSection(_ config: FadeConfig) -> some View {
        VStack(spacing: 10) {
            Divider()
            fadeRow(title: "フェードイン", value: $fadeIn, maximum: config.maximumFade, config: config)
            fadeRow(title: "フェードアウト", value: $fadeOut, maximum: config.maximumFade, config: config)
            Text(String(format: "上限 %.1f 秒（曲の長さの半分。イン・アウトは重なりません）",
                       config.maximumFade))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func fadeRow(title: String, value: Binding<Double>,
                         maximum: Double, config: FadeConfig) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.footnote)
                Spacer()
                Text(String(format: "%.1f 秒", value.wrappedValue))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...max(maximum, 0.01)) { editing in
                if !editing { applyFade(config) }
            }
        }
    }

    /// モデルへ反映する唯一の口。0 でない値は「ミュート解除で戻る先」としても覚える。
    private func apply(_ value: Float) {
        let clamped = TimelineClip.clampedVolume(value)
        if clamped > 0 { volumeBeforeMute = Double(clamped) }
        onApply(clamped)
    }

    /// フェードをモデルへ反映する唯一の口。実際の丸め（`duration / 2` 上限）は
    /// `TimelineState.settingAudioFade` が最終防御として行う。
    private func applyFade(_ config: FadeConfig) {
        config.onApply(fadeIn, fadeOut)
    }

    /// ミュートのトグル。ON で 0、OFF で直前値へ復帰する。
    ///
    /// 適用値は `sliderValue` を読み直さず `target` から渡す（`@State` の
    /// 書き戻し直後に読むことに依存しない）。
    private func toggleMute() {
        let target: Double
        if isMuted {
            target = volumeBeforeMute
        } else {
            volumeBeforeMute = sliderValue
            target = 0
        }
        sliderValue = target
        apply(Float(target))
    }

    private func select(_ preset: Float) {
        sliderValue = Double(TimelineClip.clampedVolume(preset))
        apply(preset)
    }
}
