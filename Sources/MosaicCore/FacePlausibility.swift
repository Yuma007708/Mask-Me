import CoreGraphics
import Foundation

/// Geometric plausibility check that rejects spurious "faces" the landmarker
/// sometimes reports on non-face regions (e.g. a torso in dim light). Works on
/// the normalized landmark coordinates, so it needs no image size and is pure /
/// unit-testable. A set that fails this should be treated as "no face".
extension FaceLandmarkSet {
    /// Tunable bounds for what counts as a plausible human face.
    public enum Plausibility {
        /// Face bounding box (normalized) must be at least this on its larger side.
        public static let minSpan: CGFloat = 0.02          // 遠距離・広角ショットの小さい顔を拾えるよう緩和
        /// …and no larger than this (a real face never exceeds the frame much).
        public static let maxSpan: CGFloat = 1.6
        /// Face height / width must fall in this range. Wide lower/upper margins so
        /// tilted (roll) and angled faces — whose axis-aligned box is squarer or
        /// wider than an upright face — are not falsely rejected. Only clearly
        /// body-like tall-thin shapes fall outside.
        public static let aspectRange: ClosedRange<CGFloat> = 0.4...3.0
        /// Inter-ocular distance / face width must fall in this range.
        public static let eyeWidthRatioRange: ClosedRange<CGFloat> = 0.10...0.95  // 斜め向きの顔を許容するよう緩和
    }

    /// `true` when the landmarks form a geometrically plausible face.
    /// Uses the static `Plausibility` defaults — call `isPlausibleFace(minSpan:eyeRatioRange:)`
    /// to override them with user-defined settings.
    public var isPlausibleFace: Bool {
        isPlausibleFace(minSpan: Plausibility.minSpan,
                        eyeRatioRange: Plausibility.eyeWidthRatioRange)
    }

    /// Parameterized variant — used by `MediaPipeFaceLandmarkerAdapter` to apply
    /// user-configured `DetectionSettings` without coupling MosaicCore to the app layer.
    public func isPlausibleFace(
        minSpan: CGFloat,
        eyeRatioRange: ClosedRange<CGFloat>
    ) -> Bool {
        plausibilityScore(minSpan: minSpan, eyeRatioRange: eyeRatioRange) > 0
    }

    /// 幾何学的妥当性を 0...1 の連続スコアで返す。0 は完全棄却、1 は正面 478点顔。
    /// `eyeRatioRange` の下限を下回った境界顔（横顔・小顔）は完全棄却ではなく低スコアで
    /// 残し、`LandmarkSmoother`/`DetectionBridge`/`TrackingEvaluator` の EMA が均せる。
    /// 完全に棄却する条件: 面数不足、span/aspect の物理的破綻、目が口より下（顔向き逆）。
    public func plausibilityScore(
        minSpan: CGFloat,
        eyeRatioRange: ClosedRange<CGFloat>
    ) -> Float {
        let unit = CGSize(width: 1, height: 1)
        let oval = polygon(for: .faceOval, in: unit)
        guard oval.count >= 3 else { return 0 }
        guard points.count > Self.leftEyeOuterIndex else { return 0 }

        var minX = oval[0].x, maxX = oval[0].x
        var minY = oval[0].y, maxY = oval[0].y
        for point in oval.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return 0 }

        let span = max(width, height)
        guard span >= minSpan, span <= Plausibility.maxSpan else { return 0 }

        let aspect = height / width
        guard Plausibility.aspectRange.contains(aspect) else { return 0 }

        let rightEye = points[Self.rightEyeOuterIndex].point(in: unit)
        let leftEye = points[Self.leftEyeOuterIndex].point(in: unit)
        let eyeDistance = hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y)
        let eyeRatio = eyeDistance / width

        // Eyes must sit above the mouth (image y grows downward). この幾何は妥協しない。
        let mouth = polygon(for: .lips, in: unit)
        guard mouth.count >= 3 else { return 0 }
        let mouthY = mouth.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(mouth.count)
        let eyeY = (rightEye.y + leftEye.y) / 2
        guard eyeY < mouthY else { return 0 }

        // 目間比のソフトマージン: 下限をわずかに割った候補は 0.3〜1.0 のスコアで残し、
        // 大きく外れた（下限×0.6 未満）候補は完全棄却する。
        if eyeRatioRange.contains(eyeRatio) {
            return 1.0
        }
        let softLower = eyeRatioRange.lowerBound * 0.6
        if eyeRatio < softLower { return 0 }
        // 線形補間: softLower → 0.3、lowerBound → 1.0
        let t = (eyeRatio - softLower) / (eyeRatioRange.lowerBound - softLower)
        return Float(max(0.3, min(1.0, 0.3 + 0.7 * t)))
    }
}
