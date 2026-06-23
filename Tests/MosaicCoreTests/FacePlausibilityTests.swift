import XCTest
import CoreGraphics
@testable import MosaicCore

final class FacePlausibilityTests: XCTestCase {
    /// Builds a full mesh with the key regions placed like a real, upright face.
    private func plausibleFace() -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        func placeCircle(_ indices: [Int], center: (Float, Float), radius: Float) {
            let count = Float(indices.count)
            for (offset, index) in indices.enumerated() {
                let theta = Float(offset) / count * 2 * .pi
                points[index] = FaceLandmark(
                    x: center.0 + radius * cos(theta),
                    y: center.1 + radius * sin(theta)
                )
            }
        }
        // Face oval ~0.3 wide / 0.42 tall, eyes upper, mouth lower.
        placeCircle(FaceRegion.faceOvalIndices, center: (0.5, 0.5), radius: 0.21)
        points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.42, y: 0.42)
        points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.58, y: 0.42)
        placeCircle(FaceRegion.lipsIndices, center: (0.5, 0.64), radius: 0.05)
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    func testPlausibleFacePasses() {
        XCTAssertTrue(plausibleFace().isPlausibleFace)
    }

    func testCollapsedLandmarksRejected() {
        // All points at one spot → zero-size box → implausible.
        let collapsed = FaceLandmarkSet(
            points: [FaceLandmark](
                repeating: FaceLandmark(x: 0.5, y: 0.5),
                count: FaceLandmarkSet.fullMeshCount
            ),
            confidence: 1
        )
        XCTAssertFalse(collapsed.isPlausibleFace)
    }

    func testPartialMeshRejected() {
        let sparse = FaceLandmarkSet(points: [FaceLandmark(x: 0.5, y: 0.5)], confidence: 1)
        XCTAssertFalse(sparse.isPlausibleFace)
    }

    func testEyesBelowMouthRejected() {
        var points = plausibleFace().points
        // Move mouth above the eyes → invalid vertical ordering.
        for index in FaceRegion.lipsIndices {
            points[index] = FaceLandmark(x: points[index].x, y: 0.20)
        }
        XCTAssertFalse(FaceLandmarkSet(points: points, confidence: 1).isPlausibleFace)
    }

    func testExtremeAspectRejected() {
        // A tall thin "body"-like box: width tiny vs height.
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        for (offset, index) in FaceRegion.faceOvalIndices.enumerated() {
            let t = Float(offset) / Float(FaceRegion.faceOvalIndices.count)
            points[index] = FaceLandmark(x: 0.49 + 0.02 * cos(t * 2 * .pi),
                                         y: 0.2 + 0.6 * t)
        }
        points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.49, y: 0.3)
        points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.51, y: 0.3)
        for index in FaceRegion.lipsIndices {
            points[index] = FaceLandmark(x: 0.5, y: 0.7)
        }
        XCTAssertFalse(FaceLandmarkSet(points: points, confidence: 1).isPlausibleFace)
    }
}
