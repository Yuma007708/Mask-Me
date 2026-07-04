import CoreGraphics
import Foundation

/// フルフレームのピクセル空間で定義された2D相似変換 `p' = scale·R(rotation)·p + (tx, ty)`。
///
/// オプティカルフロー追跡（App 層の OpticalFlowTracker）が返す対応点ペアから顔の
/// フレーム間運動を推定し、最後に検出できたランドマーク一式を前進させるために使う。
/// 推定は Umeyama 法（最小二乗の相似変換フィット）+ 外れ値除去の再フィット 1 回。
/// OpenCV 非依存の純粋幾何なので MosaicCore に置き、swift test で検証する。
public struct SimilarityTransform: Sendable, Equatable {
    public let scale: CGFloat
    public let rotation: CGFloat
    public let tx: CGFloat
    public let ty: CGFloat

    public init(scale: CGFloat, rotation: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.scale = scale
        self.rotation = rotation
        self.tx = tx
        self.ty = ty
    }

    /// 対応点ペアから相似変換を推定する。
    /// - 6 ペア未満は nil（自由度 4 に対し余裕を要求）。
    /// - 1 回フィット → 残差が max(2px, 中央値の 2 倍) を超える点を除去 → 再フィット。
    ///   除去後のインライア比が 0.5 未満なら「動きが一貫していない」として nil。
    public static func estimate(from: [CGPoint], to: [CGPoint]) -> SimilarityTransform? {
        guard from.count == to.count, from.count >= 6 else { return nil }
        guard let first = fit(from: from, to: to) else { return nil }
        let residuals = zip(from, to).map { f, t -> CGFloat in
            let p = first.applyPoint(f)
            return hypot(p.x - t.x, p.y - t.y)
        }
        let sorted = residuals.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(2.0, median * 2.0)
        var inFrom: [CGPoint] = [], inTo: [CGPoint] = []
        for (i, r) in residuals.enumerated() where r <= threshold {
            inFrom.append(from[i])
            inTo.append(to[i])
        }
        guard inFrom.count >= 6,
              CGFloat(inFrom.count) / CGFloat(from.count) >= 0.5 else { return nil }
        return fit(from: inFrom, to: inTo)
    }

    /// Umeyama 法による最小二乗フィット（反射なし・等方スケール）。
    private static func fit(from: [CGPoint], to: [CGPoint]) -> SimilarityTransform? {
        let n = CGFloat(from.count)
        var mfx: CGFloat = 0, mfy: CGFloat = 0, mtx: CGFloat = 0, mty: CGFloat = 0
        for i in from.indices {
            mfx += from[i].x; mfy += from[i].y
            mtx += to[i].x;   mty += to[i].y
        }
        mfx /= n; mfy /= n; mtx /= n; mty /= n
        // 中心化した点で a = Σ(f·t)（内積和）, b = Σ(f×t)（外積和）, norm = Σ|f|²
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for i in from.indices {
            let fx = from[i].x - mfx, fy = from[i].y - mfy
            let tx = to[i].x - mtx,   ty = to[i].y - mty
            a += fx * tx + fy * ty
            b += fx * ty - fy * tx
            norm += fx * fx + fy * fy
        }
        guard norm > .ulpOfOne else { return nil }
        let scale = (a * a + b * b).squareRoot() / norm
        guard scale > .ulpOfOne else { return nil }
        let rotation = atan2(b, a)
        // t = mean_to − scale·R·mean_from
        let cosR = cos(rotation), sinR = sin(rotation)
        let tx = mtx - scale * (cosR * mfx - sinR * mfy)
        let ty = mty - scale * (sinR * mfx + cosR * mfy)
        return SimilarityTransform(scale: scale, rotation: rotation, tx: tx, ty: ty)
    }

    /// ピクセル空間の 1 点に変換を適用する。
    public func applyPoint(_ p: CGPoint) -> CGPoint {
        let cosR = cos(rotation), sinR = sin(rotation)
        return CGPoint(x: scale * (cosR * p.x - sinR * p.y) + tx,
                       y: scale * (sinR * p.x + cosR * p.y) + ty)
    }

    /// 正規化ランドマーク一式に適用する（ピクセル空間経由、z/confidence は保持）。
    public func apply(to set: FaceLandmarkSet, imageSize: CGSize) -> FaceLandmarkSet {
        guard imageSize.width > 0, imageSize.height > 0 else { return set }
        let moved = set.points.map { lm -> FaceLandmark in
            let p = applyPoint(CGPoint(x: CGFloat(lm.x) * imageSize.width,
                                       y: CGFloat(lm.y) * imageSize.height))
            return FaceLandmark(x: Float(p.x / imageSize.width),
                                y: Float(p.y / imageSize.height),
                                z: lm.z)
        }
        return FaceLandmarkSet(points: moved, confidence: set.confidence)
    }

    /// 正規化矩形に適用する（中心を変換しサイズを scale 倍する axis-aligned 近似）。
    public func apply(toNormalizedRect rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let center = applyPoint(CGPoint(x: rect.midX * imageSize.width,
                                        y: rect.midY * imageSize.height))
        let w = rect.width * imageSize.width * scale
        let h = rect.height * imageSize.height * scale
        return CGRect(x: (center.x - w / 2) / imageSize.width,
                      y: (center.y - h / 2) / imageSize.height,
                      width: w / imageSize.width,
                      height: h / imageSize.height)
    }
}
