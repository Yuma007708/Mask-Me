import CoreGraphics
import Foundation

/// Builds the alpha mask that tells the Metal kernel *where* (and *how finely*)
/// to mosaic. The mask is rendered from landmark-derived `CGPath`s so the
/// pixelation hugs the face contour — the "吸い付く" look from the reference.
public struct FaceMaskBuilder: Sendable {
    /// How much each region's outline is inflated, as a fraction of the image's
    /// smaller dimension. A little dilation keeps hair/edge pixels covered even
    /// as the face moves between frames.
    public let dilation: CGFloat

    public init(dilation: CGFloat = 0.015) {
        self.dilation = dilation
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
        return order.compactMap { region in
            let points = landmarks.polygon(for: region, in: size)
            guard points.count >= 3 else { return nil }
            guard let path = Self.smoothClosedPath(through: points, expandedBy: inset) else {
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
