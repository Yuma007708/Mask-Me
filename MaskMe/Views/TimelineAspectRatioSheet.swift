import MosaicCore
import SwiftUI

/// 出力の画面比率（9:16 / 1:1 / 16:9 / 素材に合わせる）を選ぶシート。
///
/// 入口は下部ツールバーの「比率」（`VideoTimelineView+Toolbar.aspectRatioItem`）。
/// 以前は再生行の小さなメニューだったが、そこは 8 要素で潰れる幅だったので移した。
///
/// **素材は切り取らない。** 枠に収まらない素材は縮小して中央に置かれ、余白ができる
/// （`TimelineAspectRatio` の doc）。モザイクの位置は素材と一緒に動く
/// （顔座標も映像と同じ写像を通る）。
///
/// 余白の埋め方（黒／色／ぼかし）も同じシートで選ぶ。**別のシートに分けない**——
/// 余白は比率を選んだ結果として生まれるものなので、原因と結果が別の場所にあると
/// 「なぜ黒帯が出るのか」と「どう変えるのか」が結び付かない。
///
/// **用途を併記している。** 「9:16」だけでは何に使う比率なのか伝わらない、という
/// 実地検証の指摘への対応。数字は覚えていなくても「TikTok に上げたい」からは選べる。
struct TimelineAspectRatioSheet: View {
    @ObservedObject var model: MosaicEditorModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TimelineAspectRatio.allCases, id: \.self) { ratio in
                        row(ratio)
                    }
                } footer: {
                    Text("枠に収まらない素材は、切り取らずに縮小して中央に置かれます。")
                }
                backgroundSection
            }
            .appSheetBackground()
            .navigationTitle("画面比率")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { onClose() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// 余白の埋め方。**比率が `.source` のときも出す**——素材が 1 本でも
    /// クリップごとに縦横比が違えば余白は出るし、隠しておくと「設定が消えた」に見える。
    @ViewBuilder
    private var backgroundSection: some View {
        Section("余白の埋め方") {
            ForEach(TimelineBackground.Kind.allCases) { kind in
                backgroundRow(kind)
            }
            if model.timeline.background.kind == .color {
                ColorPicker("余白の色",
                            selection: Binding(
                                get: { Color(uiColor: model.timeline.background.color.uiColor) },
                                set: { newValue in
                                    var next = model.timeline.background
                                    next.color = newValue.rgbaColorValue
                                    model.setLetterboxBackground(next)
                                }),
                            supportsOpacity: false)
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityIdentifier("editor.background.colorPicker")
            }
            if model.timeline.background.kind == .blur {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ぼかしの強さ")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkDim)
                    Slider(value: Binding(
                        get: { model.timeline.background.blurStrength },
                        set: { newValue in
                            var next = model.timeline.background
                            next.blurStrength = newValue
                            model.setLetterboxBackground(next)
                        }), in: 0.05...1)
                        .accessibilityIdentifier("editor.background.blurStrength")
                }
            }
        }
    }

    private func backgroundRow(_ kind: TimelineBackground.Kind) -> some View {
        let isSelected = model.timeline.background.kind == kind
        return Button {
            var next = model.timeline.background
            next.kind = kind
            model.setLetterboxBackground(next)
        } label: {
            HStack(spacing: 12) {
                backgroundSwatch(kind)
                Text(kind.title)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityIdentifier("editor.background.\(kind.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 埋め方の見本。**ぼかしは絵が要る**ので、色の見本と同じ四角では表せない。
    /// 段階的なグラデーションで「ぼけた絵が敷かれる」ことを示す。
    @ViewBuilder
    private func backgroundSwatch(_ kind: TimelineBackground.Kind) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        switch kind {
        case .black:
            shape.fill(Color.black)
                .frame(width: 22, height: 22)
                .overlay(shape.strokeBorder(AppTheme.line, lineWidth: 1))
                .frame(width: 32, height: 28)
        case .color:
            shape.fill(Color(uiColor: model.timeline.background.color.uiColor))
                .frame(width: 22, height: 22)
                .overlay(shape.strokeBorder(AppTheme.line, lineWidth: 1))
                .frame(width: 32, height: 28)
        case .blur:
            shape.fill(LinearGradient(colors: [AppTheme.accent.opacity(0.7),
                                               AppTheme.ToolAccent.decorate.opacity(0.7)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .blur(radius: 2)
                .frame(width: 22, height: 22)
                .clipShape(shape)
                .overlay(shape.strokeBorder(AppTheme.line, lineWidth: 1))
                .frame(width: 32, height: 28)
        }
    }

    private func row(_ ratio: TimelineAspectRatio) -> some View {
        let isSelected = model.timeline.aspectRatio == ratio
        return Button {
            model.setOutputAspectRatio(ratio)
            onClose()
        } label: {
            HStack(spacing: 12) {
                shape(for: ratio)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(ratio))
                        .foregroundStyle(AppTheme.ink)
                    Text(Self.usage(ratio))
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkDim)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityIdentifier("editor.aspectRatio.\(ratio.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 比率の形をそのまま小さな枠で見せる（言葉より形のほうが速く読める）。
    private func shape(for ratio: TimelineAspectRatio) -> some View {
        let size: CGSize = {
            switch ratio {
            case .source: return CGSize(width: 22, height: 22)
            case .portrait9x16: return CGSize(width: 15, height: 26)
            case .square1x1: return CGSize(width: 22, height: 22)
            case .landscape16x9: return CGSize(width: 28, height: 16)
            }
        }()
        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(AppTheme.inkDim, lineWidth: ratio == .source ? 1 : 1.5)
            .frame(width: size.width, height: size.height)
            .frame(width: 32, height: 28)
            .opacity(ratio == .source ? 0.5 : 1)
    }

    static func title(_ ratio: TimelineAspectRatio) -> String {
        switch ratio {
        case .source: return "素材に合わせる"
        case .portrait9x16: return "9:16（縦）"
        case .square1x1: return "1:1（正方形）"
        case .landscape16x9: return "16:9（横）"
        }
    }

    /// 何に使う比率か。数字を覚えていない人が選べるようにする。
    static func usage(_ ratio: TimelineAspectRatio) -> String {
        switch ratio {
        case .source: return "元の動画のままの形"
        case .portrait9x16: return "TikTok・リール・ショート向け"
        case .square1x1: return "Instagram のフィード向け"
        case .landscape16x9: return "YouTube・テレビ向け"
        }
    }
}

extension Color {
    /// `ColorPicker` の選択値をコア層の値型へ戻す。
    ///
    /// **`MosaicCore` へ SwiftUI の型を持ち込まない**ためにアプリ層へ置く
    /// （`RGBAColor.uiColor` が UIKit 側で同じ理由により `TextRasterizer` にあるのと対）。
    /// 取り出せない色空間（P3 外・パターン等）は黒へ倒す——ここで落とすと
    /// 余白の色を選んだ瞬間にアプリが止まる。
    var rgbaColorValue: RGBAColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .black
        }
        return RGBAColor(red: Double(red), green: Double(green),
                         blue: Double(blue), alpha: Double(alpha)).clamped
    }
}
