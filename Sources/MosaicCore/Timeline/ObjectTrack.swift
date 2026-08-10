import CoreGraphics
import Foundation

/// `ObjectMask` を自動追跡した結果の軌跡。**素材時刻アンカーの値型**で、
/// マスク本体（ユーザーのキーフレーム）とは別レイヤに置く。
///
/// ## なぜキーフレームとして書き戻さないのか
///
/// 追跡は毎フレームぶんの位置を出す。これをキーフレームにすると、
///
/// - ユーザーが手で置いた 3 個のキーフレームが、数百個の自動キーフレームに埋もれる
/// - 手直ししたキーフレームが、次の追跡実行で上書きされる
/// - 下書き JSON が数百 KB 単位で膨らむ
///
/// の 3 つが同時に起きる。別レイヤにして「**ユーザーのキーフレームが常に勝つ**」を
/// 型で保証する（`corrected` のドリフト補正が、追跡結果を必ずキーフレームへ着地させる）。
///
/// ## なぜ「描画時に追跡する」ではないのか
///
/// このコードベースは全経路で「プレビューとエクスポートは同じ純関数を通す」を強制している
/// （`ObjectMaskResolver` / `TransitionKind.visibleRect` の doc）。オプティカルフローは
/// **直前のフレームに依存する逐次処理**なので、ランダムシークするプレビューと
/// 先頭から舐めるエクスポートでは同じ時刻でも別の結果になる。
/// 事前に計算した軌跡を両者が**読むだけ**にすれば、この食い違いが原理的に起きない。
///
/// ## 保存しない
///
/// 下書きには入れない（`EditingDraft` に無い）。素材から再計算できる派生データであり、
/// キーフレームさえ残っていれば復元後に同じ軌跡が出る。
public struct ObjectTrack: Equatable, Sendable {
    /// ある素材時刻での追跡位置（**素材フレーム基準**の正規化矩形）。
    public struct Sample: Equatable, Sendable {
        public let sourceTime: Double
        public let rect: CGRect

        public init(sourceTime: Double, rect: CGRect) {
            self.sourceTime = sourceTime
            self.rect = rect
        }
    }

    /// 追跡が連続していた 1 区間。**追跡が切れるとセグメントが分かれる**。
    ///
    /// 穴（セグメントとセグメントの間）では軌跡を返さず、呼び出し側が
    /// マスクのキーフレーム補間へフォールバックする。追跡できなかった区間で
    /// 嘘の位置を出すより、ユーザーが置いたキーフレームの直線補間の方が安全。
    public struct Segment: Equatable, Sendable {
        /// 素材時刻の昇順・**2 個以上**。
        public let samples: [Sample]

        /// サンプルが 2 個未満、または昇順でないときは nil（区間として意味を持たない）。
        public init?(samples: [Sample]) {
            guard samples.count >= 2 else { return nil }
            for index in 1..<samples.count
            where !(samples[index].sourceTime > samples[index - 1].sourceTime) { return nil }
            self.samples = samples
        }

        public var start: Double { samples[0].sourceTime }
        public var end: Double { samples[samples.count - 1].sourceTime }

        func contains(_ time: Double) -> Bool { time >= start && time <= end }

        /// 区間内の線形補間。区間外は nil。
        func rect(at time: Double) -> CGRect? {
            guard contains(time) else { return nil }
            guard let index = samples.firstIndex(where: { $0.sourceTime >= time }) else { return nil }
            guard index > 0 else { return samples[0].rect }
            let before = samples[index - 1], after = samples[index]
            let span = after.sourceTime - before.sourceTime
            guard span > 0 else { return before.rect }
            let t = CGFloat((time - before.sourceTime) / span)
            let interpolated = CGRect(x: lerp(before.rect.origin.x, after.rect.origin.x, t),
                                      y: lerp(before.rect.origin.y, after.rect.origin.y, t),
                                      width: lerp(before.rect.size.width, after.rect.size.width, t),
                                      height: lerp(before.rect.size.height, after.rect.size.height, t))
            // `ObjectMask.rect(atSourceTime:)` と同じ理由で、補間結果の非有限を通さない
            // （成分ごとに有限でも差分計算で overflow しうる）。
            return ObjectMask.isFinite(interpolated) ? interpolated : before.rect
        }

        private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    }

    public let maskID: UUID
    public let clipID: UUID
    public let sourceID: UUID

    /// 追跡の元になったキーフレーム列の**そのままの写し**。
    ///
    /// ハッシュではなく実体を持つのは、衝突で「古い軌跡を新しいマスクに使ってしまう」
    /// 事故を起こさないため。キーフレームは通常数個なのでコストは無視できる。
    /// ユーザーが 1 個でもキーフレームを動かせば `matches(_:)` が false になり、
    /// 軌跡は自動的に使われなくなる（＝再計算が要る、という合図でもある）。
    public let keyframes: [ObjectMask.Keyframe]

    public let segments: [Segment]

    public init(maskID: UUID, clipID: UUID, sourceID: UUID,
                keyframes: [ObjectMask.Keyframe], segments: [Segment]) {
        self.maskID = maskID
        self.clipID = clipID
        self.sourceID = sourceID
        self.keyframes = keyframes
        self.segments = segments
    }

    /// この軌跡が `mask` のものとして**今も有効**か。
    ///
    /// id・アンカー・キーフレーム列が全て一致して初めて true。1 つでも違えば
    /// 軌跡は捨てられ、描画はキーフレーム補間へ戻る（＝安全側）。
    public func matches(_ mask: ObjectMask) -> Bool {
        mask.id == maskID
            && mask.anchor.clipID == clipID
            && mask.anchor.sourceID == sourceID
            && mask.keyframes == keyframes
    }

    /// 指定した**素材時刻**での追跡位置。軌跡が無い時刻は nil
    /// （呼び出し側がマスクのキーフレーム補間へフォールバックする）。
    ///
    /// 端の扱いは「見失ったら最後の位置に残す」というユーザー決定に従う:
    ///
    /// - **最後のキーフレームより後**に伸びたセグメントの終端を過ぎたら、その終端位置で止める。
    ///   キーフレーム補間へ落とすと最後のキーフレームの位置へ**逆戻り**してしまい、
    ///   「追跡していたのに急に元の場所へ飛ぶ」という最悪の見え方になる。
    /// - **最初のキーフレームより前**に伸びたセグメントも同様に先端で止める。
    /// - 中間の穴（追跡が切れた区間）は nil。次のキーフレームで必ず正しい位置へ戻るので、
    ///   直線補間の方が「途中で消えた追跡位置を引きずる」より正確。
    public func rect(atSourceTime time: Double) -> CGRect? {
        guard time.isFinite, let first = keyframes.first, let last = keyframes.last else { return nil }
        if let segment = segments.first(where: { $0.contains(time) }) {
            return segment.rect(at: time)
        }
        if time > last.sourceTime,
           let tail = segments.last, tail.end > last.sourceTime, time > tail.end {
            return tail.samples[tail.samples.count - 1].rect
        }
        if time < first.sourceTime,
           let head = segments.first, head.start < first.sourceTime, time < head.start {
            return head.samples[0].rect
        }
        return nil
    }

    /// 追跡が埋めた素材時間の合計（秒）。UI の「追跡できた割合」表示に使う。
    public var coveredDuration: Double {
        segments.reduce(0) { $0 + ($1.end - $1.start) }
    }
}
