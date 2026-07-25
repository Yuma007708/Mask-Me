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

/// タイムラインの編集ツールバー（横スクロール）。
struct TimelineToolbarView: View {
    let items: [TimelineToolItem]

    var body: some View {
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

/// 目盛りのスクロール識別子（`ScrollViewReader.scrollTo` の対象）。
struct TimelineTickID: Hashable {
    let index: Int
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

    /// 実効間隔（本数上限で粗くしたもの）。親のプレイヘッド追従も同じ値を使う。
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
        .id(TimelineTickID(index: index))
        .offset(x: geometry.x(forTime: time))
    }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
