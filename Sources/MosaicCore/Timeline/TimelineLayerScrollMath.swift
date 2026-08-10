import Foundation

/// レイヤー段の縦スクロール（px 単位）の算術。
///
/// タイムラインは**横が時間軸、縦がレイヤー**の 2 次元だが、この 2 つは
/// 性質がまるで違う:
/// - 横（`TimelineScrollMath`）は「時刻とスクロール量が写像で結ばれる」。
///   中央固定のプレイヘッドがあり、スクロール量からシーク位置を逆算する。
/// - 縦は**ただの一覧**。時刻とは無関係で、何段目が見えているかしか意味がない。
///
/// 混ぜると横の写像に縦の状態が混入するので、別の型・別のファイルに分けてある。
///
/// **動画クリップの段はこの器に入れない**（VLLO と同じで常に見えている必要がある。
/// 何のクリップを編集しているか分からないままレイヤーだけ動くのは読めない）。
/// 器に入るのはモザイク・音声・テキストなどの「上に載る段」だけ。
public struct TimelineLayerViewport: Equatable, Sendable {
    /// 段を全部積んだ高さ（px）。
    public let contentHeight: Double
    /// 画面に見えている高さ（px）。
    public let visibleHeight: Double

    public init(contentHeight: Double, visibleHeight: Double) {
        self.contentHeight = max(0, contentHeight.isFinite ? contentHeight : 0)
        self.visibleHeight = max(0, visibleHeight.isFinite ? visibleHeight : 0)
    }

    /// スクロールできる余地（px）。段が可視高に収まるなら 0。
    public var maximumOffset: Double {
        max(0, contentHeight - visibleHeight)
    }

    /// 縦スクロールが要るか（＝はみ出しているか）。
    /// 見た目のヒント（スクロールバー・影）を出すかの判断に使う。
    public var isScrollable: Bool { maximumOffset > 0.5 }
}

/// レイヤー段の縦スクロールの純ロジック。
public enum TimelineLayerScrollMath {

    /// 提案されたスクロール量を可視範囲へ丸める。
    ///
    /// **ラバーバンドは作らない**（横と違って慣性も中央固定も無く、
    /// 行き過ぎて戻る動きは「段が揺れている」だけに見える）。
    public static func clampedOffset(_ proposed: Double,
                                     viewport: TimelineLayerViewport) -> Double {
        guard proposed.isFinite else { return 0 }
        return min(max(0, proposed), viewport.maximumOffset)
    }

    /// 段の高さの合計。**間隔は段と段の間にだけ入る**（最後の段の下には付けない。
    /// 付けると可視高ちょうどの段数でも「あと少しスクロールできる」状態になり、
    /// 一番下の段が数 px だけ動く）。
    public static func contentHeight(rowHeights: [Double], spacing: Double) -> Double {
        let heights = rowHeights.filter { $0.isFinite && $0 > 0 }
        guard !heights.isEmpty else { return 0 }
        let gaps = Double(heights.count - 1) * max(0, spacing.isFinite ? spacing : 0)
        return heights.reduce(0, +) + gaps
    }

    /// ある段が完全に見えるための最小スクロール量。
    ///
    /// 段をタップ・追加したときに「見えていない段が選ばれた」状態を作らないための計算。
    /// 既に見えているなら現在値をそのまま返す（勝手に動かさない）。
    public static func offsetToReveal(rowIndex: Int,
                                      rowHeights: [Double],
                                      spacing: Double,
                                      currentOffset: Double,
                                      viewport: TimelineLayerViewport) -> Double {
        guard rowHeights.indices.contains(rowIndex) else {
            return clampedOffset(currentOffset, viewport: viewport)
        }
        let top = contentHeight(rowHeights: Array(rowHeights.prefix(rowIndex)), spacing: spacing)
            + (rowIndex > 0 ? spacing : 0)
        let bottom = top + rowHeights[rowIndex]
        let current = clampedOffset(currentOffset, viewport: viewport)
        if top < current {                                   // 上へはみ出している
            return clampedOffset(top, viewport: viewport)
        }
        if bottom > current + viewport.visibleHeight {       // 下へはみ出している
            return clampedOffset(bottom - viewport.visibleHeight, viewport: viewport)
        }
        return current
    }
}
