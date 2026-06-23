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
}
