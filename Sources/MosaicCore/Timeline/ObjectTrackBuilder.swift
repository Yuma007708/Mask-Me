import CoreGraphics
import Foundation

/// 物体マスクの自動追跡ロジック本体。**フレームの読み方も OpenCV も知らない**純 Swift。
///
/// 呼び出し側（アプリ層の `ObjectMaskTracker`）は素材を先頭から舐めて、
/// 1 フレームごとに「直前フレーム → このフレーム」の相似変換を渡すだけでよい。
/// 品質ゲート・キーフレームでの再アンカー・見失いの扱い・ドリフト補正という
/// **判断は全てここ**にあるので、`swift test` だけで検証できる。
///
/// ## 追跡率を上げるためにしていること
///
/// 1. **毎フレーム再 seed**（呼び出し側の責務。`currentRect` を返すのはそのため）。
///    Lucas-Kanade は追跡のたびに特徴点が脱落していき、点が尽きた時点で追跡が死ぬ。
///    毎フレーム現在位置で特徴点を取り直せば脱落が累積せず、これが実測で最も効く。
/// 2. **キーフレームで必ず再アンカー**。ユーザーが「ここに居る」と言った位置へ強制的に戻す。
///    ドリフトが次の区間へ持ち越されない。
/// 3. **ドリフト補正**（`finish()`）。区間の終端で溜まった誤差を、区間全体へ
///    時間比例で配り戻す。結果として軌跡は**必ずキーフレームを通る**。
/// 4. **短い見失いは等速外挿で埋める**。1〜2 フレームのブレやブラーで軌跡が切れない。
///
/// ## 見失いが続いたら「凍結」する（再取得しない）
///
/// 外挿の上限を超えたら、その区間を閉じて位置を凍結し、**次のキーフレームまで追跡を再開しない**。
/// 一度ロックを失った位置で特徴点を取り直すと、そこに映っているのは背景なので、
/// マスクが背景に貼り付いてカメラのパンと一緒に流れていく（見た目は「追跡できている」のに
/// 対象からは完全に外れている、という最も質の悪い失敗）。
/// 隠れて出てくる対象はキーフレームを 1 個足して貰う——これは
/// 「手直しはキーフレームで」というユーザー決定そのものである。
public final class ObjectTrackBuilder {
    public struct Options: Sendable {
        /// 1 フレームあたりの許容スケール変化。逸脱＝誤追跡としてフロー失敗扱い。
        /// 30fps で 1 フレーム 12% の拡大は現実の被写体では起きない。
        public var perFrameScale: ClosedRange<CGFloat>
        /// 区間の開始位置に対する累積スケールの許容範囲。
        /// じわじわ縮んで点になる／膨らんで画面を覆う暴走を止める。
        public var cumulativeScale: ClosedRange<CGFloat>
        /// フロー失敗を等速外挿で埋める最大フレーム数。超えたら区間を閉じて凍結する。
        public var maxExtrapolationFrames: Int

        public init(perFrameScale: ClosedRange<CGFloat> = 0.88...1.12,
                    cumulativeScale: ClosedRange<CGFloat> = 0.3...3.0,
                    maxExtrapolationFrames: Int = 6) {
            self.perFrameScale = perFrameScale
            self.cumulativeScale = cumulativeScale
            self.maxExtrapolationFrames = maxExtrapolationFrames
        }
    }

    private let maskID: UUID
    private let clipID: UUID
    private let sourceID: UUID
    private let keyframes: [ObjectMask.Keyframe]
    private let options: Options

    /// 現在の追跡位置（素材フレーム基準の正規化矩形）。呼び出し側の再 seed 先。
    private var currentRect: CGRect
    /// 現在の区間の開始矩形（累積スケールゲートの基準）。
    private var runAnchorRect: CGRect
    private var currentRun: [ObjectTrack.Sample] = []
    private var runs: [[ObjectTrack.Sample]] = []
    private var lastTime: Double
    /// 正規化座標 / 秒。短い見失いを埋める等速外挿に使う。
    private var velocity: CGPoint = .zero
    private var failureFrames = 0
    /// 外挿の上限を超えて凍結中か。次のキーフレームまで追跡を再開しない。
    private var isFrozen = false

    /// - Parameters:
    ///   - mask: 追跡対象。**キーフレームが 1 個以上**であることは `ObjectMask` の不変条件。
    ///   - clipID / sourceID: マスクのアンカー。軌跡の同一性検査に使う。
    ///   - startTime: 追跡を始める素材時刻。通常は最初のキーフレームの時刻。
    public init?(mask: ObjectMask, clipID: UUID, sourceID: UUID, options: Options = Options()) {
        guard let first = mask.keyframes.first else { return nil }
        self.maskID = mask.id
        self.clipID = clipID
        self.sourceID = sourceID
        self.keyframes = mask.keyframes
        self.options = options
        self.currentRect = first.rect
        self.runAnchorRect = first.rect
        self.lastTime = first.sourceTime
        self.currentRun = [ObjectTrack.Sample(sourceTime: first.sourceTime, rect: first.rect)]
    }

    /// 追跡を始めるべき素材時刻（最初のキーフレーム）。呼び出し側のシーク先。
    public var startTime: Double { keyframes[0].sourceTime }

    /// 呼び出し側が次フレームで特徴点を取り直す位置。
    public var reseedRect: CGRect? { isFrozen ? nil : currentRect }

    /// 1 フレーム進める。**`sourceTime` は厳密に増加する順**で渡すこと。
    ///
    /// - Parameters:
    ///   - sourceTime: このフレームの素材時刻。
    ///   - transform: 直前フレーム → このフレームの相似変換。`nil` はフロー失敗。
    ///   - imageSize: 変換が定義されているピクセル空間の寸法（デコードしたフレームの実寸）。
    /// - Returns: 次フレームの再 seed に使う矩形。`nil` は凍結中（seed しなくてよい）。
    @discardableResult
    public func advance(toSourceTime sourceTime: Double,
                        transform: SimilarityTransform?,
                        imageSize: CGSize) -> CGRect? {
        guard sourceTime.isFinite, sourceTime > lastTime else { return reseedRect }
        let dt = sourceTime - lastTime
        defer { lastTime = sourceTime }

        if !isFrozen {
            step(to: sourceTime, transform: transform, imageSize: imageSize, dt: dt)
        }
        // **キーフレームの通過判定は step の後**。通過フレームの追跡サンプルまでを
        // 前の区間に含めてから閉じることで、キーフレーム時刻ちょうどの生位置を
        // 補間で取り出せる（ドリフト補正の誤差計算に要る）。
        reanchorIfCrossedKeyframe(previousTime: lastTime, currentTime: sourceTime)
        return reseedRect
    }

    private func step(to sourceTime: Double, transform: SimilarityTransform?,
                      imageSize: CGSize, dt: Double) {
        if let transform, accepts(transform, imageSize: imageSize) {
            let moved = transform.apply(toNormalizedRect: currentRect, imageSize: imageSize)
            guard ObjectMask.isFinite(moved), withinCumulativeScale(moved) else {
                extrapolate(dt: dt)
                return
            }
            if dt > 0 {
                velocity = CGPoint(x: (moved.midX - currentRect.midX) / CGFloat(dt),
                                   y: (moved.midY - currentRect.midY) / CGFloat(dt))
            }
            currentRect = moved
            failureFrames = 0
            currentRun.append(ObjectTrack.Sample(sourceTime: sourceTime, rect: moved))
        } else {
            extrapolate(dt: dt)
            if !isFrozen {
                currentRun.append(ObjectTrack.Sample(sourceTime: sourceTime, rect: currentRect))
            }
        }
    }

    private func accepts(_ transform: SimilarityTransform, imageSize: CGSize) -> Bool {
        transform.scale.isFinite && transform.tx.isFinite && transform.ty.isFinite
            && options.perFrameScale.contains(transform.scale)
            && imageSize.width > 0 && imageSize.height > 0
    }

    private func withinCumulativeScale(_ rect: CGRect) -> Bool {
        guard runAnchorRect.width > 0, runAnchorRect.height > 0 else { return false }
        let ratio = rect.width / runAnchorRect.width
        return ratio.isFinite && options.cumulativeScale.contains(ratio)
    }

    /// 短い見失いを等速で埋める。上限を超えたら区間を閉じて凍結する。
    private func extrapolate(dt: Double) {
        failureFrames += 1
        guard failureFrames <= options.maxExtrapolationFrames else {
            closeRun()
            isFrozen = true
            return
        }
        let moved = currentRect.offsetBy(dx: velocity.x * CGFloat(dt), dy: velocity.y * CGFloat(dt))
        if ObjectMask.isFinite(moved) { currentRect = moved }
    }

    /// キーフレームを跨いだら、そこで区間を閉じてユーザーの位置へ再アンカーする。
    ///
    /// 凍結中でも再アンカーは行う（＝キーフレームは追跡の再開点でもある）。
    private func reanchorIfCrossedKeyframe(previousTime: Double, currentTime: Double) {
        guard let crossed = keyframes.last(where: {
            $0.sourceTime > previousTime && $0.sourceTime <= currentTime
        }) else { return }
        closeRun()
        currentRect = crossed.rect
        runAnchorRect = crossed.rect
        velocity = .zero
        failureFrames = 0
        isFrozen = false
        currentRun = [ObjectTrack.Sample(sourceTime: crossed.sourceTime, rect: crossed.rect)]
    }

    private func closeRun() {
        if currentRun.count >= 2 { runs.append(currentRun) }
        currentRun = []
    }

    /// 収集した生の軌跡をドリフト補正して `ObjectTrack` に組み上げる。
    /// 有効な区間が 1 つも無ければ nil（＝軌跡なし。描画はキーフレーム補間のまま）。
    public func finish() -> ObjectTrack? {
        closeRun()
        let segments = ObjectTrackAssembler.segments(runs: runs, keyframes: keyframes)
        guard !segments.isEmpty else { return nil }
        return ObjectTrack(maskID: maskID, clipID: clipID, sourceID: sourceID,
                           keyframes: keyframes, segments: segments)
    }
}
