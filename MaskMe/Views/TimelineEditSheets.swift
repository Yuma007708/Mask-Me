import MosaicCore
import SwiftUI
import UniformTypeIdentifiers

// `TextFontFamily.displayName` / `TimelineTextStyleSheet` は
// `TimelineTextStyleSheet.swift` へ（`file_length` の都合で分離）。

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

/// テキスト入力シート（E3-3a）。文面だけを受ける。
///
/// **見た目（フォント・色・位置）の設定はここに置かない**（E3-3b の範囲）。
/// このシートで確定した `TextItem` は既定のスタイル（`TextStyle()`）で
/// プレイヘッド位置・既定の長さ（`MosaicEditorModel.defaultTextDuration`）に置かれる。
///
/// **空文字は追加ボタンを押せない形で塞ぐ。** コア層（`TimelineState.addingTextItem`）も
/// 空文字を弾くが、ボタンを押せる見た目のまま何も起きないのは「壊れている」と読まれるため、
/// UI 側でも同じ判定（前後の空白を落として空かどうか）で活性を決める。
struct TimelineTextInputSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    /// 追加ボタンの活性判定。**`onAdd` に渡す実行と同じ判定**（前後の空白を落として空かどうか）。
    /// 別々に書くと「押せるのに何も起きない」を作れる（コア層の
    /// `TimelineState.addingTextItem` と同じ理由）。
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !trimmed.isEmpty }

    var body: some View {
        VStack(spacing: 18) {
            Text("テキストを追加")
                .font(.headline)

            TextField("表示する文字", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onChange(of: text) { newValue in
                    if newValue.count > TextItem.maximumTextLength {
                        text = String(newValue.prefix(TextItem.maximumTextLength))
                    }
                }

            Text("プレイヘッドの位置に既定の長さで置かれます（見た目は後で調整できます）")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("追加") {
                onAdd(trimmed)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
        }
        .padding(24)
        .presentationDetents([.height(260)])
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
