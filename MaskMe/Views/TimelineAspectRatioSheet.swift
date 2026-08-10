import MosaicCore
import SwiftUI

/// 出力の画面比率（9:16 / 1:1 / 16:9 / 素材に合わせる）を選ぶシート。
///
/// 入口は下部ツールバーの「比率」（`VideoTimelineView+Toolbar.aspectRatioItem`）。
/// 以前は再生行の小さなメニューだったが、そこは 8 要素で潰れる幅だったので移した。
///
/// **素材は切り取らない。** 枠に収まらない素材は縮小して中央に置かれ、余白は黒帯になる
/// （`TimelineAspectRatio` の doc）。モザイクの位置は素材と一緒に動く
/// （顔座標も映像と同じ写像を通る）。
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
                    Text("枠に収まらない素材は、切り取らずに縮小して中央に置かれます"
                         + "（余白は黒帯になります）。")
                }
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
        .presentationDetents([.medium])
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
                        .foregroundStyle(Color(uiColor: .label))
                    Text(Self.usage(ratio))
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
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
            .strokeBorder(Color(uiColor: .secondaryLabel), lineWidth: ratio == .source ? 1 : 1.5)
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
