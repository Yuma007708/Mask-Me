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

/// タイムラインの横スクロール容器。**プレイヘッドは可視領域の中央に固定**する。
///
/// ビューポート観測・ピンチズーム・ズーム時の位置保持・プレイヘッド追従・
/// 「タイムラインを払ってシーク」をここにまとめる（トラックの中身は呼び出し側が組む）。
///
/// ## 中央固定の作り
///
/// コンテンツの左右に**可視幅の半分**の余白を付ける（`TimelineScrollMath.scrollOffsetBounds`）。
/// これで合成時刻 0 と終端の両方を画面中央へ持ってこられる。プレイヘッドの縦線は
/// スクロールしない別レイヤー（呼び出し側の `.overlay`）に置き、
/// **中身の位置が唯一の再生位置の表現**になる。
///
/// ## 押し合いを起こさない理由（ここが壊れると画面が震える）
///
/// 「スクロール → シーク」と「再生位置 → スクロール」の 2 方向があるが、
/// **プログラム由来のスクロールは着地点が必ず `x(playheadTime) - 可視幅/2`** なので、
/// 着地後に中央が指す時刻は現在の再生位置と一致する（`centeredTime` は
/// `centeredScrollOffset` の逆写像で、端でもクランプされずに往復する）。
/// したがって
/// - 中央の時刻が再生位置と一致していれば「プログラム由来 or 落ち着いた状態」→ シークしない
/// - 追従側も「目標 == 現在のスクロール量」なら撃たない
/// の 2 つの不動点判定だけでループが閉じる。ユーザー由来かを見分けるフラグは要らない。
/// 例外は並べ替え中の自動スクロール（中央の時刻を意図的に動かす）で、これは明示的に除外する。
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
    /// 再生中か。**追従は停止中も行う**（中央固定なので、外部シークでも中身を動かさないと
    /// 線と映像がずれる）。再生中だけ追従にアニメーションを掛け、スクロール由来シークの
    /// 判定を粗くする（アニメーションの遅れを指の操作と誤読しないため）。
    let isPlaying: Bool
    /// 並べ替えドラッグとの受け渡し口（指の x を受け、スクロール量を返す）。
    @ObservedObject var autoScroll: TimelineAutoScrollState
    /// 可視範囲・ズームが動いてサムネイル要求を積み直すべきときの通知。
    let onRefreshNeeded: () -> Void
    /// 中央のプレイヘッドが指す合成時刻へのシーク要求（秒）。
    /// 再生中に呼ばれたときは呼び出し側で再生を止めること（そうしないと追従と押し合う）。
    let onSeek: (Double) -> Void
    /// ユーザー由来のスクロールが始まった／落ち着いたの通知。
    /// スクロール中はシークを撃ち続ける（= プレビューがデコーダを握る）ので、
    /// 呼び出し側はサムネイル生成を止める。
    let onScrubbingChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    /// ピンチ開始時点の px/秒（倍率の基準）。終了・キャンセルで nil に戻す。
    @State private var pinchBase: Double?
    /// 最後に再要求を促したときの可視レンジ開始時刻（横スクロール判定用）。
    @State private var lastNotifiedVisibleStart = Double.infinity
    /// ピンチ倍率。**`@GestureState` なのでキャンセルで必ず 1 に戻る**
    /// （`onEnded` だけに頼ると中断時に基準 px/秒 が取り残されて次のピンチが飛ぶ）。
    @GestureState private var pinch: CGFloat = 1
    /// 並べ替え中の自動スクロールのループ。
    @State private var autoScrollTask: Task<Void, Never>?
    /// ユーザー由来のスクロールが続いているか（サムネイル抑止の通知用）。
    @State private var isUserScrolling = false
    /// スクロールが落ち着いたと判定するデバウンス。
    @State private var scrollSettleTask: Task<Void, Never>?
    /// 直近に見た可視幅。変わると余白（可視幅/2）も変わるので中央へ寄せ直す。
    @State private var lastVisibleWidth: Double = 0

    private static var scrollSpace: String { TimelineCoordinateSpace.scroll }
    private static var contentID: String { "timelineContent" }
    /// 停止中のシーク不感帯（px）。`scrollTo` の着地誤差と丸めを吸収する。
    private static var seekDeadZonePixels: Double { 1.5 }
    /// 再生中に「指で動かされた」と見なすずれ（秒）。追従アニメーション（0.15 秒）と
    /// 再生位置の更新間隔ぶんの遅れより十分大きく取る。
    private static var playingSeekThresholdSeconds: Double { 0.5 }
    /// スクロールが止まったと見なすまでの猶予（ナノ秒）。慣性が続く間は伸び続ける。
    private static var scrollSettleDelay: UInt64 { 160_000_000 }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                scrollView(visibleWidth: Double(outer.size.width))
                    .coordinateSpace(name: Self.scrollSpace)
                    // **`.gesture` ではなく `.simultaneousGesture`**。`.gesture` だと
                    // UIScrollView の pan と排他になり得て横スクロールが死ぬ。
                    .simultaneousGesture(pinchGesture)
                    .onPreferenceChange(TimelineScrollOffsetKey.self) {
                        update(scrollOffset: Double($0), visibleWidth: Double(outer.size.width),
                               proxy: proxy)
                    }
                    .onChange(of: geometry) { applyZoom($0, proxy: proxy) }
                    .onChange(of: playheadTime) { recenter(on: $0, proxy: proxy) }
                    // クリップ編集で全幅が変わると時刻→x が変わる。線は中央に固定なので
                    // ここで寄せ直さないと「線の位置と再生位置」がずれたままになる。
                    .onChange(of: contentWidth) { _ in recenter(on: playheadTime, proxy: proxy) }
                    .onChange(of: pinch) { if $0 == 1 { pinchBase = nil } }
                    .onChange(of: autoScroll.isDragging) { setAutoScroll(active: $0, proxy: proxy) }
                    .onDisappear {
                        autoScrollTask?.cancel()
                        scrollSettleTask?.cancel()
                    }
            }
        }
        .frame(height: TimelineMetrics.stackHeight)
    }

    private func scrollView(visibleWidth: Double) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) { content() }
                .frame(width: contentWidth, height: TimelineMetrics.stackHeight, alignment: .topLeading)
                // 計測は余白の**内側**に付ける（トラック内 x = 合成時刻 0 が原点。
                // `TimelineViewport` の座標系契約）。`.background` はレイアウトを変えない。
                .background(offsetProbe)
                .padding(.horizontal, CGFloat(Self.leadingInset(visibleWidth: visibleWidth)))
                // **`.id` は余白の外側**。`anchorUnitPointX(leadingInset:)` は
                // 「余白を含む全幅」を分母に分数を出すので、内側に付けると分母が食い違って
                // 着地点が余白ぶんずれる（= プレイヘッドが中央から外れる）。
                .id(Self.contentID)
        }
    }

    /// コンテンツ左右の余白。プレイヘッドを中央に固定するため可視幅の半分を取る。
    private static func leadingInset(visibleWidth: Double) -> Double {
        guard visibleWidth.isFinite, visibleWidth > 0 else { return 0 }
        return visibleWidth / 2
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
    /// 位置は `applyZoom` が「中央 = 再生位置」から補う。
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

    private func update(scrollOffset: Double, visibleWidth: Double, proxy: ScrollViewProxy) {
        // 進行中のジェスチャが読む値は再描画を挟まない参照型へも書く（`TimelineAutoScrollState`）。
        autoScroll.scrollOffset = scrollOffset
        let updated = TimelineViewport(scrollOffset: scrollOffset, visibleWidth: visibleWidth,
                                       contentWidth: Double(contentWidth))
        if updated != viewport {
            viewport = updated
            notifyRefreshIfVisibleRangeMoved(updated)
        }
        // 初回レイアウト（幅 0 → 実幅）と回転。余白が可視幅に依存するので、幅が変わると
        // 中央が指す時刻もずれる。下書き復元で再生位置が 0 でない場合もここで合わせる。
        // **`viewport` を読まずに引数の値で計算する**（`@Binding` への書き込みは
        // 同じ呼び出しの中では読み戻せないため）。
        if visibleWidth != lastVisibleWidth {
            lastVisibleWidth = visibleWidth
            recenter(on: playheadTime, proxy: proxy,
                     visibleWidth: visibleWidth, currentOffset: scrollOffset)
            return
        }
        seekIfCenterMoved(scrollOffset: scrollOffset, visibleWidth: visibleWidth, proxy: proxy)
    }

    /// 横スクロールでもサムネイルを積み直す。ただし**枠半分以上動いたときだけ**
    /// （毎フレーム通知すると全クリップ全スロットの走査 CPU を食う）。
    private func notifyRefreshIfVisibleRangeMoved(_ updated: TimelineViewport) {
        let start = TimelineScrollMath.visibleTimeRange(viewport: updated, geometry: geometry).lowerBound
        let threshold = geometry.duration(forWidth: Double(TimelineMetrics.thumbnailSlotWidth)) / 2
        guard threshold > 0, abs(start - lastNotifiedVisibleStart) >= threshold else { return }
        lastNotifiedVisibleStart = start
        onRefreshNeeded()
    }

    /// スクロール量から「中央が指す合成時刻」を出し、再生位置と違えばシークする。
    ///
    /// **プログラム由来かを見分けるフラグは持たない**（型の doc 参照）。追従・ズーム保持の
    /// 着地点はどちらも中央 = 再生位置なので、一致しない差分だけが指（と慣性）による移動。
    /// 並べ替え中の自動スクロールは中央の時刻を意図的に動かすため、ここでは除外する。
    private func seekIfCenterMoved(scrollOffset: Double, visibleWidth: Double,
                                   proxy: ScrollViewProxy) {
        guard totalDuration > 0, visibleWidth > 0, !autoScroll.isDragging else { return }
        let center = TimelineScrollMath.centeredTime(scrollOffset: scrollOffset, geometry: geometry,
                                                     visibleWidth: visibleWidth,
                                                     totalDuration: totalDuration)
        let deviation = abs(center - playheadTime)
        if isPlaying {
            // 再生中は追従アニメーションのぶん常に少し遅れている。指の操作と区別できる
            // 大きさを超えたときだけシークする（呼び出し側が再生を止める）。
            guard deviation > Self.playingSeekThresholdSeconds else { return }
        } else {
            guard deviation > geometry.duration(forWidth: Self.seekDeadZonePixels) else { return }
        }
        markUserScrolling(proxy: proxy)
        onSeek(center)
    }

    /// スクロール中フラグを立て、止まったら下ろす（デバウンス）。
    ///
    /// 下ろすときに**中央の再点検を 1 回だけ入れる**。指と慣性が動いている間は
    /// `recenter` を撃たない（押し返さないため）ので、その最中に外部シーク
    /// （undo による尺クランプなど）が来ると線の位置と再生位置がずれたまま残る。
    /// 止まった直後に再点検すれば、通常は目標 == 現在位置で no-op のまま、
    /// ずれた場合だけ自己修復する。
    private func markUserScrolling(proxy: ScrollViewProxy) {
        if !isUserScrolling {
            isUserScrolling = true
            onScrubbingChanged(true)
        }
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.scrollSettleDelay)
            guard !Task.isCancelled else { return }
            isUserScrolling = false
            onScrubbingChanged(false)
            recenter(on: playheadTime, proxy: proxy)
        }
    }

    /// ズーム変更の**唯一の入口**。プレイヘッド（= 中央）を留めたまま px/秒 を変える。
    ///
    /// 中央固定では見ている位置は常に再生位置なので、`TimelineScrollMath.zoomAnchor` の
    /// ような「可視外なら可視中心」の分岐は不要（分岐させると、線が中央にあるまま
    /// 別の時刻を指す状態が作れてしまう）。`lastGeometry` は次のズームのために更新し続ける。
    private func applyZoom(_ newGeometry: TimelineGeometry, proxy: ScrollViewProxy) {
        defer { onRefreshNeeded() }
        let visibleWidth = viewport.visibleWidth
        guard visibleWidth > 0 else { return }
        let width = max(newGeometry.width(forDuration: totalDuration), 1)
        let offset = TimelineScrollMath.centeredScrollOffset(time: playheadTime, geometry: newGeometry,
                                                            contentWidth: width,
                                                            visibleWidth: visibleWidth)
        scroll(proxy: proxy, to: offset, contentWidth: width, visibleWidth: visibleWidth)
    }

    /// 再生位置を可視領域の中央へ持ってくる（`onChange` からの入口。`viewport` を読む）。
    private func recenter(on time: Double, proxy: ScrollViewProxy) {
        recenter(on: time, proxy: proxy,
                 visibleWidth: viewport.visibleWidth, currentOffset: viewport.scrollOffset)
    }

    /// 同上。可視幅と現在のスクロール量を明示的に受ける版。
    ///
    /// **すでに中央に居るなら撃たない**のが押し合い防止の核心。スクロール由来シークの
    /// 直後は「現在のスクロール量から逆算した時刻」へシークしているので着地点が一致し、
    /// ここで必ず止まる（指を押し返さない）。
    private func recenter(on time: Double, proxy: ScrollViewProxy,
                          visibleWidth: Double, currentOffset: Double) {
        // 指と慣性が動いている間はプログラムから動かさない（`scrollTo` を撃つと
        // ドラッグ中の UIScrollView と押し合って引っかかる）。落ち着いた時点で
        // `markUserScrolling` の再点検が最終状態を保証する。
        guard visibleWidth > 0, !isUserScrolling else { return }
        let width = Double(contentWidth)
        let target = TimelineScrollMath.centeredScrollOffset(time: time, geometry: geometry,
                                                            contentWidth: width,
                                                            visibleWidth: visibleWidth)
        guard abs(target - currentOffset) >= 0.5 else { return }
        guard isPlaying else {
            scroll(proxy: proxy, to: target, contentWidth: width, visibleWidth: visibleWidth)
            return
        }
        // 再生中だけ滑らかに寄せる（再生位置の更新は描画フレーム単位で、
        // 端末が重いと間隔が開くため。停止中は即時 = 指の動きに遅れを入れない）。
        withAnimation(.linear(duration: 0.15)) {
            scroll(proxy: proxy, to: target, contentWidth: width, visibleWidth: visibleWidth)
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
        // 可動域は中央固定の余白ぶん左右へ広い（`0...width - visible` に切ると、
        // 先頭・終端のクリップを画面中央まで運べなくなる）。
        let bounds = TimelineScrollMath.scrollOffsetBounds(
            contentWidth: width, visibleWidth: visible,
            leadingInset: Self.leadingInset(visibleWidth: visible))
        let target = min(max(current + velocity * TimelineAutoScrollTuning.tick, bounds.lowerBound),
                         bounds.upperBound)
        // 端に張り付いたら何もしない（`scrollTo` を撃ち続けても位置は変わらない）。
        guard abs(target - current) >= 0.5 else { return }
        scroll(proxy: proxy, to: target, contentWidth: width, visibleWidth: visible)
    }

    private func scroll(proxy: ScrollViewProxy, to offset: Double,
                        contentWidth width: Double, visibleWidth: Double) {
        let unit = TimelineScrollMath.anchorUnitPointX(
            scrollOffset: offset, contentWidth: width, visibleWidth: visibleWidth,
            leadingInset: Self.leadingInset(visibleWidth: visibleWidth))
        proxy.scrollTo(Self.contentID, anchor: UnitPoint(x: unit, y: 0))
    }
}
