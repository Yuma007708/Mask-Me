import MosaicCore
import SwiftUI

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
                .fill(Color.white.opacity(0.04))
                .frame(width: contentWidth, height: TimelineMetrics.rulerHeight)
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

    private func tick(_ index: Int) -> some View {
        let time = Double(index) * interval
        return HStack(spacing: 2) {
            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 1, height: 6)
            Text(Self.timeLabel(time))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .offset(x: geometry.x(forTime: time))
    }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
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
            .fill(Color.white)
            .frame(width: 2, height: stackHeight)
            // 中央固定のプレイヘッドは動かないので、「ここが再生位置」と読ませる
            // 目印を上端に付ける（線だけだと目盛りの一本と区別しにくい）。
            .overlay(alignment: .top) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .offset(y: -4)
            }
            .shadow(color: .black.opacity(0.6), radius: 2)
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
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            )
    }
}
