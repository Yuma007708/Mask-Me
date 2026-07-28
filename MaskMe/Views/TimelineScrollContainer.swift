import MosaicCore
import SwiftUI

// タイムラインの横スクロール容器。
// `TimelineChromeViews.swift` から切り出したのは、スクロール／ズーム／自動スクロールが
// 互いに前提を共有する 1 つのまとまりで、ツールバーや帯とは変更理由が別なため。
// 容器とジェスチャ側で共有する語彙（座標空間名・`TimelineAutoScrollState`・
// 自動スクロールの調整値・スクロール量の PreferenceKey・`blocksTimelinePan`）は
// `TimelineReorderRecognizer.swift` にある（file_length のため逃がした。
// 新規ファイルの追加には `xcodegen generate` = CocoaPods 統合の再構築が要る）。

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
/// 「スクロール → シーク」と「再生位置 → スクロール」の 2 方向がある。値の一致だけで
/// ループを閉じようとすると**止まらない往復になる**（実測。ユーザー報告
/// 「シークの仕方によってクリップが左右に動いて止まらない」）。理由は 2 つ:
///
/// - シークの往復が**恒等写像ではない**。`MosaicPreviewController.seek(to:)` は描画後に
///   `playbackPosition` を「実際に返ってきたフレームの時刻」で上書きするので
///   （フレーム格子へ量子化され、1〜3 コマ遅れることもある）、中央の時刻へシークしても
///   再生位置はその値に戻ってこない。
/// - `scrollTo(anchor:)` には**着地誤差**がある。誤差が不感帯（`seekDeadZonePixels`）を
///   超えると、追従の着地がそのままシーク要求に化ける。
///
/// この 2 つが噛み合うと「追従 → 着地誤差 → シーク → 量子化で元のフレーム → 追従」が
/// 閉じず回り続ける。そこで**プログラム由来のスクロールを明示的に印付けする**
/// （`programmaticScrollDeadline`）: 追従・ズーム保持が撃ったスクロールの着地は
/// シークに変換しない。指が触れている間はこの印を無視するので、ユーザーの払いは
/// 1px も取りこぼさない（`recenter` 自身が指と慣性の間は撃たないため、
/// 操作中にこの印が立つことはない）。
/// あわせて追従側も「目標 == 現在のスクロール量」なら撃たない。
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
    /// 積んだトラックの高さ。継ぎ目レーンの有無で変わるので受け取る
    /// （`TimelineMetrics.stackHeight(hasJoints:)` から採ること。プレイヘッドの縦線と
    /// 同じ値でなければ線がはみ出す）。
    let stackHeight: CGFloat
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
    /// 指がタイムラインを払っている最中か。
    ///
    /// **これが無いと再生中のスワイプが効かない。** 再生中は再生位置の更新ごとに
    /// 中央へ引き戻しているため、指が動かしたぶんが毎フレーム打ち消されて
    /// 「指の操作」と判定できる差が永久に溜まらない。触っている間は引き戻しを止める。
    /// `@GestureState` なのでキャンセル・中断でも必ず false へ戻る。
    @GestureState private var isTouchDragging = false
    /// 並べ替え中の自動スクロールのループ。
    @State private var autoScrollTask: Task<Void, Never>?
    /// ユーザー由来のスクロールが続いているか（サムネイル抑止の通知用）。
    @State private var isUserScrolling = false
    /// スクロールが落ち着いたと判定するデバウンス。
    @State private var scrollSettleTask: Task<Void, Never>?
    /// 直近に見た可視幅。変わると余白（可視幅/2）も変わるので中央へ寄せ直す。
    @State private var lastVisibleWidth: Double = 0
    /// プログラム由来のスクロール（追従・ズーム保持）が落ち着くまでの猶予の終わり。
    /// この間に届いたスクロール量はシーク要求に変換しない（型の doc 参照）。
    @State private var programmaticScrollDeadline: Date?

    private static var scrollSpace: String { TimelineCoordinateSpace.scroll }
    private static var contentID: String { "timelineContent" }
    /// 停止中のシーク不感帯（px）。`scrollTo` の着地誤差と丸めを吸収する。
    private static var seekDeadZonePixels: Double { 1.5 }
    /// 再生中に「指で動かされた」と見なすずれ（秒）。追従アニメーション（0.15 秒）と
    /// 再生位置の更新間隔ぶんの遅れより十分大きく取る。
    private static var playingSeekThresholdSeconds: Double { 0.5 }
    /// スクロールが止まったと見なすまでの猶予（ナノ秒）。慣性が続く間は伸び続ける。
    private static var scrollSettleDelay: UInt64 { 160_000_000 }
    /// プログラム由来スクロールの着地を待つ猶予（秒）。追従アニメーション（0.15 秒）が
    /// 吐く途中の位置まで覆える長さにする（途中位置をシークと読むと押し合う）。
    private static var programmaticScrollWindow: TimeInterval { 0.2 }
    /// 「もう端に居る」と見なす許容（秒）。**px ではなく秒で持つこと**:
    /// ずれの正体は実フレーム時刻への丸め（1〜3 コマ）なのでフレーム間隔＝時間で決まり、
    /// ズームには依存しない。px 換算にするとズームを上げた瞬間に許容が足りなくなる。
    /// 30fps の 4 コマぶんを見込む（`isRestingBeyondTimeline` の doc 参照）。
    private static var edgeRestToleranceSeconds: Double { 0.15 }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                scrollView(visibleWidth: Double(outer.size.width))
                    .coordinateSpace(name: Self.scrollSpace)
                    // **`.gesture` ではなく `.simultaneousGesture`**。`.gesture` だと
                    // UIScrollView の pan と排他になり得て横スクロールが死ぬ。
                    .simultaneousGesture(pinchGesture)
                    .simultaneousGesture(touchTracker)
                    .onPreferenceChange(TimelineScrollOffsetKey.self) { offset in
                        guard let offset else { return }
                        update(scrollOffset: Double(offset), visibleWidth: Double(outer.size.width),
                               proxy: proxy)
                    }
                    .onChange(of: geometry) { applyZoom($0, proxy: proxy) }
                    .onChange(of: playheadTime) { recenter(on: $0, proxy: proxy) }
                    // 指が離れた時点で中央を再点検する。触っている間は引き戻しを止めて
                    // いるので、その最中に起きた再生位置・全幅の変化はここで回収する。
                    .onChange(of: isTouchDragging) { if !$0 { recenter(on: playheadTime, proxy: proxy) } }
                    // 慣性が止まった時点でも同じ再点検を入れる（外部シークで線と絵が
                    // ずれたまま残るのを自己修復する）。`markUserScrolling` の Task から
                    // 直接呼べない理由はそちらの doc 参照。
                    .onChange(of: isUserScrolling) { if !$0 { recenter(on: playheadTime, proxy: proxy) } }
                    // クリップ編集で全幅が変わると時刻→x が変わる。線は中央に固定なので
                    // ここで寄せ直さないと「線の位置と再生位置」がずれたままになる。
                    .onChange(of: contentWidth) { _ in recenter(on: playheadTime, proxy: proxy) }
                    .onChange(of: pinch) { if $0 == 1 { pinchBase = nil } }
                    .onChange(of: autoScroll.isDragging) { setAutoScroll(active: $0, proxy: proxy) }
                    .onDisappear {
                        autoScrollTask?.cancel()
                        scrollSettleTask?.cancel()
                        // 落ち着き待ちを打ち切るので、**下ろす通知は自分で出す**。
                        // 出さないと呼び出し側の「スクラブ中」が立ったまま残り、
                        // サムネイル生成と再生位置の書き戻しが復帰しない
                        // （= 再生しても時刻表示が止まったままになる）。
                        if isUserScrolling {
                            isUserScrolling = false
                            onScrubbingChanged(false)
                        }
                    }
            }
        }
        .frame(height: stackHeight)
    }

    private func scrollView(visibleWidth: Double) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) { content() }
                .frame(width: contentWidth, height: stackHeight, alignment: .topLeading)
                // 計測は余白の**内側**に付ける（トラック内 x = 合成時刻 0 が原点。
                // `TimelineViewport` の座標系契約）。`.background` はレイアウトを変えない。
                .background(offsetProbe)
                .padding(.horizontal, CGFloat(Self.leadingInset(visibleWidth: visibleWidth)))
                // **`.id` は余白の外側**。`anchorUnitPointX(leadingInset:)` は
                // 「余白を含む全幅」を分母に分数を出すので、内側に付けると分母が食い違って
                // 着地点が余白ぶんずれる（= プレイヘッドが中央から外れる）。
                .id(Self.contentID)
        }
        // 横スクロールを止める 2 つの条件。
        // 1. 並べ替え中（`autoScroll.isDragging`）: 止めないと指の移動が pan にも吸われ、
        //    座標補正がそれを打ち消してクリップが動かない。画面端の自動スクロールは
        //    `stepAutoScroll` がプログラムから動かす。
        // 2. シークさせない段を押している（`isBlockedRowTouch`）: 押下の時点で立てるので
        //    pan がそもそも始まらない（`TimelinePanBlocker`）。
        .scrollDisabled(autoScroll.isDragging || autoScroll.isBlockedRowTouch)
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

    /// 指の接触を知るだけのドラッグ（値は使わない）。
    ///
    /// **8pt 動いてから成立させる**ことで、タップ（クリップ選択・選択解除）や
    /// 長押し（並べ替え）と競合しない。`.simultaneousGesture` で付けるので
    /// 横スクロール自体を奪うこともない。
    private var touchTracker: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isTouchDragging) { _, state, _ in state = true }
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
        seekIfCenterMoved(scrollOffset: scrollOffset, visibleWidth: visibleWidth)
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
    /// 並べ替え中の自動スクロールは中央の時刻を意図的に動かすため、ここでは除外する。
    /// プログラム由来のスクロール（追従・ズーム保持）の着地も除外する: 値の一致だけで
    /// 判定すると着地誤差がシークに化けて往復が止まらない（型の doc 参照）。
    private func seekIfCenterMoved(scrollOffset: Double, visibleWidth: Double) {
        guard totalDuration > 0, visibleWidth > 0, !autoScroll.isDragging else { return }
        guard !consumeProgrammaticScrollMark() else { return }
        let center = TimelineScrollMath.centeredTime(scrollOffset: scrollOffset, geometry: geometry,
                                                     visibleWidth: visibleWidth,
                                                     totalDuration: totalDuration)
        let deviation = abs(center - playheadTime)
        if isPlaying, !isTouchDragging {
            // 指が触れていない再生中は、追従アニメーションのぶん常に少し遅れている。
            // 指の操作と区別できる大きさを超えたときだけシークする（保険。
            // 通常は下の `isTouchDragging` 側で拾う）。
            guard deviation > Self.playingSeekThresholdSeconds else { return }
        } else {
            // 指が触れているなら、ずれはすべて指が作ったもの。再生中でも即座に
            // シークへ倒す（呼び出し側が再生を止める）。
            guard deviation > geometry.duration(forWidth: Self.seekDeadZonePixels) else { return }
        }
        markUserScrolling()
        onSeek(center)
    }

    /// このスクロール更新がプログラム由来の着地かを判定し、印を消費する。
    ///
    /// 指が触れている間は印を無視する（`recenter` は指と慣性の間は撃たないので、
    /// 操作中に印が立つことはない = ユーザーの払いを取りこぼさない）。
    private func consumeProgrammaticScrollMark() -> Bool {
        guard let deadline = programmaticScrollDeadline else { return false }
        guard !isTouchDragging, Date() < deadline else {
            programmaticScrollDeadline = nil
            return false
        }
        return true
    }

    /// スクロール中フラグを立て、止まったら下ろす（デバウンス）。
    ///
    /// 下ろすのは**フラグだけ**にして、中央の再点検は
    /// `.onChange(of: isUserScrolling)` に任せる。この `Task` が捕まえている
    /// `playheadTime` は struct の `let`（値コピー）なので、ここで `recenter` を呼ぶと
    /// **160ms 前の再生位置**へ寄せてしまい、直後にその古い時刻へシークが撃たれて
    /// 位置が巻き戻る（`@State` / `@Binding` は参照なので生きているが、
    /// 素の `let` は生きていない）。`onChange` のクロージャは最新の body 評価のものなので
    /// 現在値が読める。
    private func markUserScrolling() {
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
        }
    }

    /// 余白（先頭より前・終端より後）まで払って止まっている状態か。
    ///
    /// **この状態では中央へ引き戻さない。** 余白は「先頭・終端のクリップを画面中央まで
    /// 運ぶ」ために必要な可動域だが、そこまで払うと中央の時刻は 0／尺へ丸められるので、
    /// 引き戻すと画面が再生位置へ弾かれて戻る（ユーザー報告の「動かしても再生位置に
    /// 戻される」）。丸めた先に再生位置が既に居るなら、線が空白の上に載るだけで
    /// 矛盾は無いのでその場に留める（一般的な動画編集アプリも終端より後ろへ送れる）。
    ///
    /// **端の判定には許容を持たせること。** 再生位置は「シークで要求した時刻」ではなく
    /// `MosaicPreviewController` が**実際に描けたフレームの時刻**で上書きされ
    /// （フレーム格子へ量子化され 1〜3 コマ遅延しうる）、さらに呼び出し側の `scrub` が
    /// `totalDuration.nextDown` へ丸める。そのため終端まで払っても
    /// `playhead == totalDuration` には決してならない。厳密比較にすると**終端側だけ
    /// 引き戻しが止まらなくなり**、慣性が残っているあいだ指と押し合う
    /// （実測: 終端を越えて払っても帯の末尾が画面中央へ吸い付いて離れない。
    /// UI テスト `test_swipeLeftBeyondEnd_staysPastEnd`）。
    private func isRestingBeyondTimeline(currentOffset: Double, visibleWidth: Double,
                                         playhead: Double) -> Bool {
        guard totalDuration > 0 else { return false }
        let raw = TimelineScrollMath.rawCenteredTime(scrollOffset: currentOffset, geometry: geometry,
                                                     visibleWidth: visibleWidth)
        if raw < 0 { return playhead <= Self.edgeRestToleranceSeconds }
        if raw > totalDuration { return playhead >= totalDuration - Self.edgeRestToleranceSeconds }
        return false
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
        // ドラッグ中の UIScrollView と押し合って引っかかる。**再生中のスワイプが
        // 効かなかった原因はこれ**）。落ち着いた時点で `markUserScrolling` の再点検、
        // 指が離れた時点で `onChange(of: isTouchDragging)` が最終状態を保証する。
        guard visibleWidth > 0, !isUserScrolling, !isTouchDragging else { return }
        guard !isRestingBeyondTimeline(currentOffset: currentOffset, visibleWidth: visibleWidth,
                                       playhead: time) else { return }
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

    /// **プログラム由来スクロールの唯一の出口**（追従・ズーム保持・並べ替えの自動送り）。
    /// ここを通る移動は着地誤差ぶんの差が残るので、印を立ててシーク判定から外す
    /// （型の doc「押し合いを起こさない理由」）。
    private func scroll(proxy: ScrollViewProxy, to offset: Double,
                        contentWidth width: Double, visibleWidth: Double) {
        programmaticScrollDeadline = Date().addingTimeInterval(Self.programmaticScrollWindow)
        let unit = TimelineScrollMath.anchorUnitPointX(
            scrollOffset: offset, contentWidth: width, visibleWidth: visibleWidth,
            leadingInset: Self.leadingInset(visibleWidth: visibleWidth))
        proxy.scrollTo(Self.contentID, anchor: UnitPoint(x: unit, y: 0))
    }
}
