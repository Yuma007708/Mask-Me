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

    init(current: TransitionSpec?,
         maximumDuration: Double,
         onApply: @escaping (TransitionKind, Double) -> Void,
         onRemove: @escaping () -> Void) {
        self.current = current
        self.maximumDuration = maximumDuration
        self.onApply = onApply
        self.onRemove = onRemove
        _kind = State(initialValue: current?.kind ?? .crossfade)
        let initial = current?.duration ?? min(0.5, maximumDuration)
        _duration = State(initialValue: min(max(initial, TransitionSpec.minimumDuration), maximumDuration))
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
                Slider(value: $duration, in: sliderRange)
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
