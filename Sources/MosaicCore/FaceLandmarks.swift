import CoreGraphics
import Foundation

/// A single normalized 3D face landmark.
///
/// Coordinates follow the MediaPipe Face Landmarker convention:
/// `x` and `y` are normalized to `[0, 1]` relative to the image width / height
/// (origin at the top-left), and `z` is the relative depth (smaller is closer to
/// the camera). These are intentionally framework-agnostic so that `MosaicCore`
/// never has to link against MediaPipe — the app target adapts MediaPipe's
/// result type into this value type.
public struct FaceLandmark: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The landmark projected into a pixel-space point for an image of `size`.
    @inlinable
    public func point(in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
    }
}

/// An immutable set of face landmarks for a single detected face.
///
/// MediaPipe's Face Landmarker emits 478 landmarks per face. Consumers should
/// treat `points` as opaque and address individual vertices through the region
/// index constants in ``FaceRegion`` rather than hard-coding indices.
public struct FaceLandmarkSet: Sendable, Equatable {
    /// The full landmark list, in MediaPipe canonical order.
    public let points: [FaceLandmark]
    /// Detection confidence in `[0, 1]`, as reported by the landmarker.
    public let confidence: Float

    public init(points: [FaceLandmark], confidence: Float) {
        self.points = points
        self.confidence = confidence
    }

    /// The number of landmarks emitted by a full MediaPipe face mesh.
    public static let fullMeshCount = 478

    /// `true` when the set contains a plausible full face mesh.
    public var isFullMesh: Bool { points.count >= Self.fullMeshCount }

    /// Returns the landmarks for the given region as pixel-space points.
    public func polygon(for region: FaceRegion, in size: CGSize) -> [CGPoint] {
        region.indices.compactMap { index in
            guard index >= 0, index < points.count else { return nil }
            return points[index].point(in: size)
        }
    }

    /// Outer eye-corner landmark indices (MediaPipe canonical), used to derive
    /// the in-plane roll so the mosaic blocks can follow a tilted face.
    public static let rightEyeOuterIndex = 33
    public static let leftEyeOuterIndex = 263

    /// Centroid of all landmarks in pixel space (the mosaic block grid is
    /// anchored here so it rotates about the face center).
    public func centroid(in size: CGSize) -> CGPoint {
        guard !points.isEmpty else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += CGFloat(point.x)
            sumY += CGFloat(point.y)
        }
        let count = CGFloat(points.count)
        return CGPoint(x: sumX / count * size.width, y: sumY / count * size.height)
    }

    /// In-plane roll angle in radians, derived from the eye-corner line. Returns
    /// `0` when the eye landmarks are unavailable (partial mesh).
    public func rollAngle(in size: CGSize) -> Float {
        guard points.count > Self.leftEyeOuterIndex else { return 0 }
        let right = points[Self.rightEyeOuterIndex].point(in: size)
        let left = points[Self.leftEyeOuterIndex].point(in: size)
        return Float(atan2(left.y - right.y, left.x - right.x))
    }
}

extension FaceLandmarkSet {
    /// 全ランドマークを囲む最小矩形（左上原点・`[0, 1]` 正規化座標）。
    /// 同じフレーム内の検出と、時系列で前後フレームの検出を比較して「同じ顔か」を
    /// 判定するときの IoU 計算用。
    public var boundingBox: CGRect {
        guard !points.isEmpty else { return .zero }
        var minX: Float = .infinity, minY: Float = .infinity
        var maxX: Float = -.infinity, maxY: Float = -.infinity
        for p in points {
            if p.x < minX { minX = p.x }
            if p.y < minY { minY = p.y }
            if p.x > maxX { maxX = p.x }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(
            x: CGFloat(minX), y: CGFloat(minY),
            width: CGFloat(maxX - minX), height: CGFloat(maxY - minY)
        )
    }

    /// 他の顔リストの中に、自分と bbox IoU が `iouThreshold` を超えて重なる顔があるか。
    /// 時系列補間で「before の顔が after にも続いているか（連続している顔か）」を判定する。
    /// 顔がフレームアウト→インした場合、before と after で位置が大きく変わるので false になり、
    /// 補間が抑制されて「アウト位置に固定」される事故を防ぐ。
    public func hasCounterpart(in others: [FaceLandmarkSet], iouThreshold: CGFloat = 0.3) -> Bool {
        let mine = self.boundingBox
        for o in others {
            let inter = mine.intersection(o.boundingBox)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let interArea = inter.width * inter.height
            let unionArea = mine.width * mine.height + o.boundingBox.width * o.boundingBox.height - interArea
            if unionArea > 0, interArea / unionArea > iouThreshold { return true }
        }
        return false
    }

    /// 正規化ランドマーク座標を `rect` (0-1正規化) のサブ領域から全体画像座標へ逆マッピングする。
    /// 矩形クロップで検出したランドマークを元の画像座標系に戻すときに使う。
    public func remapped(into rect: CGRect) -> FaceLandmarkSet {
        let remappedPoints = points.map { lm in
            FaceLandmark(
                x: Float(rect.origin.x) + lm.x * Float(rect.width),
                y: Float(rect.origin.y) + lm.y * Float(rect.height),
                z: lm.z
            )
        }
        return FaceLandmarkSet(points: remappedPoints, confidence: confidence)
    }
}

/// Named face regions, each backed by the MediaPipe canonical landmark indices
/// that trace its outline. The orderings below form closed loops suitable for
/// building a fill `CGPath`.
public enum FaceRegion: CaseIterable, Sendable {
    case faceOval
    case leftEye
    case rightEye
    case lips

    /// The mask intensity associated with the region. The Metal kernel reads
    /// this value to choose a per-region block size, so eyes / mouth can be
    /// pixelated more finely than the broad face area.
    public var maskValue: Float {
        switch self {
        case .faceOval: return 0.4
        case .leftEye, .rightEye: return 0.7
        case .lips: return 1.0
        }
    }

    /// Ordered landmark indices tracing the region outline as a closed loop.
    public var indices: [Int] {
        switch self {
        case .faceOval: return Self.faceOvalIndices
        case .leftEye: return Self.leftEyeIndices
        case .rightEye: return Self.rightEyeIndices
        case .lips: return Self.lipsIndices
        }
    }

    // MARK: - MediaPipe canonical contours

    /// FACEMESH_FACE_OVAL, reordered into a continuous loop.
    static let faceOvalIndices: [Int] = [
        10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288,
        397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
        172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109
    ]

    /// FACEMESH_LEFT_EYE outer ring.
    static let leftEyeIndices: [Int] = [
        263, 249, 390, 373, 374, 380, 381, 382, 362,
        398, 384, 385, 386, 387, 388, 466
    ]

    /// FACEMESH_RIGHT_EYE outer ring.
    static let rightEyeIndices: [Int] = [
        33, 7, 163, 144, 145, 153, 154, 155, 133,
        173, 157, 158, 159, 160, 161, 246
    ]

    /// FACEMESH_LIPS outer ring.
    static let lipsIndices: [Int] = [
        61, 146, 91, 181, 84, 17, 314, 405, 321, 375,
        291, 409, 270, 269, 267, 0, 37, 39, 40, 185
    ]
}
