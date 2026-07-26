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

/// タイムラインの編集ツールバー。
///
/// **編集項目は横スクロール、`pinnedItems` は右端に固定**する。全項目を 1 本の
/// 横スクロールに並べると、概算 434pt に対し iPhone 16 の 393pt 幅では末尾 2 項目
/// （拡大・縮小）が**初期表示で画面外**に出て、存在に気づけない。
struct TimelineToolbarView: View {
    let items: [TimelineToolItem]
    /// 右端に常時見せる項目（ズーム）。空なら固定ゾーンごと出ない。
    let pinnedItems: [TimelineToolItem]

    init(items: [TimelineToolItem], pinnedItems: [TimelineToolItem] = []) {
        self.items = items
        self.pinnedItems = pinnedItems
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        if item.separatorBefore {
                            Divider().frame(height: 22)
                        }
                        button(item)
                    }
                }
                .padding(.horizontal, 16)
            }
            if !pinnedItems.isEmpty {
                Divider().frame(height: 22)
                HStack(spacing: 8) {
                    ForEach(pinnedItems) { button($0) }
                }
                // `ScrollView` は幅を取れるだけ取るので、固定ゾーンは理想幅で固定する
                // （でないと編集項目に押されて固定ゾーンまで潰れる）。
                .fixedSize()
                .padding(.trailing, 16)
            }
        }
    }

    private func button(_ item: TimelineToolItem) -> some View {
        Button(action: item.action) {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15))
                Text(item.title)
                    .font(.system(size: 8))
            }
            .frame(minWidth: 40)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.3)
        .accessibilityLabel(item.title)
    }
}

/// 目盛り + スクラブ帯。
///
/// スクラブ（横ドラッグでシーク）を**この帯だけ**に持たせることで、クリップ帯の
/// 素のドラッグを ScrollView の横スクロールに残せる（両方に付けると取り合いになる）。
/// 目盛り間隔は `TimelineGeometry.effectiveTickInterval(totalDuration:)`
/// （ズーム段から決まり、本数が多すぎる長尺では倍々に粗くなる純関数）。
struct TimelineRulerTrackView: View {
    let geometry: TimelineGeometry
    let totalDuration: Double
    let contentWidth: CGFloat
    /// 合成時刻（秒）でのシーク要求。
    let onScrub: (Double) -> Void
    /// スクラブ中かどうかの通知。
    ///
    /// スクラブは `onChanged` ごとに zero-tolerance seek を撃つ（= プレビューが
    /// デコーダを握り続ける）ため、この間はサムネイル生成を止める必要がある。
    /// `@GestureState` で持つことで**ジェスチャがキャンセルされても必ず false へ戻る**
    /// （`onEnded` は中断で呼ばれないので、そこだけに頼ると生成が永久に止まる）。
    let onScrubbingChanged: (Bool) -> Void

    @GestureState private var isScrubbing = false

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
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isScrubbing) { _, state, _ in state = true }
                .onChanged { value in onScrub(geometry.time(forX: Double(value.location.x))) }
        )
        .onChange(of: isScrubbing) { scrubbing in onScrubbingChanged(scrubbing) }
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
struct TimelinePlayheadView: View {
    let geometry: TimelineGeometry
    let time: Double

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: TimelineMetrics.stackHeight)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .offset(x: geometry.x(forTime: time) - 1)
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
