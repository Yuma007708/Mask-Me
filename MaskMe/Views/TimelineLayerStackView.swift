import MosaicCore
import SwiftUI

/// クリップ帯の下に積む「レイヤーの段」の種類。
///
/// **動画クリップの段はここに含めない。** あちらは常に見えている必要があり
/// （何を編集しているか分からないまま下の段だけ動くのは読めない）、
/// この列挙が表すのは「上に載る段」だけである。
enum TimelineLayerRowKind: String, CaseIterable, Identifiable {
    /// エフェクト。いま中身はモザイクだけ（`MosaicApplyRange`）。
    ///
    /// **`rawValue` は `mosaic` のまま**。これは表示名ではなく accessibility
    /// 識別子（`timeline.layer.mosaic.empty` 等）の素で、UI テストが掴んでいる。
    /// 帯の名前が「エフェクト」に変わったのは見え方の話なので、識別子は動かさない。
    case mosaic
    /// BGM・効果音。**まだ器だけ**（音声の取り込みは未実装）。
    case audio
    /// 画面に置く文字。**まだ器だけ**。
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mosaic: return "エフェクト"
        case .audio: return "音声"
        case .text: return "テキスト"
        }
    }

    /// 左端の固定列に出すアイコン。
    var systemImage: String {
        switch self {
        case .mosaic: return "squareshape.split.3x3"
        case .audio: return "music.note"
        case .text: return "textformat"
        }
    }

    /// 空の段に出す誘い文句。
    var emptyActionTitle: String {
        switch self {
        case .mosaic: return "エフェクトを追加"
        case .audio: return "音声を追加"
        case .text: return "テキストを追加"
        }
    }

    /// **中身を置けるか。** 器だけ先に作った段は false で、押しても何も起きない
    /// （押せる見た目のまま無反応にすると「壊れている」と読まれる）。
    var isImplemented: Bool {
        switch self {
        case .mosaic: return true
        case .audio, .text: return false
        }
    }
}

/// 空のレイヤー段。「ここに置ける」ことを見せるためだけの帯。
///
/// CapCut / VLLO と同じで、**空でも段は出す**。段が無いと機能の存在自体が
/// 見えず、ツールバーを総当たりすることになる。
struct TimelineEmptyLayerRow: View {
    let kind: TimelineLayerRowKind
    let width: CGFloat
    let onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
            Text(kind.emptyActionTitle)
                .font(TimelinePalette.hintFont)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind.isImplemented
                         ? TimelinePalette.secondaryText
                         : TimelinePalette.secondaryText.opacity(0.6))
        .padding(.horizontal, 8)
        .frame(width: max(width, 1), height: TimelineMetrics.layerRowHeight, alignment: .leading)
        .background(TimelinePalette.applyTrackBackground,
                    in: RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityIdentifier("timeline.layer.\(kind.rawValue).empty")
        .accessibilityLabel(kind.emptyActionTitle)
        .accessibilityAddTraits(.isButton)
    }
}

/// レイヤー段の左端に置く固定アイコン列。
///
/// **横スクロールしない層に置くこと**（呼び出し側の `.overlay`）。中身と一緒に
/// スクロールさせると、少し払っただけでどの段が何なのか分からなくなる。
/// 縦方向は中身と一緒に動く（段とアイコンの対応が崩れるため）。
struct TimelineLayerRailView: View {
    let kinds: [TimelineLayerRowKind]
    /// 中身と揃えるための縦スクロール量。
    let scrollOffset: Double
    let visibleHeight: CGFloat
    let selectedKind: TimelineLayerRowKind?
    let onSelect: (TimelineLayerRowKind) -> Void

    var body: some View {
        VStack(spacing: TimelineMetrics.trackSpacing) {
            ForEach(kinds) { kind in
                Button { onSelect(kind) } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(kind == selectedKind
                                         ? TimelinePalette.selection
                                         : TimelinePalette.secondaryText)
                        .frame(width: TimelineMetrics.layerRailWidth,
                               height: TimelineMetrics.layerRowHeight)
                        .background(Color.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius))
                }
                .buttonStyle(.plain)
                // **ドックの「モザイク」ボタンと同じ名前にしない。** 同名の要素が
                // 2 つあると UI テストの要素指定が曖昧になって落ちる（実際に落ちた）。
                // 人が読んでも「段の見出し」と「効果を開くボタン」は別物である。
                .accessibilityLabel("\(kind.title)の段")
                .accessibilityIdentifier("timeline.layerRail.\(kind.rawValue)")
            }
        }
        .offset(y: -scrollOffset)
        .frame(width: TimelineMetrics.layerRailWidth, height: visibleHeight, alignment: .top)
        .clipped()
        .accessibilityIdentifier("timeline.layerRail")
    }
}
