import MosaicCore
import SwiftUI

// タイムラインの横スクロール容器と、その周辺（座標空間名・自動スクロールの
// 受け渡し口と調整値・スクロール量の PreferenceKey）。
// `TimelineChromeViews.swift` から切り出したのは、スクロール／ズーム／自動スクロールが
// 互いに前提を共有する 1 つのまとまりで、ツールバーや帯とは変更理由が別なため。

/// タイムラインの座標空間名。
///
/// スクロールビュー自身に付ける名前。ここで受けたジェスチャの `location.x` は
/// **可視領域左端からの px**（= 自動スクロールの入力）になり、`translation` は
/// コンテンツの移動に影響されない純粋な指の移動量になる。
enum TimelineCoordinateSpace {
    static let scroll = "timelineScroll"
}

/// 並べ替えドラッグと横スクロール容器のあいだで、**再描画を伴わずに**受け渡す値。
///
/// 指の x とスクロール量は 60Hz で書き換わる。`@Published` にするとタイムライン全体が
/// 毎フレーム再評価されるため、**変化を通知するのは `isDragging` だけ**にしてある
/// （自動スクロールのループを起こす／止めるのに必要な 1 ビット。ジェスチャ 1 回につき
/// 2 回しか変わらない）。ループ側は毎ティック `fingerX` をポーリングする。
///
/// `scrollOffset` を View の `let` プロパティで渡さないのは、進行中のジェスチャが
/// 掴んでいるクロージャが body 再評価前の古い値を握り得るため（参照型なら常に最新）。
final class TimelineAutoScrollState: ObservableObject {
    /// 並べ替えドラッグ中か。自動スクロールのループはこれだけを見て起動・停止する。
    @Published private(set) var isDragging = false
    /// 可視領域左端からの指の x（px）。
    private(set) var fingerX: Double = 0
    /// 現在の横スクロール量（トラック内 x, px）。容器が毎フレーム書き込む。
    var scrollOffset: Double = 0

    func updateDrag(fingerX: Double) {
        self.fingerX = fingerX
        if !isDragging { isDragging = true }
    }

    func endDrag() {
        if isDragging { isDragging = false }
    }
}

/// 自動スクロールの調整値。
///
/// **`TimelineScrollContainer` の static にはできない**（ジェネリック型に格納型の
/// static プロパティは置けない）。
enum TimelineAutoScrollTuning {
    /// 自動スクロールが立ち上がる端の帯（px）。
    static let edgeInset: Double = 44
    /// 端での最大速度（px/秒）。
    static let maximumSpeed: Double = 600
    /// 1 ティック（秒 / ナノ秒）。
    static let tick: Double = 1.0 / 60
    static let tickNanoseconds: UInt64 = 16_666_667
}

/// 横スクロール量（トラック内 x = 合成時刻 0 が原点）の伝達。
///
/// 計測子はコンテンツの `.padding(.horizontal, 16)` の**内側**に置くこと
/// （`TimelineViewport` の座標系契約。外側に置くと余白ぶん恒常的にずれる）。
/// 値は複数の計測子を想定しないので、最後に流れてきた 1 個をそのまま採る。
struct TimelineScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// タイムラインの横スクロール容器。
///
/// ビューポート観測・ピンチズーム・ズーム時のアンカー保持・再生中のプレイヘッド追従を
/// ここにまとめる（トラックの中身は呼び出し側が組む）。
///
/// **iOS 16 でスクロール位置を作れるのは `scrollTo(id:anchor:)` だけ**
/// （`.scrollPosition` も `contentOffset` の直接指定も iOS 17+）。そこで
/// **コンテンツ全体に単一の id** を付け、`anchor` の x を分数にすることで
/// 「任意の時刻を任意のビューポート x に置く」を実現している。目盛りごとの id は使えない:
/// tick は `ZStack` + `.offset` で見た目だけずらしており、レイアウト上は全員 x=0 なので
/// `scrollTo` が index に関わらず同じ位置を狙い、先頭にクランプされた後は no-op になる。
struct TimelineScrollContainer<Content: View>: View {
    /// 現在のズーム。ピンチはここへ書き戻す（`+`/`-` ボタンからの変更も同じ経路に入る）。
    @Binding var geometry: TimelineGeometry
    /// 観測したビューポート（トラック内 x 座標系）。
    @Binding var viewport: TimelineViewport
    let contentWidth: CGFloat
    let totalDuration: Double
    let playheadTime: Double
    /// プレイヘッドを追うか（一時停止中に自動スクロールするとユーザー操作と喧嘩する）。
    let isFollowingPlayhead: Bool
    /// 並べ替えドラッグとの受け渡し口（指の x を受け、スクロール量を返す）。
    @ObservedObject var autoScroll: TimelineAutoScrollState
    /// 可視範囲・ズームが動いてサムネイル要求を積み直すべきときの通知。
    let onRefreshNeeded: () -> Void
    @ViewBuilder let content: () -> Content

    /// `onChange(of: geometry)` で「変更前」を知るための明示的な退避。
    /// iOS 16 の 1 引数 `onChange` は旧値を渡さないので、これが無いとアンカー計算が
    /// 新旧混在で狂う。**必ず `applyZoom` の先頭で更新する**。
    @State private var lastGeometry = TimelineGeometry()
    /// ピンチ開始時点の px/秒（倍率の基準）。終了・キャンセルで nil に戻す。
    @State private var pinchBase: Double?
    /// 最後に再要求を促したときの可視レンジ開始時刻（横スクロール判定用）。
    @State private var lastNotifiedVisibleStart = Double.infinity
    /// ピンチ倍率。**`@GestureState` なのでキャンセルで必ず 1 に戻る**
    /// （`onEnded` だけに頼ると中断時に基準 px/秒 が取り残されて次のピンチが飛ぶ）。
    @GestureState private var pinch: CGFloat = 1
    /// 並べ替え中の自動スクロールのループ。
    @State private var autoScrollTask: Task<Void, Never>?

    private static var scrollSpace: String { TimelineCoordinateSpace.scroll }
    private static var contentID: String { "timelineContent" }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                scrollView
                    .coordinateSpace(name: Self.scrollSpace)
                    // **`.gesture` ではなく `.simultaneousGesture`**。`.gesture` だと
                    // UIScrollView の pan と排他になり得て横スクロールが死ぬ。
                    .simultaneousGesture(pinchGesture)
                    .onPreferenceChange(TimelineScrollOffsetKey.self) {
                        update(scrollOffset: Double($0), visibleWidth: Double(outer.size.width))
                    }
                    .onChange(of: geometry) { applyZoom($0, proxy: proxy) }
                    .onChange(of: playheadTime) { followPlayhead($0, proxy: proxy) }
                    .onChange(of: pinch) { if $0 == 1 { pinchBase = nil } }
                    .onChange(of: autoScroll.isDragging) { setAutoScroll(active: $0, proxy: proxy) }
                    .onDisappear { autoScrollTask?.cancel() }
            }
        }
        .frame(height: TimelineMetrics.stackHeight)
    }

    private var scrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) { content() }
                .frame(width: contentWidth, height: TimelineMetrics.stackHeight, alignment: .topLeading)
                .id(Self.contentID)
                // 計測は `.padding` の**内側**に付ける（トラック内 x = 合成時刻 0 が原点。
                // `TimelineViewport` の座標系契約）。`.background` はレイアウトを変えない。
                .background(offsetProbe)
                .padding(.horizontal, 16)
        }
    }

    /// スクロール量の計測子。`-minX` が「トラック内 x のスクロール量」になる
    /// （先頭余白が見えている間・ラバーバンド中は負。符号は潰さない）。
    private var offsetProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TimelineScrollOffsetKey.self,
                                   value: -proxy.frame(in: .named(Self.scrollSpace)).minX)
        }
    }

    /// ピンチズーム。iOS 16 には位置つきの `MagnifyGesture` が無いので倍率だけを受け、
    /// 位置は `applyZoom` が `TimelineScrollMath.zoomAnchor` で補う。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onChanged { value in
                let base = pinchBase ?? geometry.pixelsPerSecond
                pinchBase = base
                geometry = TimelineGeometry(
                    pixelsPerSecond: TimelineScrollMath.pixelsPerSecond(base: base,
                                                                        magnification: Double(value)))
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func update(scrollOffset: Double, visibleWidth: Double) {
        // 進行中のジェスチャが読む値は再描画を挟まない参照型へも書く（`TimelineAutoScrollState`）。
        autoScroll.scrollOffset = scrollOffset
        let updated = TimelineViewport(scrollOffset: scrollOffset, visibleWidth: visibleWidth,
                                       contentWidth: Double(contentWidth))
        guard updated != viewport else { return }
        viewport = updated
        // 横スクロールでもサムネイルを積み直す。ただし**枠半分以上動いたときだけ**
        // （毎フレーム通知すると全クリップ全スロットの走査 CPU を食う）。
        let start = TimelineScrollMath.visibleTimeRange(viewport: updated, geometry: geometry).lowerBound
        let threshold = geometry.duration(forWidth: Double(TimelineMetrics.thumbnailSlotWidth)) / 2
        guard threshold > 0, abs(start - lastNotifiedVisibleStart) >= threshold else { return }
        lastNotifiedVisibleStart = start
        onRefreshNeeded()
    }

    /// ズーム変更の**唯一の入口**。見ていた位置（プレイヘッド、可視外なら可視中心）を
    /// 同じビューポート x に留めたまま px/秒 を変える。
    private func applyZoom(_ newGeometry: TimelineGeometry, proxy: ScrollViewProxy) {
        let previous = lastGeometry
        lastGeometry = newGeometry
        defer { onRefreshNeeded() }
        let visibleWidth = viewport.visibleWidth
        guard visibleWidth > 0 else { return }
        let anchor = TimelineScrollMath.zoomAnchor(playheadTime: playheadTime,
                                                   viewport: viewport, geometry: previous)
        let width = max(newGeometry.width(forDuration: totalDuration), 1)
        let offset = TimelineScrollMath.scrollOffset(anchorTime: anchor.time,
                                                     anchorViewportX: anchor.viewportX,
                                                     geometry: newGeometry, contentWidth: width,
                                                     visibleWidth: visibleWidth)
        scroll(proxy: proxy, to: offset, contentWidth: width, visibleWidth: visibleWidth)
    }

    private func followPlayhead(_ time: Double, proxy: ScrollViewProxy) {
        guard isFollowingPlayhead, viewport.visibleWidth > 0 else { return }
        let width = Double(contentWidth)
        let offset = TimelineScrollMath.scrollOffset(anchorTime: time,
                                                     anchorViewportX: viewport.visibleWidth / 2,
                                                     geometry: geometry, contentWidth: width,
                                                     visibleWidth: viewport.visibleWidth)
        withAnimation(.linear(duration: 0.15)) {
            scroll(proxy: proxy, to: offset, contentWidth: width, visibleWidth: viewport.visibleWidth)
        }
    }

    // MARK: - 並べ替え中の自動スクロール

    /// 自動スクロールのループを起こす／止める。
    ///
    /// 起動条件は `isDragging` の立ち上がりだけ（指の x は毎フレーム変わるので、
    /// それを `onChange` の対象にするとループが毎フレーム作り直しになる）。
    private func setAutoScroll(active: Bool, proxy: ScrollViewProxy) {
        autoScrollTask?.cancel()
        guard active else {
            autoScrollTask = nil
            return
        }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: TimelineAutoScrollTuning.tickNanoseconds)
                guard !Task.isCancelled else { return }
                stepAutoScroll(proxy: proxy)
            }
        }
    }

    /// 1 ティックぶん送る。速度は `TimelineScrollMath.autoScrollVelocity`（純関数）。
    @MainActor
    private func stepAutoScroll(proxy: ScrollViewProxy) {
        let visible = viewport.visibleWidth
        guard autoScroll.isDragging, visible > 0 else { return }
        let velocity = TimelineScrollMath.autoScrollVelocity(
            fingerX: autoScroll.fingerX, visibleWidth: visible,
            edgeInset: TimelineAutoScrollTuning.edgeInset,
            maximumSpeed: TimelineAutoScrollTuning.maximumSpeed)
        guard velocity != 0 else { return }
        let width = Double(contentWidth)
        let current = viewport.scrollOffset
        let target = min(max(current + velocity * TimelineAutoScrollTuning.tick, 0), max(0, width - visible))
        // 端に張り付いたら何もしない（`scrollTo` を撃ち続けても位置は変わらない）。
        guard abs(target - current) >= 0.5 else { return }
        scroll(proxy: proxy, to: target, contentWidth: width, visibleWidth: visible)
    }

    private func scroll(proxy: ScrollViewProxy, to offset: Double,
                        contentWidth width: Double, visibleWidth: Double) {
        let unit = TimelineScrollMath.anchorUnitPointX(scrollOffset: offset, contentWidth: width,
                                                       visibleWidth: visibleWidth)
        proxy.scrollTo(Self.contentID, anchor: UnitPoint(x: unit, y: 0))
    }
}
