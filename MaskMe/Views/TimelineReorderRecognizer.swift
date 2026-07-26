import SwiftUI
import UIKit

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
