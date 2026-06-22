import XCTest
import Foundation
import CoreGraphics
@testable import MosaicCore

final class FaceMaskBuilderTests: XCTestCase {
    private let imageSize = CGSize(width: 256, height: 256)

    /// Builds a synthetic full mesh, placing each region's outline on a small
    /// circle so the resulting polygons have real area.
    private func makeLandmarks(confidence: Float = 0.9) -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        func placeCircle(_ indices: [Int], center: (Float, Float), radius: Float) {
            let count = Float(indices.count)
            for (i, index) in indices.enumerated() {
                let theta = Float(i) / count * 2 * .pi
                points[index] = FaceLandmark(
                    x: center.0 + radius * cos(theta),
                    y: center.1 + radius * sin(theta)
                )
            }
        }
        placeCircle(FaceRegion.faceOvalIndices, center: (0.5, 0.5), radius: 0.4)
        placeCircle(FaceRegion.leftEyeIndices, center: (0.65, 0.4), radius: 0.05)
        placeCircle(FaceRegion.rightEyeIndices, center: (0.35, 0.4), radius: 0.05)
        placeCircle(FaceRegion.lipsIndices, center: (0.5, 0.7), radius: 0.08)
        return FaceLandmarkSet(points: points, confidence: confidence)
    }

    func testBuildsOnePathPerRegion() {
        let builder = FaceMaskBuilder(dilation: 0)
        let paths = builder.regionPaths(for: makeLandmarks(), in: imageSize)
        XCTAssertEqual(paths.count, 4)
        // Region intensities must be distinct & ordered face < eyes < lips.
        XCTAssertEqual(paths.first?.value, FaceRegion.faceOval.maskValue)
        XCTAssertEqual(paths.last?.value, FaceRegion.lips.maskValue)
    }

    func testBoundingBoxIsWithinImageAndNonEmpty() {
        let builder = FaceMaskBuilder(dilation: 0)
        let box = builder.boundingBox(for: makeLandmarks(), in: imageSize)
        XCTAssertFalse(box.isNull)
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
        // The face circle (r=0.4 about center) should fill most of the frame.
        XCTAssertGreaterThan(box.width, imageSize.width * 0.5)
    }

    func testDilationGrowsTheBoundingBox() {
        let landmarks = makeLandmarks()
        let tight = FaceMaskBuilder(dilation: 0)
            .boundingBox(for: landmarks, in: imageSize)
        let loose = FaceMaskBuilder(dilation: 0.05)
            .boundingBox(for: landmarks, in: imageSize)
        XCTAssertGreaterThan(loose.width, tight.width)
        XCTAssertGreaterThan(loose.height, tight.height)
    }

    func testRenderMaskProducesMaskedPixels() throws {
        let builder = FaceMaskBuilder(dilation: 0)
        let rendered = try XCTUnwrap(
            builder.renderMask(for: makeLandmarks(), width: 128, height: 128)
        )
        XCTAssertEqual(rendered.bytes.count, 128 * 128)
        // The center of the face must be inside the mask (non-zero).
        let centerIndex = 64 * rendered.bytesPerRow + 64
        XCTAssertGreaterThan(rendered.bytes[centerIndex], 0)
        // A corner must be outside the mask (zero → original pixel preserved).
        XCTAssertEqual(rendered.bytes[0], 0)
    }

    func testRenderMaskRejectsNonPositiveSize() {
        let builder = FaceMaskBuilder()
        XCTAssertNil(builder.renderMask(for: makeLandmarks(), width: 0, height: 10))
    }

    func testSmoothPathNeedsAtLeastThreePoints() {
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertNil(FaceMaskBuilder.smoothClosedPath(through: two, expandedBy: 0))
    }

    func testIncompleteMeshYieldsNoPaths() {
        // A partial detection (fewer than the indices reference) is tolerated.
        let sparse = FaceLandmarkSet(
            points: [FaceLandmark(x: 0.5, y: 0.5)],
            confidence: 0.9
        )
        let paths = FaceMaskBuilder().regionPaths(for: sparse, in: imageSize)
        XCTAssertTrue(paths.isEmpty)
    }
}
