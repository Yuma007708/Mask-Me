import CoreGraphics
import Foundation

/// Builds the alpha mask that tells the Metal kernel *where* to mosaic. Each
/// enabled region is filled as the **convex hull** of its landmarks, so the
/// masked area follows the face as it rotates / tilts (the hull turns with the
/// landmarks) while the mosaic blocks themselves stay axis-aligned — the
/// TikTok-style "吸い付く" look from the reference, hard-edged and solid.
public struct FaceMaskBuilder: Sendable {
    /// How much each region's outline is inflated, as a fraction of the image's
    /// smaller dimension. A little dilation keeps hair/edge pixels covered even
    /// as the face moves between frames.
    public let dilation: CGFloat

    /// Which regions to include in the mask. Toggling a region off leaves it
    /// un-mosaicked. Defaults to every region.
    public var enabledRegions: Set<FaceRegion>

    public init(
        dilation: CGFloat = 0.015,
        enabledRegions: Set<FaceRegion> = Set(FaceRegion.allCases)
    ) {
        self.dilation = dilation
        self.enabledRegions = enabledRegions
    }

    /// A region's fill path together with the mask intensity it should write.
    public struct RegionPath: Sendable {
        public let path: CGPath
        public let value: Float
    }

    /// Builds one fill path per region present in `landmarks`, in painter order
    /// (broad face first, then the finer eye / mouth regions on top).
    public func regionPaths(for landmarks: FaceLandmarkSet, in size: CGSize) -> [RegionPath] {
        let inset = dilation * min(size.width, size.height)
        // Face first so eyes/lips overwrite it with their higher mask values.
        let order: [FaceRegion] = [.faceOval, .leftEye, .rightEye, .lips]
        return order.filter(enabledRegions.contains).compactMap { region in
            let points = landmarks.polygon(for: region, in: size)
            guard points.count >= 3 else { return nil }
            guard let path = Self.convexHullPath(through: points, expandedBy: inset) else {
                return nil
            }
            return RegionPath(path: path, value: region.maskValue)
        }
    }

    /// The union bounding box of every region path. Useful for tests and for
    /// scoping the GPU work to the affected area.
    public func boundingBox(for landmarks: FaceLandmarkSet, in size: CGSize) -> CGRect {
        regionPaths(for: landmarks, in: size)
            .reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    }

    /// Renders the region paths into an 8-bit single-channel mask. Pixel values
    /// encode the region (see ``FaceRegion/maskValue``); `0` means "leave the
    /// original pixel untouched". Returns the raw row-major bytes plus the
    /// bytes-per-row used, or `nil` if a context could not be created.
    public func renderMask(
        for landmarks: FaceLandmarkSet,
        width: Int,
        height: Int
    ) -> (bytes: [UInt8], bytesPerRow: Int)? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let success: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            let size = CGSize(width: width, height: height)
            for region in regionPaths(for: landmarks, in: size) {
                context.addPath(region.path)
                context.setFillColor(gray: CGFloat(region.value), alpha: 1)
                context.fillPath()
            }
            return true
        }
        return success ? (bytes, bytesPerRow) : nil
    }

    // MARK: - Path construction

    /// Builds a closed convex-hull path around `points`, dilated outward from the
    /// centroid by `inset`. The hull is a solid polygon that rotates with the
    /// landmarks, so a tilted / turned face stays covered with hard edges (vs. an
    /// axis-aligned box, which would spill onto the background for an angled face).
    static func convexHullPath(through points: [CGPoint], expandedBy inset: CGFloat) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let hull = convexHull(of: points)
        guard hull.count >= 3 else { return nil }
        let expanded = inset > 0 ? expand(hull, by: inset) : hull
        let path = CGMutablePath()
        path.addLines(between: expanded)
        path.closeSubpath()
        return path
    }

    /// Andrew's monotone-chain convex hull. Returns the hull vertices in order.
    static func convexHull(of points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ origin: CGPoint, _ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            (lhs.x - origin.x) * (rhs.y - origin.y) - (lhs.y - origin.y) * (rhs.x - origin.x)
        }

        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Builds a closed, smoothed path through `points`, optionally dilated
    /// outward from the centroid by `inset` points. Smoothing uses a
    /// Catmull-Rom-style quad approximation through edge midpoints, which keeps
    /// the outline rounded without overshooting concave eye/lip contours.
    static func smoothClosedPath(through points: [CGPoint], expandedBy inset: CGFloat) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let pts = inset > 0 ? expand(points, by: inset) : points
        let path = CGMutablePath()
        let count = pts.count

        let first = midpoint(pts[count - 1], pts[0])
        path.move(to: first)
        for index in 0..<count {
            let current = pts[index]
            let next = pts[(index + 1) % count]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    private static func expand(_ points: [CGPoint], by inset: CGFloat) -> [CGPoint] {
        let centroid = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let n = CGFloat(points.count)
        let center = CGPoint(x: centroid.x / n, y: centroid.y / n)
        return points.map { point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            let length = max(hypot(dx, dy), 0.0001)
            return CGPoint(
                x: point.x + dx / length * inset,
                y: point.y + dy / length * inset
            )
        }
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
