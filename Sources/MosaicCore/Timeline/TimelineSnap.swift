import Foundation

/// 吸着の判定結果。
public struct TimelineSnapResult: Equatable, Sendable {
    /// 吸着後の合成時刻。吸着しなければ入力そのまま。
    public let time: Double
    /// 吸着先。`nil` なら未吸着。
    ///
    /// **ハプティクスは「`snappedTo` が前回と変わったとき」だけ鳴らす**こと
    /// （毎フレーム `time == snappedTo` で鳴らすと連打になる）。
    public let snappedTo: Double?

    public init(time: Double, snappedTo: Double?) {
        self.time = time
        self.snappedTo = snappedTo
    }

    /// 吸着したか。
    public var isSnapped: Bool { snappedTo != nil }
}

/// タイムライン編集の吸着（純ロジック）。
///
/// ## 使う順序（逆にしないこと）
///
/// **吸着 → クランプ**（`TimelineBandLayout.trimmedBounds`）の順で合成する。
/// 逆順だと、クランプで最小尺に止めた値を吸着が最小尺の内側へ引き戻してしまい、
/// クリップが最小合成尺（`TimelineEditOperations.minimumClipDuration`）を割る。
/// この順序は `TimelineSnapTests.test_snapThenClamp_keepsMinimumDuration` が固定している。
public enum TimelineSnap {
    /// 吸着の既定許容量（px）。秒ではなく px で決める（ズーム段によらず
    /// 指の感覚が一定になる）。秒へ直すのは `TimelineGeometry.duration(forWidth:)`。
    public static let defaultTolerancePixels: Double = 12

    /// 同値とみなす誤差（秒）。クリップ分割由来の境界は浮動小数点で微妙にずれる。
    private static let duplicateTolerance: Double = 1e-9

    /// 吸着候補（合成時刻。昇順・重複除去済み）。
    ///
    /// 候補は「クリップ帯の両端」「適用区間の両端」「プレイヘッド」「0」「全体尺」。
    ///
    /// - Parameter excluding: いま掴んでいる要素の id（`clipID` または `rangeID`）。
    ///   **その要素が出す候補を全部外す**（自分の端に吸着すると操作が固まるため）。
    ///   端単位ではなく要素単位で外すのは、掴んでいない側の端に吸着しても
    ///   結局クランプで弾かれる（最小尺 0 は作れない）ため、区別する実益がないから。
    ///
    ///   **注意**: 帯どうしは接しているので、クリップを 1 本外しただけでは継ぎ目の
    ///   時刻が候補から消えない（隣のクリップが同じ時刻を出す）。継ぎ目そのものを
    ///   外したいときは隣のクリップ id も渡すこと（隣の反対側の端は最小合成尺以上
    ///   離れているので、巻き添えで失う候補の実害は小さい）。
    ///   この挙動は `TimelineSnapTests.test_candidates_excludesGrabbedElement` が固定している。
    public static func candidates(layouts: [TimelineClipLayout],
                                  applySpans: [TimelineApplySpan],
                                  playheadTime: Double,
                                  totalDuration: Double,
                                  excluding: Set<UUID> = []) -> [Double] {
        var values: [Double] = [0]
        for layout in layouts where !excluding.contains(layout.clipID) {
            values.append(layout.bandStart)
            values.append(layout.bandEnd)
        }
        for span in applySpans
        where !excluding.contains(span.rangeID)
            && !(span.anchorClipID.map { excluding.contains($0) } ?? false) {
            values.append(span.start)
            values.append(span.end)
        }
        values.append(playheadTime)
        values.append(totalDuration)

        let sorted = values.filter { $0.isFinite }.sorted()
        var result: [Double] = []
        for value in sorted where result.last.map({ value - $0 > duplicateTolerance }) ?? true {
            result.append(value)
        }
        return result
    }

    /// 最寄り候補が `tolerance` 内なら吸着する。
    ///
    /// 距離が同じ候補が複数あるときは**小さい時刻**を選ぶ（並び順で結果が変わらないよう
    /// 決めておく。`candidates` は昇順なので先勝ちでよい）。
    /// `time` が非有限、`tolerance` が非有限・0 以下のときは吸着しない。
    public static func snapped(time: Double,
                               candidates: [Double],
                               tolerance: Double) -> TimelineSnapResult {
        let unsnapped = TimelineSnapResult(time: time, snappedTo: nil)
        guard time.isFinite, tolerance.isFinite, tolerance > 0 else { return unsnapped }
        var best: Double?
        var bestDistance = Double.infinity
        for candidate in candidates where candidate.isFinite {
            let distance = abs(candidate - time)
            if distance < bestDistance || (distance == bestDistance && candidate < (best ?? .infinity)) {
                bestDistance = distance
                best = candidate
            }
        }
        guard let best, bestDistance <= tolerance else { return unsnapped }
        return TimelineSnapResult(time: best, snappedTo: best)
    }
}
