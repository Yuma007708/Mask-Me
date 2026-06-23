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
        public static let minSpan: CGFloat = 0.04
        /// …and no larger than this (a real face never exceeds the frame much).
        public static let maxSpan: CGFloat = 1.6
        /// Face height / width must fall in this range.
        public static let aspectRange: ClosedRange<CGFloat> = 0.7...2.6
        /// Inter-ocular distance / face width must fall in this range.
        public static let eyeWidthRatioRange: ClosedRange<CGFloat> = 0.15...0.85
    }

    /// `true` when the landmarks form a geometrically plausible face.
    public var isPlausibleFace: Bool {
        let unit = CGSize(width: 1, height: 1)
        let oval = polygon(for: .faceOval, in: unit)
        guard oval.count >= 3 else { return false }
        guard points.count > Self.leftEyeOuterIndex else { return false }

        var minX = oval[0].x, maxX = oval[0].x
        var minY = oval[0].y, maxY = oval[0].y
        for point in oval.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return false }

        let span = max(width, height)
        guard span >= Plausibility.minSpan, span <= Plausibility.maxSpan else { return false }

        let aspect = height / width
        guard Plausibility.aspectRange.contains(aspect) else { return false }

        let rightEye = points[Self.rightEyeOuterIndex].point(in: unit)
        let leftEye = points[Self.leftEyeOuterIndex].point(in: unit)
        let eyeDistance = hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y)
        let eyeRatio = eyeDistance / width
        guard Plausibility.eyeWidthRatioRange.contains(eyeRatio) else { return false }

        // Eyes must sit above the mouth (image y grows downward).
        let mouth = polygon(for: .lips, in: unit)
        guard mouth.count >= 3 else { return false }
        let mouthY = mouth.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(mouth.count)
        let eyeY = (rightEye.y + leftEye.y) / 2
        guard eyeY < mouthY else { return false }

        return true
    }
}
