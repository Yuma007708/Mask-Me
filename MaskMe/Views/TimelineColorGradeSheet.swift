import MosaicCore
import SwiftUI

/// プリセットの日本語表示名・アイコン（UI 専用。コア層は表示文言を持たない）。
///
/// `TransitionKind.displayName` / `symbolName`（`TimelineEditSheets.swift`）と同じ流儀。
extension ColorGradePreset {
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .cinema: return "シネマ"
        case .retro: return "レトロ"
        case .cool: return "クール"
        case .warm: return "ウォーム"
        case .mono: return "モノクロ"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "circle.slash"
        case .cinema: return "film"
        case .retro: return "camera.aperture"
        case .cool: return "snowflake"
        case .warm: return "sun.max"
        case .mono: return "circle.lefthalf.filled"
        }
    }
}

/// 色調補正シート（明るさ・コントラスト・彩度・暖かみの 4 スライダー + プリセット）。
///
/// **プリセット名は保存しない。** クリップに保存されるのは `ColorGrade` の 4 値だけ
/// （`ColorGradePreset` の型 doc 参照）。このシートが「いま選ばれているプリセット」を
/// 表示するのは `ColorGradePreset.matching(_:)` による**逆引き**であり、保存経路には
/// 一切関与しない。
///
/// **確定はスライダーを離したときだけ**（`TimelineVolumeSheet` / `TimelineSpeedSheet` と
/// 同じ流儀。連続適用すると 1 ドラッグで composition の再構築が何十回も走る）。
/// プリセットのタップは即時反映（値の確定そのものであり、連続ドラッグではないため）。
struct TimelineColorGradeSheet: View {
    let initialGrade: ColorGrade
    /// このクリップだけへ適用する。
    let onApply: (ColorGrade) -> Void
    /// 「すべてのクリップに適用」。1 回の undo 単位にまとまる
    /// （`MosaicEditorModel.applyColorGradeToAllClips` の doc 参照）。
    let onApplyToAll: (ColorGrade) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var brightness: Double
    @State private var contrast: Double
    @State private var saturation: Double
    @State private var warmth: Double

    init(initialGrade: ColorGrade,
         onApply: @escaping (ColorGrade) -> Void,
         onApplyToAll: @escaping (ColorGrade) -> Void) {
        self.initialGrade = initialGrade
        self.onApply = onApply
        self.onApplyToAll = onApplyToAll
        _brightness = State(initialValue: initialGrade.brightness)
        _contrast = State(initialValue: initialGrade.contrast)
        _saturation = State(initialValue: initialGrade.saturation)
        _warmth = State(initialValue: initialGrade.warmth)
    }

    /// 現在のスライダー値から組み立てた `ColorGrade`。クランプは `ColorGrade` 自身が
    /// 担う（`didSet` 経由）ので、ここでは算術しない。
    private var currentGrade: ColorGrade {
        ColorGrade(brightness: brightness, contrast: contrast, saturation: saturation, warmth: warmth)
    }

    /// 現在の数値に一致するプリセット（無ければ「カスタム」表示）。保存経路には使わない
    /// （`ColorGradePreset.matching` の doc 参照。UI のハイライト用途限定）。
    private var matchingPreset: ColorGradePreset? { ColorGradePreset.matching(currentGrade) }

    var body: some View {
        VStack(spacing: 16) {
            Text("フィルター")
                .font(.headline)

            Text(matchingPreset?.displayName ?? "カスタム")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            presetRow

            VStack(spacing: 10) {
                slider(title: "明るさ", value: $brightness, range: ColorGrade.brightnessRange)
                slider(title: "コントラスト", value: $contrast, range: ColorGrade.contrastRange)
                slider(title: "彩度", value: $saturation, range: ColorGrade.saturationRange)
                slider(title: "暖かみ", value: $warmth, range: ColorGrade.warmthRange)
            }

            Button("すべてのクリップに適用") { onApplyToAll(currentGrade) }
                .buttonStyle(.bordered)

            Text("元素材の色味だけに掛かります（合成尺・モザイク区間は変わりません）")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("完了") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.height(560)])
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ColorGradePreset.allCases, id: \.self) { preset in
                    presetChip(preset)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func presetChip(_ preset: ColorGradePreset) -> some View {
        let isActive = matchingPreset == preset
        return Button { select(preset) } label: {
            VStack(spacing: 2) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 16))
                Text(preset.displayName)
                    .font(.caption2)
            }
            .frame(width: 56, height: 48)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }

    private func slider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.footnote)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if !editing { onApply(currentGrade) }
            }
        }
    }

    /// プリセットを選ぶ。**即時反映**（4 本まとめての確定なので「離したとき」の対象がない）。
    private func select(_ preset: ColorGradePreset) {
        let grade = preset.grade
        brightness = grade.brightness
        contrast = grade.contrast
        saturation = grade.saturation
        warmth = grade.warmth
        onApply(grade)
    }
}
