import Foundation

/// 範囲指定サーチが置いた暫定矩形マスク（`ObjectMask.isRegionPlaceholder == true`）を、
/// 第 2 段のトラッカーが実際に検出・書き込みした素材時刻の台帳（`coveredTimes`）から見て
/// 外してよいかを判定する純ロジック。
///
/// **`MosaicCore` は MediaPipe に依存しない。** `FaceLandmarkSet` すら扱わず、Foundation /
/// CoreGraphics の値だけを受け取る。`coveredTimes` の集め方（`mergeDetection` で検出キャッシュへ
/// 書き込んだ素材時刻を集計する部分）はアプリ層の責務。
///
/// ## 判定対象は「シードした区間」ではなく「クリップ全区間」
///
/// 暫定矩形はキーフレーム 1 個で時間範囲を持たず、`ObjectMaskResolver.placements` は
/// `anchor.clipID` でしか絞り込まない。したがって矩形は `clip.sourceStart...sourceEnd`
/// の**全区間**に貼り付いている。シード走査がその一部しか追えていなければ、
/// 追えなかった残りの区間で矩形が消えると露出が増える。判定範囲は必ずクリップ全区間で
/// 渡すこと（呼び出し側の責務）。
///
/// ## 迷ったら不合格（矩形を残す）
///
/// プライバシーアプリなので、判定はどの分岐でも「疑わしければ覆えていない」に倒す。
public enum RegionPlaceholderAudit {
    /// 判定の閾値。`max*Gap` / `edge*Tolerance` は素材秒（source）と合成秒（composition）の
    /// 両方の単位を持つ（`rate` を挟んで対応する2つの値を同時に満たす必要がある）。
    public struct Thresholds: Sendable {
        /// 隣接する被覆時刻の間に許す最大の穴（素材秒）。
        ///
        /// 書き出しは `DetectionBridge`（`bridgeWindow = 8/15` 秒）しか穴を跨げない。
        /// 穴の全点が両端から `bridgeWindow` 以内に収まるよう、その2倍を上限にする。
        public var maxSourceGap: Double
        /// 隣接する被覆時刻の間に許す最大の穴（合成秒）。
        ///
        /// 露出の体感は合成時刻（画面に映る時間軸）で起きる。`rate` が小さい
        /// （スロー再生の）クリップでは素材秒の穴がそのまま長時間の露出になるため、
        /// `g / rate <= maxCompositionGap` も同時に要求する。
        public var maxCompositionGap: Double
        /// 区間の両端で許す未被覆の長さ（素材秒）。
        ///
        /// 端はブリッジが原理的に効かない（片側にしか検出が無いと `DetectionBridge.faces`
        /// は空を返す）。検出キャッシュの丸め幅1バケット分（`bucketFPS: 15`）だけ許す。
        public var edgeSourceTolerance: Double
        /// 区間の両端で許す未被覆の長さ（合成秒）。端も合成時刻で二重に縛る。
        public var edgeCompositionTolerance: Double
        /// これ未満の被覆時刻数は退化ケースとして足切りする。
        public var minCoveredTimes: Int
        /// 区間長（合成秒 = `spanLength / rate`）がこれを超えたら判定自体をしない。
        /// 算術だけで（`coveredTimes` に触れる前に）判定できるので、暴走防止として最初に効かせる。
        public var maxCompositionSpan: Double
        /// `coveredTimes`（フィルタ後）の件数がこれを超えたら判定自体をしない
        /// （ソート費用の上限。極端に長い区間・高頻度書き込みの暴走防止）。
        public var maxCoveredTimes: Int
        /// 人物同定が要るときに必要な最低確認回数。
        public var minIdentityConfirmations: Int

        public init(maxSourceGap: Double = 8.0 / 15.0,
                    maxCompositionGap: Double = 0.5,
                    edgeSourceTolerance: Double = 1.0 / 15.0,
                    edgeCompositionTolerance: Double = 0.5,
                    minCoveredTimes: Int = 2,
                    maxCompositionSpan: Double = 600,
                    maxCoveredTimes: Int = 20_000,
                    minIdentityConfirmations: Int = 3) {
            self.maxSourceGap = maxSourceGap
            self.maxCompositionGap = maxCompositionGap
            self.edgeSourceTolerance = edgeSourceTolerance
            self.edgeCompositionTolerance = edgeCompositionTolerance
            self.minCoveredTimes = minCoveredTimes
            self.maxCompositionSpan = maxCompositionSpan
            self.maxCoveredTimes = maxCoveredTimes
            self.minIdentityConfirmations = minIdentityConfirmations
        }
    }

    /// 不合格・合格の理由。デバッグ・テストのための内訳。
    public enum Reason: Equatable, Sendable {
        case covered
        case emptySpan
        case invalidRate
        case spanTooLong
        case anchorMismatch
        case tooFewCoveredTimes
        /// 先頭の未被覆（素材秒, 合成秒）。
        case headUncovered(source: Double, composition: Double)
        /// 末尾の未被覆（素材秒, 合成秒）。
        case tailUncovered(source: Double, composition: Double)
        /// 中間の穴（素材秒, 合成秒）。
        case gapTooLong(source: Double, composition: Double)
        case identityUnconfirmed(Int)
    }

    /// 判定結果。
    public struct Verdict: Equatable, Sendable {
        public let isCovered: Bool
        /// span 内にフィルタされた被覆時刻の件数。
        public let coveredCount: Int
        /// 拡張列（両端 + 被覆時刻）に見つかった最大の穴（素材秒）。
        public let largestSourceGap: Double
        /// 同じ穴の合成秒表現（`largestSourceGap / rate`）。
        public let largestCompositionGap: Double
        public let reason: Reason

        public init(isCovered: Bool, coveredCount: Int, largestSourceGap: Double,
                    largestCompositionGap: Double, reason: Reason) {
            self.isCovered = isCovered
            self.coveredCount = coveredCount
            self.largestSourceGap = largestSourceGap
            self.largestCompositionGap = largestCompositionGap
            self.reason = reason
        }
    }

    private static func failing(reason: Reason, coveredCount: Int = 0, largestSourceGap: Double = 0,
                                largestCompositionGap: Double = 0) -> Verdict {
        Verdict(isCovered: false, coveredCount: coveredCount, largestSourceGap: largestSourceGap,
                largestCompositionGap: largestCompositionGap, reason: reason)
    }

    // 判定に要る値がそのぶんだけある（span/rate/coveredTimes/identityConfirmations/
    // requiresIdentity/anchorInsideRect）。1つの構造体へまとめるほどの凝集性は無い。
    // swiftlint:disable function_parameter_count
    /// 暫定矩形を外してよいかを判定する。
    ///
    /// - Parameters:
    ///   - span: 判定対象区間（**クリップ全区間**の素材時刻。シードした区間ではない）。
    ///   - rate: `clip.rate`。素材秒 → 合成秒 は `÷ rate`。
    ///   - coveredTimes: 第2段のトラッカーが実際に検出・書き込みした素材時刻の一覧
    ///     （順不同でよい。内部で `span` 内へフィルタし昇順化する）。
    ///   - identityConfirmations: 追跡中の人物と一致したと確認できたバケット数。
    ///   - requiresIdentity: 人物同定を必須にするか（矩形が特定人物に紐づくシードのときのみ true）。
    ///   - anchorInsideRect: シード時刻の被覆顔の重心が矩形内（の許容範囲）にあるか。
    public static func evaluate(
        span: ClosedRange<Double>,
        rate: Double,
        coveredTimes: [Double],
        identityConfirmations: Int,
        requiresIdentity: Bool,
        anchorInsideRect: Bool,
        thresholds: Thresholds = .init()
    ) -> Verdict {
        let spanLength = span.upperBound - span.lowerBound
        guard spanLength > 0 else { return failing(reason: .emptySpan) }
        guard rate.isFinite, rate > 0 else { return failing(reason: .invalidRate) }
        // 算術だけで先に判定する（coveredTimes に触れる前）。極端に長い区間の暴走防止。
        guard spanLength / rate <= thresholds.maxCompositionSpan else { return failing(reason: .spanTooLong) }
        guard anchorInsideRect else { return failing(reason: .anchorMismatch) }

        let sorted = coveredTimes.filter { span.contains($0) }.sorted()
        guard sorted.count <= thresholds.maxCoveredTimes else { return failing(reason: .spanTooLong) }
        guard sorted.count >= thresholds.minCoveredTimes else { return failing(reason: .tooFewCoveredTimes) }

        // 端と穴を1本の式に統一: 両端を加えた拡張列を1回走査する。
        let points = [span.lowerBound] + sorted + [span.upperBound]
        var largestSourceGap = 0.0
        var largestCompositionGap = 0.0
        let lastIndex = points.count - 2
        for index in 0..<(points.count - 1) {
            let gap = points[index + 1] - points[index]
            let compositionGap = gap / rate
            let isHead = index == 0
            let isTail = index == lastIndex
            let sourceLimit = (isHead || isTail) ? thresholds.edgeSourceTolerance : thresholds.maxSourceGap
            let compositionLimit = (isHead || isTail)
                ? thresholds.edgeCompositionTolerance
                : thresholds.maxCompositionGap

            if gap > sourceLimit || compositionGap > compositionLimit {
                let reason: Reason = isHead
                    ? .headUncovered(source: gap, composition: compositionGap)
                    : (isTail
                        ? .tailUncovered(source: gap, composition: compositionGap)
                        : .gapTooLong(source: gap, composition: compositionGap))
                return failing(reason: reason, coveredCount: sorted.count,
                                largestSourceGap: gap, largestCompositionGap: compositionGap)
            }

            largestSourceGap = max(largestSourceGap, gap)
            largestCompositionGap = max(largestCompositionGap, compositionGap)
        }

        if requiresIdentity, identityConfirmations < thresholds.minIdentityConfirmations {
            return Verdict(isCovered: false, coveredCount: sorted.count, largestSourceGap: largestSourceGap,
                           largestCompositionGap: largestCompositionGap,
                           reason: .identityUnconfirmed(identityConfirmations))
        }

        return Verdict(isCovered: true, coveredCount: sorted.count, largestSourceGap: largestSourceGap,
                       largestCompositionGap: largestCompositionGap, reason: .covered)
    }
    // swiftlint:enable function_parameter_count
}
