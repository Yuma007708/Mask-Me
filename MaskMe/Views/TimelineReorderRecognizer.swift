import SwiftUI
import UIKit

// タイムラインの**ジェスチャとスクロールの受け渡し**（UIKit の recognizer 2 種）と、
// 容器・段・ジェスチャで共有する語彙（座標空間名・`TimelineAutoScrollState`・
// 自動スクロールの調整値・スクロール量の PreferenceKey・`blocksTimelinePan`）。
// 語彙をここに置いているのは `TimelineScrollContainer.swift` が file_length に
// 張り付いたため（新規ファイルの追加には `xcodegen generate` = CocoaPods 統合の
// 再構築が要る）。受け渡す相手がこのファイルの recognizer なので同居の筋は通る。

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
    /// シークさせない段（継ぎ目レーン・適用区間トラック）を指が押さえているか。
    ///
    /// 段は同時に複数触られ得るので**数える**（片方の指が離れた瞬間に
    /// もう片方ぶんまで下ろさないため）。
    @Published private(set) var isBlockedRowTouch = false
    private var blockedRowTouches = 0
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

    func beginBlockedRowTouch() {
        blockedRowTouches += 1
        if !isBlockedRowTouch { isBlockedRowTouch = true }
    }

    func endBlockedRowTouch() {
        blockedRowTouches = max(0, blockedRowTouches - 1)
        if blockedRowTouches == 0, isBlockedRowTouch { isBlockedRowTouch = false }
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
/// 計測子はコンテンツの左右余白の**内側**に置くこと
/// （`TimelineViewport` の座標系契約。外側に置くと余白ぶん恒常的にずれる）。
///
/// **値は `Optional` でなければならない。** 非 Optional（既定値 0・`value = nextValue()`）
/// にすると、計測子を持たない兄弟サブツリー（トラックの中身）が流す**既定値 0 で
/// 上書きされ、スクロール量が常に 0 になる**。実測ではこの状態で
/// 「払っても再生位置が動かない・サムネイルが横スクロールで積み直されない」が起きていた
/// （UI テスト `TimelineGestureUITests` で検出。中身を無地に差し替えると再現しなくなる
/// ことから、上書き元が中身であると特定した）。
/// nil を無視して非 nil だけ採れば、計測子 1 個の値がそのまま上がる。
struct TimelineScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// シークの操作面を**目盛り帯とクリップ帯だけ**に絞るための当て板
/// （継ぎ目レーンと適用区間トラックの上を払っても再生位置は動かない）。
///
/// 判定は UIKit 側（`TimelinePanBlocker`）。SwiftUI の `.gesture` で pan を止める方式は
/// 段の中身がヒットテストを取らないと届かず、コンテンツ全面に敷くと今度は目盛り帯まで
/// 塞ぐ（どちらも実測。`TimelinePanBlocker` の doc 参照）。
extension View {
    /// この段の上で始まったドラッグではタイムラインをスクロール（= シーク）させない。
    func blocksTimelinePan(_ autoScroll: TimelineAutoScrollState) -> some View {
        background(TimelinePanBlocker(autoScroll: autoScroll))
    }
}

/// 長押し → そのままドラッグ（クリップの並べ替え）を **UIKit の recognizer** で受ける当て板。
///
/// ## なぜ SwiftUI のジェスチャではないのか
///
/// `LongPressGesture().sequenced(before: DragGesture())` は、`.gesture` でも
/// `.simultaneousGesture` でも**囲みの `ScrollView` の pan を起こさなくする**。
/// 実測（`MaskMeUITests/TimelineGestureUITests`）では、クリップ帯の上を払っても
/// スクロールが 1px も動かず、中央固定タイムラインのシークが丸ごと効かなかった。
/// クリップ帯を無地の `Color` に差し替えると同じ払いでスクロールしたことから、
/// 原因がこのジェスチャだと特定した。`.simultaneousGesture` は
/// **SwiftUI のジェスチャ同士の関係**を宣言するだけで、`UIScrollView` の pan
/// （UIKit の recognizer）との関係には効かない。
///
/// ## 仕組み
///
/// recognizer は**自分の View ではなく、囲みの `UIScrollView` に付ける**。
/// 祖先に付いた recognizer はヒットテストの結果に関わらずタッチを見られるので、
///
/// - この View 自身は `hitTest` を素通し（`nil`）にできる
///   → 下のクリップのタップ（選択）も pan もこの View に吸われない
/// - `cancelsTouchesInView = false` で、成立後も下の View のタッチを打ち消さない
/// - `shouldRecognizeSimultaneouslyWith` で pan との同時認識を明示する
///
/// が同時に成り立つ。UIKit 自身のドラッグ並べ替え（ホーム画面・テーブル）と同じ形である。
/// 並べ替えが始まったらスクロール側は `scrollDisabled` で止める
/// （`TimelineScrollContainer.scrollView`。止めないと指の移動が pan にも吸われ、
/// 並べ替えの座標補正がそれを打ち消してクリップが動かない）。
///
/// ## 後始末
///
/// `@GestureState` の自動リセットは使えないので、終端の 3 状態
/// （`.ended` / `.cancelled` / `.failed`）を**すべて** `onFinish` へ流す。
/// スクロールに主導権を奪われたときは `.cancelled` が来るため、
/// 「取り残された下書きで自動スクロールが走り続ける」事故は起きない。
struct TimelineReorderRecognizer: UIViewRepresentable {
    /// 長押しの成立時間（秒）。
    let minimumPressDuration: TimeInterval
    /// 成立と判定する指のブレ幅（px）。これを超えて先に動くと長押しは失敗し、
    /// 横スクロール（= シーク）に主導権が渡る。
    let allowableMovement: CGFloat
    /// 長押し成立。引数は**この View 内**の座標。
    let onBegin: (CGPoint) -> Void
    /// 成立後の移動。`translation` は成立位置からの差分、`location` は View 内座標。
    let onChange: (CGSize, CGPoint) -> Void
    /// 終了・中断（どちらの経路でも必ず呼ばれる）。`committed` は正常終了かどうか。
    let onFinish: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TimelineRecognizerHostView()
        let coordinator = context.coordinator
        coordinator.anchor = view
        view.onMoveToWindow = { [weak coordinator] in coordinator?.attachIfNeeded() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.attachIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: TimelineReorderRecognizer
        /// 座標変換の基準（この representable の View）。
        weak var anchor: TimelineRecognizerHostView?
        private var recognizer: UILongPressGestureRecognizer?
        /// 長押しが成立した位置（`anchor` 内座標）。差分の基準。
        private var origin: CGPoint?

        init(owner: TimelineReorderRecognizer) {
            self.owner = owner
        }

        func attachIfNeeded() {
            guard recognizer == nil, let anchor, let scrollView = anchor.enclosingScrollView else {
                return
            }
            let created = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            created.minimumPressDuration = owner.minimumPressDuration
            created.allowableMovement = owner.allowableMovement
            created.cancelsTouchesInView = false
            created.delegate = self
            scrollView.addGestureRecognizer(created)
            recognizer = created
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let anchor else { return }
            let location = recognizer.location(in: anchor)
            switch recognizer.state {
            case .began:
                // 自分の担当範囲（クリップ帯）の外で成立した長押しは無視する
                // （recognizer はスクロールビュー全体のタッチを見ているため）。
                guard anchor.bounds.contains(location) else { return }
                origin = location
                owner.onBegin(location)
            case .changed:
                guard let origin else { return }
                owner.onChange(translation(from: origin, to: location), location)
            case .ended, .cancelled, .failed:
                guard let origin else { return }
                self.origin = nil
                owner.onFinish(translation(from: origin, to: location),
                               recognizer.state == .ended)
            default:
                break
            }
        }

        private func translation(from origin: CGPoint, to location: CGPoint) -> CGSize {
            CGSize(width: location.x - origin.x, height: location.y - origin.y)
        }

        /// **pan との同時認識を許す。** false だと長押し成立後に指を動かした瞬間
        /// どちらか一方しか生き残らず、並べ替えとスクロールのどちらかが死ぬ。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

}

/// 「この段の上で始まったドラッグではタイムラインをスクロールさせない」を
/// **UIKit 側で**判定する当て板。
///
/// SwiftUI の `.gesture` で pan を止める方式は、そのジェスチャが**ヒットテストを
/// 取った View に付いている**ときしか効かない。タイムラインの段は中身の大半が
/// `Color.clear`（継ぎ目レーン・適用区間トラック）や地色（目盛り帯）で、そこは
/// ヒットテストを取らないため、段に付けた `.gesture` には届かない。
/// コンテンツ全体の背面に 1 枚敷く方式も試したが、今度は**目盛り帯の払いまで
/// 飲み込んでシークできなくなった**（いずれも `MaskMeUITests` で実測）。
///
/// そこで判定を座標に寄せる: 囲みの `UIScrollView` に**押下即成立**の recognizer を
/// 付け、押した点が自分の段の矩形に入っていれば `isBlockedRowTouch` を立てる。
/// 容器はそれを `scrollDisabled` に繋ぐので、**pan がそもそも始まらない**。
/// ヒットテストには一切関与しないので、段の中のタップ（継ぎ目ボタン・区間選択）と
/// 端ハンドルのドラッグはそのまま効く。
struct TimelinePanBlocker: UIViewRepresentable {
    /// 押下の通知先（`TimelineScrollContainer` が `scrollDisabled` に使う）。
    let autoScroll: TimelineAutoScrollState

    func makeUIView(context: Context) -> UIView {
        let view = TimelineRecognizerHostView()
        let coordinator = context.coordinator
        coordinator.anchor = view
        view.onMoveToWindow = { [weak coordinator] in coordinator?.attachIfNeeded() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.autoScroll = autoScroll
        context.coordinator.attachIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(autoScroll: autoScroll) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var autoScroll: TimelineAutoScrollState
        weak var anchor: TimelineRecognizerHostView?
        private var recognizer: UILongPressGestureRecognizer?
        /// 自分が押下を立てたか（他の段が立てた分を下ろさないための自己申告）。
        private var isHolding = false

        init(autoScroll: TimelineAutoScrollState) {
            self.autoScroll = autoScroll
        }

        func attachIfNeeded() {
            guard recognizer == nil, let anchor, let scrollView = anchor.enclosingScrollView else {
                return
            }
            // 押下と同時に成立させる（指が動き出す前に `scrollDisabled` を立てないと
            // pan が先に始まってしまう）。
            let created = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            created.minimumPressDuration = 0
            created.cancelsTouchesInView = false
            created.delegate = self
            scrollView.addGestureRecognizer(created)
            recognizer = created
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let anchor else { return }
            switch recognizer.state {
            case .began:
                guard anchor.bounds.contains(recognizer.location(in: anchor)) else { return }
                isHolding = true
                autoScroll.beginBlockedRowTouch()
            case .ended, .cancelled, .failed:
                guard isHolding else { return }
                isHolding = false
                autoScroll.endBlockedRowTouch()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

}

/// 祖先の `UIScrollView` に recognizer を付けるための当て板 View。
///
/// **ヒットテストには関与しない**（`hitTest` が nil）。recognizer は祖先に付くので、
/// この View がタッチを受け取らなくても成立する。下のクリップのタップも pan も吸わない。
///
/// `updateUIView` の中で付けようとすると**取り付けに失敗し得る**。SwiftUI は
/// `makeUIView` → `updateUIView` の時点でまだ View を階層へ入れておらず、
/// 段が再描画されなければ 2 度目の `updateUIView` も来ないためである
/// （実測: 当て板を足したのに 4 段すべて素通しでスクロールした）。
/// ウィンドウに入った時点（`didMoveToWindow`）で必ず 1 回試すのが確実。
final class TimelineRecognizerHostView: UIView {
    /// 階層に入った（または外れた）ときの通知。
    var onMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    /// 祖先の `UIScrollView`。
    var enclosingScrollView: UIScrollView? {
        var parent = superview
        while let current = parent {
            if let scrollView = current as? UIScrollView { return scrollView }
            parent = current.superview
        }
        return nil
    }
}
