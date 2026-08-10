import CoreGraphics
import Foundation

/// ユーザーが矩形で指定した顔（シード）を、動画全体へ**前後どちらか一方向**に
/// 追い続けるための歩幅・ROI（関心領域）決定ロジック。**フレームの読み方も
/// 顔検出器も知らない**純 Swift（`ObjectTrackBuilder` と同じ切り方 — こちらは
/// `SimilarityTransform` を、あちらは検出候補と類似度を受け取るだけで、
/// 実際にフレームを取り出して顔を探すのは呼び出し側の責務）。
///
/// 呼び出し側（アプリ層）は `nextStep()` で「次はこの時刻のこの矩形を見て」を受け取り、
/// その ROI 内で顔検出を行った結果（候補と、追っている人物プロファイルとの類似度）を
/// `accept(candidates:similarities:)` に渡す。あとは `isFinished` を見て
/// 追跡を止めるかどうかを判断するだけでよい。
///
/// ## 「迷ったら追跡を止める」
///
/// 候補が同定できない・位置的にも近くない場合は**ミスとして扱い、適当な候補を採らない**。
/// ここで妥協して別人を採ると、追跡が別人へ乗り移り「別人が隠れ、本人が晒される」という
/// 露出方向の事故になる（このアプリの性質上、検出漏れより重い）。
///
/// `class` ではなく `struct` + `mutating` にしてあるのは、`MosaicCore` の型が
/// 値型を基本とする方針だからである（`final class` は detached task から使うときに
/// `Sendable` 準拠の面倒を持ち込む）。
public struct RegionSeedTracker: Sendable {
    public enum Direction: Sendable {
        case forward
        case backward
    }

    public struct Options: Sendable {
        /// 歩幅（秒、素材時刻）。
        public var step: Double
        /// 前回ヒットの bbox を膨らませる倍率（連続ミス 0 のときの ROI 倍率）。
        public var roiScale: Double
        /// ROI 短辺の下限（正規化座標）。これを下回ると縦横比を保ったまま拡大する。
        public var minROISide: Double
        /// この回数だけ連続でミスしたら追跡を終える。
        public var maxConsecutiveMisses: Int
        /// これだけ歩いたら（ヒット・ミスに関わらず）追跡を終える。
        public var maxSteps: Int
        /// 中心の外挿速度のクランプ（正規化 / 秒）。急加速する誤外挿を防ぐ。
        public var maxCenterSpeed: Double

        public init(step: Double = 0.2,
                    roiScale: Double = 2.0,
                    minROISide: Double = 0.15,
                    maxConsecutiveMisses: Int = 4,
                    maxSteps: Int = 750,
                    maxCenterSpeed: Double = 1.0) {
            self.step = step
            self.roiScale = roiScale
            self.minROISide = minROISide
            self.maxConsecutiveMisses = maxConsecutiveMisses
            self.maxSteps = maxSteps
            self.maxCenterSpeed = maxCenterSpeed
        }
    }

    public struct Step: Sendable {
        public let sourceTime: Double
        /// 素材フレーム基準の正規化矩形（`[0, 1]²` へクランプ済み）。
        public let roi: CGRect
        /// 連続ミス 3 回目の全画面フォールバックか。
        public let isFullFrame: Bool
    }

    public struct Outcome: Sendable {
        /// 採用した候補の添字。`nil` はミス。
        public let chosenIndex: Int?
        /// これ以上 `nextStep()` が nil ではない値を返さないか。
        public let isFinished: Bool
    }

    /// ミス連続 1 回・2 回のときの ROI 倍率（絶対値。`roiScale` からの相対倍ではない）。
    /// ミスが続くほど「顔が動いた範囲」の不確実性が広がるため、2.0 → 3.0 → 4.5 と
    /// 段階的に見る範囲を広げ、3 回目で全画面フォールバックに落とす。
    private static let secondMissMultiplier = 3.0
    private static let thirdMissMultiplier = 4.5

    private let seedTime: Double
    private let range: ClosedRange<Double>
    private let direction: Direction
    private let options: Options

    /// 直近ヒットの bbox（素材フレーム基準）。ROI サイズの基準。
    private var lastHitBox: CGRect
    /// 直近 2 ヒットの (時刻, 中心)。等速外挿の速度計算に使う。ヒットが 1 つ
    /// （シードのみ）のときは速度 0 として扱う。
    private var hitHistory: [(time: Double, center: CGPoint)]
    private var consecutiveMisses = 0
    private var stepsTaken = 0
    private var finished = false

    /// 直近の `nextStep()` が返した ROI（`accept` の位置判定の許容量に使う）。
    private var lastROI: CGRect?
    /// 直近に返した `Step.sourceTime`（シードのみのときは `seedTime`）。
    /// 走査が `range` を出た瞬間、この値が境界ちょうどだったか（＝既に端点まで歩き切って
    /// いたか）を見て、端点クランプ用の重複ステップを出さないようにする。
    private var lastEmittedSourceTime: Double
    /// 直近の `nextStep()` が計算した予測中心（`accept` の位置判定に使う）。
    private var pendingPredictedCenter: CGPoint?
    /// `accept` 待ちの候補時刻。
    private var pendingTime: Double?

    /// - Parameters:
    ///   - seedTime: ユーザーが矩形で指定して顔を見つけた素材時刻。
    ///   - seedBox: その時刻で見つかった顔の bbox（素材フレーム基準の正規化矩形）。
    ///   - range: 素材時刻の閉区間。これを出たら追跡を終える。
    ///   - direction: シードから見てどちら向きに歩くか。
    public init(seedTime: Double, seedBox: CGRect, range: ClosedRange<Double>,
                direction: Direction, options: Options = Options()) {
        self.seedTime = seedTime
        self.range = range
        self.direction = direction
        self.options = options
        self.lastHitBox = seedBox
        self.hitHistory = [(time: seedTime, center: CGPoint(x: seedBox.midX, y: seedBox.midY))]
        self.lastEmittedSourceTime = seedTime
    }

    /// 次に見るべき ROI。歩幅ぶん進めた素材時刻が `range` の外、`maxSteps` に達した、
    /// または連続ミスが上限に達したときは `nil`（もう見るべき時刻がない）。
    ///
    /// シード時刻そのものは返さない（既に検出済みのため）。最初の呼び出しは
    /// `seedTime ± step`。
    ///
    /// ## 端点ステップ
    ///
    /// 歩幅刻み（既定 0.2 秒）は `range` の端点にぴったり届くとは限らない。次の候補時刻が
    /// `range` を出るとき、**直前のステップが `range` の内側だった**場合に限り、クランプした
    /// 端点（前方は `range.upperBound.nextDown`、後方は `range.lowerBound`）で最後の1ステップを
    /// 返してから終了する。既に端点ちょうどに居る（歩幅が割り切れて自然に端点へ乗った）ときは
    /// 重複ステップを出さずにそのまま終了する。
    public mutating func nextStep() -> Step? {
        guard !finished else { return nil }
        guard consecutiveMisses < options.maxConsecutiveMisses else {
            finished = true
            return nil
        }
        let nextStepsTaken = stepsTaken + 1
        guard nextStepsTaken <= options.maxSteps else {
            finished = true
            return nil
        }
        let offset = options.step * Double(nextStepsTaken)
        let candidateTime = direction == .forward ? seedTime + offset : seedTime - offset

        let sourceTime: Double
        if range.contains(candidateTime) {
            sourceTime = candidateTime
        } else if let boundaryTime = clampedBoundaryStepIfNeeded() {
            sourceTime = boundaryTime
            finished = true // 端点ステップは最後の一手。
        } else {
            finished = true
            return nil
        }
        stepsTaken = nextStepsTaken
        lastEmittedSourceTime = sourceTime

        let predictedCenter = extrapolatedCenter(atTime: sourceTime)
        pendingPredictedCenter = predictedCenter
        pendingTime = sourceTime

        let (roi, isFullFrame) = computeROI(center: predictedCenter)
        lastROI = roi
        return Step(sourceTime: sourceTime, roi: roi, isFullFrame: isFullFrame)
    }

    /// 直前のステップが `range` の境界ちょうどでなければ、クランプした端点時刻を返す。
    /// 既に境界ちょうど（歩幅が割り切れて自然に端点へ乗った）なら `nil`。
    private func clampedBoundaryStepIfNeeded() -> Double? {
        let boundary = direction == .forward ? range.upperBound : range.lowerBound
        let epsilon = 1e-9
        guard abs(lastEmittedSourceTime - boundary) > epsilon else { return nil }
        return direction == .forward ? range.upperBound.nextDown : range.lowerBound
    }

    /// `nextStep()` で得た ROI 内で顔検出を行った結果を渡し、どれを採るか（採らないか）を決める。
    ///
    /// - Parameter candidates: ROI 内で見つかった顔（**素材フレーム基準**へ戻し済み）。
    /// - Parameter similarities: 追っている人物プロファイルとの類似度。候補と同じ順・同じ件数。
    ///   `nil` または件数不一致なら「同定は使えない」として位置だけで決める。
    @discardableResult
    public mutating func accept(candidates: [FaceLandmarkSet], similarities: [Float]?) -> Outcome {
        guard !finished else { return Outcome(chosenIndex: nil, isFinished: true) }
        let predictedCenter = pendingPredictedCenter ?? CGPoint(x: lastHitBox.midX, y: lastHitBox.midY)

        var chosen: Int?
        if candidates.isEmpty {
            chosen = nil
        } else if let similarities, similarities.count == candidates.count {
            if let best = bestSimilarityIndex(similarities), similarities[best] >= FaceIdentityThreshold.match {
                chosen = best
            } else {
                chosen = nearestCandidateIndex(candidates: candidates, predictedCenter: predictedCenter)
            }
        } else {
            chosen = nearestCandidateIndex(candidates: candidates, predictedCenter: predictedCenter)
        }

        if let chosen {
            consecutiveMisses = 0
            let face = candidates[chosen]
            lastHitBox = face.boundingBox
            let center = FaceCentroidMatching.centroid(of: face)
            if let time = pendingTime {
                hitHistory.append((time: time, center: center))
                if hitHistory.count > 2 { hitHistory.removeFirst(hitHistory.count - 2) }
            }
        } else {
            consecutiveMisses += 1
            if consecutiveMisses >= options.maxConsecutiveMisses {
                finished = true
            }
        }

        pendingPredictedCenter = nil
        pendingTime = nil
        return Outcome(chosenIndex: chosen, isFinished: finished)
    }

    // MARK: - 内部計算

    /// 直近 2 ヒットの中心差分から求めた速度で、`time` まで等速外挿した中心。
    /// ヒットが 1 つ（シードのみ）のときは速度 0（＝直近ヒットの中心のまま）。
    private func extrapolatedCenter(atTime time: Double) -> CGPoint {
        guard let last = hitHistory.last else {
            return CGPoint(x: lastHitBox.midX, y: lastHitBox.midY)
        }
        var velocity = CGPoint.zero
        if hitHistory.count >= 2 {
            let prev = hitHistory[hitHistory.count - 2]
            let dt = last.time - prev.time
            if dt != 0 {
                velocity = CGPoint(x: (last.center.x - prev.center.x) / CGFloat(dt),
                                   y: (last.center.y - prev.center.y) / CGFloat(dt))
            }
        }
        let maxSpeed = CGFloat(options.maxCenterSpeed)
        velocity.x = min(max(velocity.x, -maxSpeed), maxSpeed)
        velocity.y = min(max(velocity.y, -maxSpeed), maxSpeed)

        let dt = time - last.time
        return CGPoint(x: last.center.x + velocity.x * CGFloat(dt),
                       y: last.center.y + velocity.y * CGFloat(dt))
    }

    /// 連続ミス回数に応じた ROI（前ヒット bbox を膨らませたもの）と、
    /// 全画面フォールバックかどうか。
    private func computeROI(center: CGPoint) -> (CGRect, Bool) {
        guard consecutiveMisses < 3 else {
            return (CGRect(x: 0, y: 0, width: 1, height: 1), true)
        }
        let multiplier: Double
        switch consecutiveMisses {
        case 0: multiplier = options.roiScale
        case 1: multiplier = Self.secondMissMultiplier
        default: multiplier = Self.thirdMissMultiplier
        }

        var width = lastHitBox.width * CGFloat(multiplier)
        var height = lastHitBox.height * CGFloat(multiplier)
        let minSide = CGFloat(options.minROISide)
        let shortSide = min(width, height)
        if shortSide < minSide {
            if shortSide > 0 {
                let scaleUp = minSide / shortSide
                width *= scaleUp
                height *= scaleUp
            } else {
                width = minSide
                height = minSide
            }
        }

        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        return (clampToUnitSquare(rect), false)
    }

    /// `[0, 1]²` へクランプする。はみ出た分は切り落とす（中心をずらして押し込まない）。
    private func clampToUnitSquare(_ rect: CGRect) -> CGRect {
        let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clamped = rect.intersection(unitSquare)
        return clamped.isNull ? .zero : clamped
    }

    private func bestSimilarityIndex(_ similarities: [Float]) -> Int? {
        guard !similarities.isEmpty else { return nil }
        var bestIndex = 0
        var bestValue = similarities[0]
        for (index, value) in similarities.enumerated() where value > bestValue {
            bestIndex = index
            bestValue = value
        }
        return bestIndex
    }

    /// 予測中心に最も近い候補。許容量は直近 ROI の短辺の半分。
    private func nearestCandidateIndex(candidates: [FaceLandmarkSet], predictedCenter: CGPoint) -> Int? {
        guard let roi = lastROI else { return nil }
        let tolerance = min(roi.width, roi.height) * 0.5
        let centroids = candidates.map { FaceCentroidMatching.centroid(of: $0) }
        return FaceCentroidMatching.nearestIndex(to: predictedCenter, in: centroids, tolerance: tolerance)
    }
}
