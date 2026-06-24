import XCTest
import CoreGraphics
@testable import MosaicCore

final class FaceLandmarksTests: XCTestCase {
    private let size = CGSize(width: 100, height: 100)

    private func fullMesh(_ mutate: (inout [FaceLandmark]) -> Void) -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        mutate(&points)
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    func testCentroidOfUniformPointsIsCenter() {
        let set = fullMesh { _ in }
        let centroid = set.centroid(in: size)
        XCTAssertEqual(centroid.x, 50, accuracy: 0.001)
        XCTAssertEqual(centroid.y, 50, accuracy: 0.001)
    }

    func testCentroidEmptyFallsBackToImageCenter() {
        let empty = FaceLandmarkSet(points: [], confidence: 0)
        let centroid = empty.centroid(in: size)
        XCTAssertEqual(centroid.x, 50, accuracy: 0.001)
        XCTAssertEqual(centroid.y, 50, accuracy: 0.001)
    }

    func testRollAngleZeroForLevelEyes() {
        let set = fullMesh { points in
            points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.3, y: 0.5)
            points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.7, y: 0.5)
        }
        XCTAssertEqual(set.rollAngle(in: size), 0, accuracy: 0.0001)
    }

    func testRollAnglePositiveWhenLeftEyeLower() {
        // Left (image-right) eye lower on screen → positive roll.
        let set = fullMesh { points in
            points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.3, y: 0.5)
            points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.7, y: 0.6)
        }
        // atan2((0.6-0.5)*100, (0.7-0.3)*100) = atan2(10, 40)
        XCTAssertEqual(set.rollAngle(in: size), atan2f(10, 40), accuracy: 0.0001)
    }

    func testRollAngleZeroForPartialMesh() {
        let sparse = FaceLandmarkSet(
            points: [FaceLandmark(x: 0.5, y: 0.5)],
            confidence: 0.9
        )
        XCTAssertEqual(sparse.rollAngle(in: size), 0)
    }

    // MARK: - remapped(into:)

    func testRemappedMapsIntoSubRect() {
        // (0.5, 0.5) in a crop at (0.2, 0.3, 0.4×0.3) → (0.4, 0.45) in full image
        let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)
        let set = fullMesh { $0[0] = FaceLandmark(x: 0.5, y: 0.5) }
        let remapped = set.remapped(into: rect)
        XCTAssertEqual(remapped.points[0].x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(remapped.points[0].y, 0.45, accuracy: 0.0001)
    }

    func testRemappedIntoFullRectIsIdentity() {
        let set = fullMesh { $0[0] = FaceLandmark(x: 0.3, y: 0.7) }
        let remapped = set.remapped(into: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(remapped.points[0].x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(remapped.points[0].y, 0.7, accuracy: 0.0001)
    }

    func testRemappedPreservesConfidenceAndDepth() {
        let set = FaceLandmarkSet(
            points: [FaceLandmark(x: 1.0, y: 1.0, z: 0.42)],
            confidence: 0.85
        )
        let remapped = set.remapped(into: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(remapped.confidence, 0.85, accuracy: 0.0001)
        XCTAssertEqual(remapped.points[0].z, 0.42, accuracy: 0.0001)
    }

    func testRemappedTopLeftCropOriginTranslates() {
        // A landmark at (0, 0) in a crop starting at (0.1, 0.2) → (0.1, 0.2)
        let set = FaceLandmarkSet(points: [FaceLandmark(x: 0, y: 0)], confidence: 1)
        let remapped = set.remapped(into: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertEqual(remapped.points[0].x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(remapped.points[0].y, 0.2, accuracy: 0.0001)
    }
}
