import MosaicCore
import SwiftUI

/// タイムラインの見た目を決める色・文字の唯一の置き場。
///
/// **色を直接書かないこと。** 以前は同じ「白の薄い地」が段ごとに 0.04 / 0.06 と
/// 微妙に違い、アクセントは `accentColor`（モザイク区間）・`yellow`（継ぎ目）・
/// `orange`（キーフレーム）の 3 系統に散っていた。どの色が何を意味するのかが
/// 読めず、結果として「作りが雑」に見える。ここへ集約して意味ごとに色を決める。
///
/// 意味の割り当て:
/// - **アクセント**（`mosaic`）= モザイクが掛かること。この 1 系統だけが彩度を持つ。
/// - **構造**（`structure`）= 継ぎ目・キーフレームなど「編集の目印」。琥珀 1 色に統一。
/// - **選択**（`selection`）= 白。枠とハンドルだけに使う。属性の色と混ぜない。
enum TimelinePalette {
    /// 段の地。**上から下へ少しずつ明るくする**（目盛り→クリップ帯→モザイク区間）。
    /// 全段を同じ濃さにすると 3 本の段が 1 枚の板に見えて構造が読めない。
    static let rulerBackground = Color.white.opacity(0.03)
    static let clipBandBackground = Color.white.opacity(0.07)
    static let applyTrackBackground = Color.white.opacity(0.05)

    /// モザイク（適用区間）。選択で濃くなる。
    static func mosaicFill(isSelected: Bool) -> Color {
        Color.accentColor.opacity(isSelected ? 0.9 : 0.55)
    }

    /// 編集の目印（継ぎ目ボタン・キーフレーム）。
    static let structure = Color(red: 1.0, green: 0.78, blue: 0.35)

    static let selection = Color.white
    /// 非選択クリップの輪郭。段の地より明るく、選択枠よりはるかに暗い。
    static let clipOutline = Color.white.opacity(0.22)

    /// 目盛りの主線（ラベルが付く）と副線（付かない）。
    static let tickMajor = Color.white.opacity(0.55)
    static let tickMinor = Color.white.opacity(0.18)

    /// 文字。**3 段しか使わない**（ラベル / バッジ / 補助）。
    static let labelFont = Font.system(size: 9, weight: .semibold).monospacedDigit()
    static let badgeFont = Font.system(size: 9, weight: .semibold)
    static let hintFont = Font.system(size: 10, weight: .medium)

    static let primaryText = Color.white.opacity(0.9)
    static let secondaryText = Color.white.opacity(0.45)

    /// 音声波形。**アクセント（モザイク）にも構造（目印）にも寄せない。**
    /// 波形は「素材にもともと入っているもの」で、編集の状態を表さないため、
    /// 色を持たせると意味のない主張になる。
    static let waveform = Color.white.opacity(0.55)
}

/// 編集ツールバーの 1 項目。
struct TimelineToolItem: Identifiable {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    /// 直前に区切り線を入れるか（操作の系統を目で分けるため）。
    let separatorBefore: Bool
    let action: () -> Void

    var id: String { title }

    init(title: String, systemImage: String, isEnabled: Bool,
         separatorBefore: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.separatorBefore = separatorBefore
        self.action = action
    }
}

/// ドックの `root` 段に並ぶ編集項目（`EditorDockView` の中身のひとつ）。
///
/// **並びは選択状態で変えない**（`VideoTimelineView.toolItems` の doc 参照）。
/// 幅に収まる 5 項目のうしろに、収まらない項目（前へ／後へ・ズーム・モザイク区間）を
/// 横スクロールで続ける。項目を絞って落とすのではなく、順序で優先度を付ける形。
struct TimelineToolbarView: View {
    let items: [TimelineToolItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    if item.separatorBefore {
                        Divider().frame(height: 26)
                    }
                    button(item)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: TimelineMetrics.toolbarHeight)
        }
        .frame(height: TimelineMetrics.toolbarHeight)
    }

    private func button(_ item: TimelineToolItem) -> some View {
        Button(action: item.action) {
            VStack(spacing: 1) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20))
                Text(item.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(minWidth: 52)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.3)
        .accessibilityLabel(item.title)
    }
}

/// 目盛り帯（表示専用）。
///
/// **シークのジェスチャは持たない。** プレイヘッドを可視領域の中央に固定した後は
/// 「タイムラインを払う = シーク」であり、指の位置の絶対時刻へ飛ばす操作は矛盾する
/// （線は中央にあるまま別の時刻を指す状態が作れてしまう）。そのため目盛り帯の上の
/// 素のドラッグは横スクロールへ通し、シークは `TimelineScrollContainer` が
/// スクロール量から逆算する。
///
/// 目盛り間隔は `TimelineGeometry.effectiveTickInterval(totalDuration:)`
/// （ズーム段から決まり、本数が多すぎる長尺では倍々に粗くなる純関数）。
struct TimelineRulerTrackView: View {
    let geometry: TimelineGeometry
    let totalDuration: Double
    let contentWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(TimelinePalette.rulerBackground)
                .frame(width: contentWidth, height: TimelineMetrics.rulerHeight)
            // 副目盛り（主目盛りの中間）。ラベルは付けない。
            // **これが無いと、主目盛りの間隔が 5s・10s と粗くなる長尺で
            // 「いま何秒あたりか」を読む手がかりが線 1 本ぶんも無くなる。**
            ForEach(minorTickIndices, id: \.self) { index in
                minorTick(Double(index) * interval + interval / 2)
            }
            ForEach(tickIndices, id: \.self) { index in
                tick(index)
            }
        }
        .frame(height: TimelineMetrics.rulerHeight, alignment: .topLeading)
    }

    /// 実効間隔（本数上限で粗くしたもの）。目盛りは `ZStack` + `.offset` で
    /// 見た目だけずらしており**レイアウト上は全員 x=0** なので、`scrollTo` の対象には
    /// できない（親のプレイヘッド追従はコンテンツ全体の id + 分数 `UnitPoint` で行う）。
    private var interval: Double { geometry.effectiveTickInterval(totalDuration: totalDuration) }

    private var tickIndices: [Int] {
        guard totalDuration > 0, interval > 0 else { return [0] }
        let count = Int((totalDuration / interval).rounded(.down))
        return Array(0...max(0, count))
    }

    /// 副目盛りは主目盛りの**間**にだけ立てる（最後の主目盛りの先は総尺を超えうるので除く）。
    private var minorTickIndices: [Int] {
        guard tickIndices.count > 1 else { return [] }
        return Array(tickIndices.dropLast())
    }

    private func minorTick(_ time: Double) -> some View {
        Rectangle()
            .fill(TimelinePalette.tickMinor)
            .frame(width: 1, height: 4)
            .offset(x: geometry.x(forTime: time))
    }

    private func tick(_ index: Int) -> some View {
        let time = Double(index) * interval
        return HStack(spacing: 3) {
            Rectangle()
                .fill(TimelinePalette.tickMajor)
                .frame(width: 1, height: 7)
            Text(Self.timeLabel(time, interval: interval))
                .font(TimelinePalette.labelFont)
                .foregroundStyle(TimelinePalette.primaryText)
        }
        .offset(x: geometry.x(forTime: time))
    }

    /// 目盛りのラベル。
    ///
    /// **`interval` を受け取るのは、秒未満の間隔（ズーム最大では 0.5s）で
    /// 隣り合うラベルが同じ文字になるため。** 0.5s 刻みで `0:00 0:00 0:01 0:01 …`
    /// と並ぶと、目盛りが 2 本に 1 本しか意味を持たない（＝読めない）。
    static func timeLabel(_ seconds: Double, interval: Double = 1) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        if interval.isFinite, interval > 0, interval < 1 {
            let whole = Int(seconds)
            let fraction = Int(((seconds - Double(whole)) * 10).rounded())
            // 繰り上がり（9.96 → 10.0）でも "0:09.10" にならないよう秒へ戻す。
            let carried = whole + fraction / 10
            return String(format: "%d:%02d.%d", carried / 60, carried % 60, fraction % 10)
        }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// タイムラインへの素材追加（動画・写真）のピッカー（S10a）。
///
/// 動画も写真も同じ 1 枚のピッカーから取り込む（`.videosAndImages`）。写真は
/// `appendPhotoClip` が `PhotoClipEncoder` で静止 mp4 へ落として動画と同じ経路に合流する。
///
/// **追加は選ばれた順に 1 本ずつ直列で await する。** 素材ごとに `Task` を立てると
/// 実行順が保証されず、タイムラインへ並ぶ順序が非決定になる（`appendVideoClip` /
/// `appendPhotoClip` はどちらも尺取得・エンコードで中断する）。ピッカー側も
/// 完了順ではなく選択順で返す契約になっている（`MediaPicker.Coordinator`）。
struct TimelineMediaAppendPicker: View {
    @ObservedObject var model: MosaicEditorModel
    let onFinish: () -> Void

    /// 一度に選べる件数の上限。追加はどれも実素材のデコード（尺取得・検出シード・
    /// composition 再構築）を伴うので無制限（PHPicker の 0）にはしない。
    private static let selectionLimit = 10

    var body: some View {
        MediaPicker(filter: .videosAndImages,
                    selectionLimit: Self.selectionLimit,
                    onFailure: { model.errorMessage = $0 },
                    onPick: append)
            .ignoresSafeArea()
    }

    private func append(_ picked: [PickedMedia]) {
        onFinish()
        guard !picked.isEmpty else { return }
        Task {
            for media in picked {
                switch media {
                case let .image(image): await model.appendPhotoClip(image: image)
                case let .video(url): await model.appendVideoClip(url: url)
                }
            }
        }
    }
}

/// プレイヘッド（全トラックを貫く縦線）。ヒットテストしない（下の帯の操作を邪魔しない）。
///
/// **時刻を受け取らない。** 位置は常に可視領域の中央で、時刻は「中身がどれだけ
/// スクロールしているか」だけが表す（`TimelineScrollContainer` の中央固定）。
/// そのためこの View は**スクロールする中身の外側**（呼び出し側の `.overlay`）に置く。
struct TimelinePlayheadView: View {
    /// 貫くトラックの高さ。継ぎ目レーンの有無で変わるので受け取る
    /// （`TimelineMetrics.stackHeight(hasJoints:)` から採ること）。
    let stackHeight: CGFloat

    var body: some View {
        Rectangle()
            .fill(TimelinePalette.selection)
            .frame(width: 2, height: stackHeight)
            // 中央固定のプレイヘッドは動かないので、「ここが再生位置」と読ませる
            // 目印を上端に付ける（線だけだと目盛りの一本と区別しにくい）。
            //
            // 目印は**丸い頭**にしてある。三角は目盛りの主線＋ラベルと同じ「上向きの
            // 細い形」の中に紛れるが、円は目盛り帯の中で唯一の曲線になるので、
            // 走査したときに一発で見つかる。
            .overlay(alignment: .top) {
                Circle()
                    .fill(TimelinePalette.selection)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
                    .offset(y: -3)
            }
            .shadow(color: .black.opacity(0.75), radius: 2.5)
            .allowsHitTesting(false)
    }
}

/// クリップが 1 本も無いときのプレースホルダ帯。
struct TimelineEmptyBandView: View {
    let contentWidth: CGFloat
    let text: String

    var body: some View {
        RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius)
            .fill(Color.black.opacity(0.4))
            .frame(width: contentWidth, height: TimelineMetrics.clipHeight)
            .overlay(
                RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius)
                    .strokeBorder(TimelinePalette.clipOutline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .overlay(
                Text(text)
                    .font(TimelinePalette.hintFont)
                    .foregroundStyle(TimelinePalette.secondaryText)
            )
    }
}
