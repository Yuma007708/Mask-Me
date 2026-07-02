import CoreGraphics
import Foundation

/// ランドマーク座標の時間方向 EMA（指数移動平均）スムーザ。
///
/// 検出は 1 フレームごとに独立なので、静止した顔でもランドマークが数ピクセル単位で
/// 揺れ、モザイクの輪郭がちらつく。描画直前にこのスムーザを通すことでフレーム間の
/// 微小ジャンプを吸収する。検出キャッシュ（計測系）には適用せず、描画系だけに使う。
///
/// - 前フレームの出力と bbox IoU > 0.3 で対応づいた顔だけを平滑化する
///   （新規の顔・対応が取れない顔はそのまま通す）。
/// - centroid の移動量が `snapDistance`（正規化座標）を超えるフレームは
///   実際に顔が速く動いたと判断してスナップ（素通し）し、追従遅れを防ぐ。
/// - シーク・ストリーム切替時は `reset()` を呼んで状態を捨てること。
public final class LandmarkSmoother {
    /// 新しい観測値の重み（EMA 係数）。1.0 で平滑化なし、小さいほど滑らかだが遅延が増える。
    public var alpha: Float
    /// このフレーム間移動量（正規化座標での centroid 距離）を超えたらスナップする閾値。
    public var snapDistance: Float

    private var previous: [FaceLandmarkSet] = []

    public init(alpha: Float = 0.5, snapDistance: Float = 0.05) {
        self.alpha = alpha
        self.snapDistance = snapDistance
    }

    /// 状態を破棄する（シーク・動画切替・プレビュー再開時に呼ぶ）。
    public func reset() {
        previous = []
    }

    /// 現フレームの検出顔を平滑化して返す。呼び出しは時刻順の直列を前提とする。
    public func smooth(_ faces: [FaceLandmarkSet]) -> [FaceLandmarkSet] {
        let smoothed = faces.map { face -> FaceLandmarkSet in
            guard let prev = face.counterpart(in: previous),
                  prev.points.count == face.points.count else { return face }
            if centroidDistance(prev, face) > snapDistance { return face }
            // EMA: prev * (1 - alpha) + face * alpha
            return prev.interpolated(to: face, alpha: alpha)
        }
        previous = smoothed
        return smoothed
    }

    private func centroidDistance(_ a: FaceLandmarkSet, _ b: FaceLandmarkSet) -> Float {
        func centroid(_ set: FaceLandmarkSet) -> (x: Float, y: Float) {
            guard !set.points.isEmpty else { return (0, 0) }
            var sx: Float = 0, sy: Float = 0
            for p in set.points { sx += p.x; sy += p.y }
            let n = Float(set.points.count)
            return (sx / n, sy / n)
        }
        let ca = centroid(a), cb = centroid(b)
        let dx = ca.x - cb.x, dy = ca.y - cb.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
