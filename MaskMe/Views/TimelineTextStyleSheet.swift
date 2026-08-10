import MosaicCore
import SwiftUI

/// テキストの見た目・出し方の設定シート（E3-3b）。フォント・文字サイズ・色・縁取り・
/// 背景帯・アニメーション種をまとめて編集する。
///
/// `TimelineEditSheets.swift` から切り出してある（`file_length` の閾値に張り付いていたため）。
///
/// **色はプリセット数色だけ。** カラーピッカーは作らない（要件どおり）。
///
/// **適用のタイミングは項目で分ける**（`TimelineVolumeSheet` と同じ流儀）:
/// - 連続値（文字サイズ・縁取りの太さ・背景の不透明度）はスライダー確定時
///   （`onEditingChanged` の false）だけで適用する。連続適用すると 1 ドラッグで
///   `applyTimelineEdit` の再構築が何十回も走る。
/// - 離散値（色・フォント・アニメーション種のプリセット）はタップ即時に適用する
///   （`TimelineVolumeSheet` のプリセットボタン・`TimelineTransitionSheet` の種類選択と同じ）。
struct TimelineTextStyleSheet: View {
    let initialStyle: TextStyle
    let initialAnimation: TextAnimation
    /// 対象の役割。**ステッカーは見た目の編集項目を絞る**（サイズ・不透明度・
    /// アニメーションだけ）。書体・文字色・縁取り・背景帯は文字専用の項目で、
    /// 絵文字は自前の色を持つため意味が薄い上、**縁取りは端末・絵文字によって
    /// 描画が破綻する**ため UI ごと出さない（`TextRasterizer` の対象外）。
    let role: TextItemRole
    let onApplyStyle: (TextStyle) -> Void
    let onApplyAnimation: (TextAnimation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var style: TextStyle
    @State private var animation: TextAnimation

    /// 文字色・縁取り色・背景色で共有するプリセット（白・黒・赤・黄・青の 5 色）。
    private static let colorPresets: [RGBAColor] = [
        .white, .black,
        RGBAColor(red: 0.95, green: 0.23, blue: 0.19),
        RGBAColor(red: 1.0, green: 0.84, blue: 0.04),
        RGBAColor(red: 0.20, green: 0.48, blue: 0.98)
    ]

    init(initialStyle: TextStyle, initialAnimation: TextAnimation, role: TextItemRole,
         onApplyStyle: @escaping (TextStyle) -> Void,
         onApplyAnimation: @escaping (TextAnimation) -> Void) {
        self.initialStyle = initialStyle
        self.initialAnimation = initialAnimation
        self.role = role
        self.onApplyStyle = onApplyStyle
        self.onApplyAnimation = onApplyAnimation
        _style = State(initialValue: initialStyle)
        _animation = State(initialValue: initialAnimation)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(role == .sticker ? "ステッカーの見た目" : "テキストの見た目")
                    .font(.headline)

                fontSizeSection
                if role == .sticker {
                    opacitySection
                } else {
                    fontFamilySection
                    colorSection(title: "文字色", selected: style.color) { style.color = $0; apply() }
                    strokeSection
                    backgroundSection
                }
                animationSection

                Button("完了") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .appSheetBackground()
        .presentationDetents(role == .sticker ? [.height(420)] : [.height(620), .large])
    }

    // MARK: - 書体

    private var fontFamilySection: some View {
        section(title: "書体") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TextFontFamily.allCases, id: \.self) { family in
                        Button {
                            style.fontFamily = family
                            apply()
                        } label: {
                            Text(family.displayName)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(style.fontFamily == family
                                             ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(style.fontFamily == family ? Color.accentColor : .clear,
                                                     lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - 文字サイズ

    /// スライダーの上限は役割ごとに違う（`TextItemRole.maximumFontSize`）。
    /// **実際のクランプはコア層（`TimelineState.settingTextStyle`）が対象アイテムの
    /// `role` から行う**ので、ここでの上限違いは UI 上の見え方を実際の可動域へ
    /// 合わせるためのものであって、安全側の判定そのものはコア層 1 本にある。
    private var fontSizeSection: some View {
        section(title: "\(role == .sticker ? "サイズ" : "文字サイズ")（\(Int((style.fontSize * 100).rounded()))%）") {
            Slider(value: $style.fontSize,
                  in: TextStyle.minimumFontSize...role.maximumFontSize) { editing in
                if !editing { apply() }
            }
        }
    }

    // MARK: - 不透明度（ステッカー専用）

    /// ステッカーには文字色の概念が薄いので色プリセットは出さず、代わりに
    /// `style.color.alpha` を「不透明度」として直接編集する。CoreText はカラー絵文字を
    /// 描くとき前景色の RGB を無視するが、**alpha は合成の不透明度としてそのまま効く**
    /// （`TextRasterizer.rasterize` が `NSAttributedString.foregroundColor` へそのまま渡す）。
    private var opacitySection: some View {
        section(title: "不透明度（\(Int((style.color.alpha * 100).rounded()))%）") {
            Slider(value: Binding(
                get: { style.color.alpha },
                set: { style.color.alpha = $0 }
            ), in: 0...1) { editing in
                if !editing { apply() }
            }
        }
    }

    // MARK: - 縁取り

    private var strokeSection: some View {
        section(title: "縁取りの太さ（\(Int((style.strokeWidth * 100).rounded()))%）") {
            VStack(spacing: 10) {
                Slider(value: $style.strokeWidth, in: 0...0.3) { editing in
                    if !editing { apply() }
                }
                colorRow(selected: style.strokeColor) { style.strokeColor = $0; apply() }
            }
        }
    }

    // MARK: - 背景帯

    private var backgroundSection: some View {
        section(title: "背景帯の濃さ（\(Int((style.backgroundOpacity * 100).rounded()))%）") {
            VStack(spacing: 10) {
                Slider(value: $style.backgroundOpacity, in: 0...1) { editing in
                    if !editing { apply() }
                }
                colorRow(selected: style.backgroundColor) { style.backgroundColor = $0; apply() }
            }
        }
    }

    // MARK: - アニメーション

    private var animationSection: some View {
        section(title: "出し方") {
            HStack(spacing: 8) {
                ForEach(TextAnimation.allCases, id: \.self) { candidate in
                    Button {
                        animation = candidate
                        onApplyAnimation(candidate)
                    } label: {
                        Text(candidate.displayName)
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(animation == candidate
                                         ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(animation == candidate ? Color.accentColor : .clear,
                                                 lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 共通部品

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorSection(title: String, selected: RGBAColor,
                              onSelect: @escaping (RGBAColor) -> Void) -> some View {
        section(title: title) { colorRow(selected: selected, onSelect: onSelect) }
    }

    private func colorRow(selected: RGBAColor, onSelect: @escaping (RGBAColor) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(Self.colorPresets.indices, id: \.self) { index in
                let preset = Self.colorPresets[index]
                Button { onSelect(preset) } label: {
                    Circle()
                        .fill(Color(uiColor: preset.uiColor))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay {
                            if preset == selected {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
        }
    }

    /// モデルへ反映する唯一の口。**必ずこの関数を通す**（`TimelineVolumeSheet.apply` と同じ流儀。
    /// 呼び出し箇所ごとに `onApplyStyle(style)` を直書きすると、将来ここへクランプ等を
    /// 足したときに反映漏れが起きる）。
    private func apply() { onApplyStyle(style) }
}

/// テキストの見た目設定シート（E3-3b）の提示条件。`EditorView` から切り出してある
/// （`type_body_length` の閾値に張り付いていたため。`TimelineEditSheetsModifier` と同じ
/// 「提示条件だけをここへ寄せる」考え方）。
///
/// **プレビュー上の選択（`TextOverlayEditView` の鉛筆ボタン）から開く。** `EditorView` は
/// この Binding を保つだけで、シート本体・対象の解決はここに閉じる。
struct EditorTextStyleSheetModifier: ViewModifier {
    @ObservedObject var model: MosaicEditorModel
    @Binding var itemID: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { itemID != nil },
                                        set: { if !$0 { itemID = nil } })) {
                sheetContent
            }
    }

    /// 消えたテキスト（削除・undo）を指したままにしない。`first(where:)` が nil を
    /// 返すぶんには何も描かない（`TimelineEditSheetsModifier.volumeSheet` と同じ規則）。
    ///
    /// **対象の配列はモードで分かれる。** 動画は `model.timeline.textItems`、写真は
    /// `model.photoEdit.texts`（写真モード底上げ 第2段。`TextOverlayEditView` の
    /// 鉛筆ボタンが両モードで積まれるようになったため、ここも両対応させる）。
    @ViewBuilder
    private var sheetContent: some View {
        if let id = itemID, let item = textItem(id: id) {
            TimelineTextStyleSheet(
                initialStyle: item.style, initialAnimation: item.animation, role: item.role,
                onApplyStyle: { style in applyStyle(id: id, style: style) },
                onApplyAnimation: { animation in applyAnimation(id: id, animation: animation) })
        }
    }

    private func textItem(id: UUID) -> TextItem? {
        switch model.mode {
        case .video: return model.timeline.textItems.first(where: { $0.id == id })
        case .photo: return model.photoEdit.texts.first(where: { $0.id == id })
        }
    }

    private func applyStyle(id: UUID, style: TextStyle) {
        switch model.mode {
        case .video: model.setTextStyle(id: id, style: style)
        case .photo: model.setPhotoTextStyle(id: id, style: style)
        }
    }

    /// **写真ではアニメーションを持たない。** `PhotoEditState.renderableTextItems` が
    /// 常に `animation = .none` へ正規化して描くため（`PhotoTextEditing.swift` の doc
    /// 参照）、写真モードでは適用先が無く no-op にする（シート自体はアニメーション種の
    /// 選択 UI を出すが、選んでも見た目には反映されない——将来アニメーションに意味を
    /// 持たせる段まではこの制約を明示的に保つ）。
    private func applyAnimation(id: UUID, animation: TextAnimation) {
        switch model.mode {
        case .video: model.setTextAnimation(id: id, animation: animation)
        case .photo: break
        }
    }
}
