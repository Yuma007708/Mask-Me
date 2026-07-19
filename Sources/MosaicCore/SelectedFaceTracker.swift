import CoreGraphics
import Foundation

/// 「選択された顔」を時系列で追跡し、各フレームの検出顔から選択顔だけを残すフィルタ。
///
/// 選択時の静的な顔位置と毎フレーム照合すると、顔が移動しただけで距離閾値を超えて
/// モザイクが外れる（実機報告: 動く顔・フレームアウト→別位置で再インした顔が
/// 以降まったくマスクされない）。このトラッカーはマッチするたびに追跡位置を検出位置へ
/// 更新し、単一選択 × 単一検出のフレームでは距離条件なしで再捕捉する。
///
/// フレームは時刻順に流すこと（エクスポートループ・ライブ再生とも時刻順で呼ばれる前提）。
public struct SelectedFaceTracker {
    /// 追跡位置とのマッチ距離（正規化座標）。プレビューの重心マッチングと同値。
    public static let matchDistance: CGFloat = 0.5

    private var tracked: [CGPoint]

    /// - Parameter initialCentroids: 選択された顔の初期重心（正規化座標）。
    ///   空のときは「全顔選択」とみなし `filter` が素通しになる。
    public init(initialCentroids: [CGPoint]) {
        tracked = initialCentroids
    }

    /// このフレームの検出顔から選択顔だけを残す。マッチした追跡位置は更新される。
    public mutating func filter(_ faces: [FaceLandmarkSet]) -> [FaceLandmarkSet] {
        guard !tracked.isEmpty else { return faces }
        var kept: [FaceLandmarkSet] = []
        for face in faces {
            let fc = Self.centroid(of: face)
            guard let (idx, dist) = tracked.enumerated()
                .map({ ($0.offset, hypot(fc.x - $0.element.x, fc.y - $0.element.y)) })
                .min(by: { $0.1 < $1.1 }) else { continue }
            // 単一選択 × 単一検出は同一人物とみなして無条件で再捕捉する。
            // フレームアウト→反対側から再インすると距離 0.5 を超え、位置追従だけでは
            // 永久に再マッチできないため。
            let solePair = tracked.count == 1 && faces.count == 1
            if solePair || dist < Self.matchDistance {
                kept.append(face)
                tracked[idx] = fc
            }
        }
        return kept
    }

    /// 正規化座標での全ランドマーク重心。
    public static func centroid(of lm: FaceLandmarkSet) -> CGPoint {
        guard !lm.points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        var sx: Float = 0, sy: Float = 0
        for p in lm.points { sx += p.x; sy += p.y }
        let n = Float(lm.points.count)
        return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
    }
}
