import MosaicCore
import SwiftUI

extension TransitionKind {
    /// 日本語表示名（UI 専用。コア層は表示文言を持たない）。
    var displayName: String {
        switch self {
        case .fadeToBlack: return "フェード（黒）"
        case .crossfade: return "クロスフェード"
        case .slideLeft: return "スライド（左へ）"
        case .slideRight: return "スライド（右へ）"
        case .wipeLeft: return "ワイプ（左へ）"
        case .wipeRight: return "ワイプ（右へ）"
        }
    }

    var symbolName: String {
        switch self {
        case .fadeToBlack: return "circle.lefthalf.filled"
        case .crossfade: return "square.on.square"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .wipeLeft: return "rectangle.lefthalf.filled"
        case .wipeRight: return "rectangle.righthalf.filled"
        }
    }
}

/// 速度シート（0.1x〜10x の**対数スケール**スライダー）。
///
/// スライダー値 0...1 ⇔ 倍率の変換は `TimelineRateScale`（純関数・単体テスト済み）が
/// 唯一の実装で、View は算術を持たない。
/// 適用はドラッグ確定時（`onEditingChanged` の false）とプリセットタップ時だけ
/// （連続適用すると 1 ドラッグで composition 再構築が何十回も走る）。
///
/// **上限は `maximumRate`（= `TimelineRateScale.maximumRate(forClip:)`）で切る。**
/// 合成尺が `TimelineEditOperations.minimumClipDuration` を割るクリップは端トリムを
/// 一切受け付けられなくなるため、そこへ到達する倍率をこの UI から選べないようにする
/// （`TimelineEditOperations.setRate` の契約は S1 のまま変えない）。
struct TimelineSpeedSheet: View {
    let initialRate: Double
    /// 選べる倍率の上限（クリップ尺から決まる）。
    let maximumRate: Double
    let onApply: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sliderValue: Double

    private static let presets: [Double] = [0.25, 0.5, 1, 2, 4]

    init(initialRate: Double,
         maximumRate: Double = TimelineClip.rateRange.upperBound,
         onApply: @escaping (Double) -> Void) {
        self.initialRate = initialRate
        self.maximumRate = maximumRate
        self.onApply = onApply
        let clamped = min(initialRate, maximumRate)
        _sliderValue = State(initialValue: TimelineRateScale.sliderValue(forRate: clamped))
    }

    /// スライダー値から決まる倍率（上限で切る）。
    private var rate: Double { min(TimelineRateScale.rate(forSliderValue: sliderValue), maximumRate) }

    /// スライダーの上端（上限倍率に対応する位置）。幅 0 の range を作らない。
    private var sliderUpperBound: Double {
        max(TimelineRateScale.sliderValue(forRate: maximumRate), 0.01)
    }

    /// 上限で押せなくなるプリセット（押せると「選んだのに違う値になる」ので無効化する）。
    private func isPresetEnabled(_ preset: Double) -> Bool { preset <= maximumRate }

    var body: some View {
        VStack(spacing: 18) {
            Text("再生速度")
                .font(.headline)

            Text(String(format: "%.2fx", rate))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())

            HStack {
                Text(String(format: "%.1fx", TimelineClip.rateRange.lowerBound))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $sliderValue, in: 0...sliderUpperBound) { editing in
                    if !editing { onApply(rate) }
                }
                Text(String(format: "%.2gx", maximumRate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button(String(format: preset < 1 ? "%.2gx" : "%.0fx", preset)) {
                        sliderValue = TimelineRateScale.sliderValue(forRate: preset)
                        onApply(preset)
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .disabled(!isPresetEnabled(preset))
                    .opacity(isPresetEnabled(preset) ? 1 : 0.3)
                }
            }

            Text(maximumRate < TimelineClip.rateRange.upperBound
                 ? String(format: "このクリップの上限は %.2gx（これ以上速くすると帯が短すぎて調整できません）",
                          maximumRate)
                 : "スライダーは対数スケール（中央が 1.00x）")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("完了") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.height(320)])
    }
}

/// クリップ音量の活性判定（View から切り出した純ロジック）。
///
/// **写真クリップを除く**のが本体。写真素材（`TimelineSource.Kind.photo`）は
/// `PhotoClipEncoder` が音声トラック無しの静止 mp4 を作るので、`AudioMixFactory` の
/// `placement.audioTrack` が nil になり音量設定が丸ごと無視される。押せるのに何も
/// 起きないボタンを出さないため、選択中でも活性にしない。
enum TimelineVolumeAvailability {
    /// 指定クリップで音量 UI を出してよいか（未選択・存在しない ID・写真クリップは false）。
    static func isEnabled(timeline: TimelineState, clipID: UUID?) -> Bool {
        guard let clipID, let clip = timeline.clips.first(where: { $0.id == clipID }) else { return false }
        return timeline.sourceKind(of: clip.sourceID) != .photo
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
    let initialVolume: Float
    let onApply: (Float) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sliderValue: Double
    /// ミュート解除で戻す音量。0 を渡されたときは 100% を既定にする
    /// （復帰先が 0 だと「ミュート解除」が無反応になる）。
    @State private var volumeBeforeMute: Double

    private static let presets: [Float] = [0.25, 0.5, 0.75, 1]

    init(initialVolume: Float, onApply: @escaping (Float) -> Void) {
        self.initialVolume = initialVolume
        self.onApply = onApply
        let clamped = Double(TimelineClip.clampedVolume(initialVolume))
        _sliderValue = State(initialValue: clamped)
        _volumeBeforeMute = State(initialValue: clamped > 0 ? clamped : 1)
    }

    private var volume: Float { TimelineClip.clampedVolume(Float(sliderValue)) }
    private var isMuted: Bool { volume <= 0 }
    private var percentText: String { "\(Int((Double(volume) * 100).rounded()))%" }

    private var sliderRange: ClosedRange<Double> {
        Double(TimelineClip.volumeRange.lowerBound)...Double(TimelineClip.volumeRange.upperBound)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("クリップ音量")
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

            Text("元素材の音声だけに掛かります（合成尺・モザイク区間は変わりません）")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("完了") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.height(320)])
    }

    /// モデルへ反映する唯一の口。0 でない値は「ミュート解除で戻る先」としても覚える。
    private func apply(_ value: Float) {
        let clamped = TimelineClip.clampedVolume(value)
        if clamped > 0 { volumeBeforeMute = Double(clamped) }
        onApply(clamped)
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

/// トランジションシート（種類 + 長さ）。
///
/// 長さの上限は `TimelineState.maximumTransitionDuration(afterClipID:)`
/// （= min(両クリップ合成尺)/2）。上限がそのまま渡ってくるので、
/// 「設定したのにクランプで消える」値をスライダーで選べない。
struct TimelineTransitionSheet: View {
    let current: TransitionSpec?
    let maximumDuration: Double
    let onApply: (TransitionKind, Double) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: TransitionKind
    @State private var duration: Double
    /// スライダーを一度でも触ったか。触るまでは種類の切り替えに合わせて
    /// 既定尺（`TransitionKind.defaultDuration`）へ追従させる。触った後に
    /// 上書きすると、選んだ長さが種類変更で黙って消える。
    @State private var didAdjustDuration = false

    init(current: TransitionSpec?,
         maximumDuration: Double,
         onApply: @escaping (TransitionKind, Double) -> Void,
         onRemove: @escaping () -> Void) {
        self.current = current
        self.maximumDuration = maximumDuration
        self.onApply = onApply
        self.onRemove = onRemove
        let initialKind = current?.kind ?? .crossfade
        _kind = State(initialValue: initialKind)
        let initial = current?.duration ?? initialKind.defaultDuration
        _duration = State(initialValue: Self.clamp(initial, maximum: maximumDuration))
        // 既存トランジションを編集しているときは、その長さがユーザーの選択。
        // 種類を変えても保つ。
        _didAdjustDuration = State(initialValue: current != nil)
    }

    private static func clamp(_ value: Double, maximum: Double) -> Double {
        min(max(value, TransitionSpec.minimumDuration), max(maximum, TransitionSpec.minimumDuration))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("トランジション")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TransitionKind.allCases, id: \.self) { candidate in
                        kindButton(candidate)
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("長さ")
                        .font(.footnote)
                    Spacer()
                    Text(String(format: "%.2f 秒", duration))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $duration, in: sliderRange) { editing in
                    if editing { didAdjustDuration = true }
                }
                Text(String(format: "上限 %.2f 秒（隣り合うクリップの短い方の半分）", maximumDuration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if current != nil {
                    Button("削除", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Button("適用") {
                    onApply(kind, duration)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .presentationDetents([.height(340)])
    }

    /// スライダーの範囲。上限が最小尺と一致する境界（極端に短いクリップ）でも
    /// 幅 0 の range を作らない（Slider が NaN を吐く）。
    private var sliderRange: ClosedRange<Double> {
        let lower = TransitionSpec.minimumDuration
        return lower...max(maximumDuration, lower + 0.01)
    }

    private func kindButton(_ candidate: TransitionKind) -> some View {
        Button {
            kind = candidate
            // 長さを触っていなければ、その種類の既定尺へ寄せる
            // （黒フェードは暗転・黒・明転の 3 段ぶん長さが要る）。
            if !didAdjustDuration {
                duration = Self.clamp(candidate.defaultDuration, maximum: maximumDuration)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: candidate.symbolName)
                    .font(.system(size: 18))
                Text(candidate.displayName)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.center)
            }
            .frame(width: 76, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(kind == candidate ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(kind == candidate ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// タイムラインの編集シート 4 種（速度・音量・トランジション・素材追加）の提示をまとめた modifier。
///
/// **`VideoTimelineView` から切り出してある**のは、あちらが file_length（500 行警告）の
/// 閾値に張り付いていて、シートを 1 つ増やすたびに閾値を割るため。提示条件は
/// 「対象クリップ ID が nil でない」の 1 本だけで、閉じたら ID を nil に戻す
/// （呼び出し側の `@State` がそのまま提示状態を兼ねる）。
///
/// **消えたクリップの掃除は呼び出し側の責務**（`VideoTimelineView.pruneSelection`）。
/// ここは ID を持たず、シート本体側で「引けなければ何も描かない」に留める。
struct TimelineEditSheetsModifier: ViewModifier {
    @ObservedObject var model: MosaicEditorModel
    @Binding var speedClipID: UUID?
    @Binding var volumeClipID: UUID?
    @Binding var transitionClipID: UUID?
    @Binding var showMediaPicker: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presenting($speedClipID)) { speedSheet }
            .sheet(isPresented: presenting($volumeClipID)) { volumeSheet }
            .sheet(isPresented: presenting($transitionClipID)) { transitionSheet }
            .sheet(isPresented: $showMediaPicker) {
                TimelineMediaAppendPicker(model: model) { showMediaPicker = false }
            }
    }

    /// 「ID が入っていたら出す・閉じたら nil に戻す」の Bool 変換。
    private func presenting(_ clipID: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { clipID.wrappedValue != nil },
                set: { if !$0 { clipID.wrappedValue = nil } })
    }

    @ViewBuilder
    private var speedSheet: some View {
        if let id = speedClipID, let clip = model.timeline.clips.first(where: { $0.id == id }) {
            // 上限はクリップ尺から決まる（合成尺が最小尺を割る倍率を選べないようにする。
            // `TimelineRateScale.maximumRate(forClip:)` の doc 参照）。
            TimelineSpeedSheet(initialRate: clip.rate,
                               maximumRate: TimelineRateScale.maximumRate(forClip: clip)) { rate in
                model.setClipRate(id: id, rate: rate)
            }
        }
    }

    @ViewBuilder
    private var volumeSheet: some View {
        if let id = volumeClipID, let clip = model.timeline.clips.first(where: { $0.id == id }) {
            TimelineVolumeSheet(initialVolume: clip.originalAudioVolume) { volume in
                model.setClipVolume(id: id, volume: volume)
            }
        }
    }

    @ViewBuilder
    private var transitionSheet: some View {
        if let id = transitionClipID,
           let maximum = model.timeline.maximumTransitionDuration(afterClipID: id) {
            TimelineTransitionSheet(
                current: model.timeline.transitions[id],
                maximumDuration: maximum,
                onApply: { kind, duration in
                    model.setTransition(afterClipID: id, kind: kind, duration: duration)
                },
                onRemove: { model.removeTransition(afterClipID: id) })
        } else {
            Text("このつなぎ目にはトランジションを付けられません（クリップが短すぎます）")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(24)
                .presentationDetents([.height(140)])
        }
    }
}
