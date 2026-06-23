import XCTest
import Foundation
import CoreGraphics
@testable import MosaicCore

final class FaceMaskBuilderTests: XCTestCase {
    private let imageSize = CGSize(width: 256, height: 256)

    /// 指定インデックス群をある中心・半径の円上に配置する。
    private static func placeCircle(
        _ indices: [Int],
        center: (Float, Float),
        radius: Float,
        into points: inout [FaceLandmark]
    ) {
        let count = Float(indices.count)
        for (i, index) in indices.enumerated() {
            let theta = Float(i) / count * 2 * .pi
            points[index] = FaceLandmark(
                x: center.0 + radius * cos(theta),
                y: center.1 + radius * sin(theta)
            )
        }
    }

    /// Builds a synthetic full mesh with large radii — existing tests depend on this scale.
    private func makeLandmarks(confidence: Float = 0.9) -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        Self.placeCircle(FaceRegion.faceOvalIndices, center: (0.5, 0.5), radius: 0.4, into: &points)
        Self.placeCircle(FaceRegion.leftEyeIndices, center: (0.65, 0.4), radius: 0.05, into: &points)
        Self.placeCircle(FaceRegion.rightEyeIndices, center: (0.35, 0.4), radius: 0.05, into: &points)
        Self.placeCircle(FaceRegion.lipsIndices, center: (0.5, 0.7), radius: 0.08, into: &points)
        return FaceLandmarkSet(points: points, confidence: confidence)
    }

    /// Builds a smaller face mesh centered at `(cx, cy)` — suitable for placing
    /// two non-overlapping faces side-by-side in multi-face tests.
    private func makeSmallLandmarks(
        center: (Float, Float),
        confidence: Float = 0.9
    ) -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: center.0, y: center.1),
            count: FaceLandmarkSet.fullMeshCount
        )
        let (cx, cy) = center
        Self.placeCircle(FaceRegion.faceOvalIndices, center: (cx, cy), radius: 0.1, into: &points)
        Self.placeCircle(FaceRegion.leftEyeIndices, center: (cx + 0.03, cy - 0.03), radius: 0.02, into: &points)
        Self.placeCircle(FaceRegion.rightEyeIndices, center: (cx - 0.03, cy - 0.03), radius: 0.02, into: &points)
        Self.placeCircle(FaceRegion.lipsIndices, center: (cx, cy + 0.04), radius: 0.02, into: &points)
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

    func testDisabledRegionsAreExcluded() {
        let builder = FaceMaskBuilder(dilation: 0, enabledRegions: [.faceOval])
        let paths = builder.regionPaths(for: makeLandmarks(), in: imageSize)
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first?.value, FaceRegion.faceOval.maskValue)
    }

    func testNoEnabledRegionsYieldsEmptyMask() {
        let builder = FaceMaskBuilder(dilation: 0, enabledRegions: [])
        XCTAssertTrue(builder.regionPaths(for: makeLandmarks(), in: imageSize).isEmpty)
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

    // MARK: - Multi-face renderMask

    func testMultiFaceRenderMaskMasksPixelsFromBothFaces() throws {
        // 2 small faces on opposite sides; use 256×256 canvas.
        let leftFace  = makeSmallLandmarks(center: (0.2, 0.5))
        let rightFace = makeSmallLandmarks(center: (0.8, 0.5))
        let builder = FaceMaskBuilder(dilation: 0)
        let rendered = try XCTUnwrap(
            builder.renderMask(for: [leftFace, rightFace], width: 256, height: 256)
        )
        XCTAssertEqual(rendered.bytes.count, 256 * 256)

        let row = 128  // y = 50% (both faces are on this row)
        let leftCol  = Int(0.2 * 256)   // x ≈ 51
        let rightCol = Int(0.8 * 256)   // x ≈ 204

        XCTAssertGreaterThan(
            rendered.bytes[row * rendered.bytesPerRow + leftCol], 0,
            "左顔の中心ピクセルはマスクされるべき"
        )
        XCTAssertGreaterThan(
            rendered.bytes[row * rendered.bytesPerRow + rightCol], 0,
            "右顔の中心ピクセルはマスクされるべき"
        )
    }

    func testMultiFaceRenderMaskWithZeroFacesProducesEmptyMask() throws {
        let builder = FaceMaskBuilder(dilation: 0)
        let rendered = try XCTUnwrap(
            builder.renderMask(for: [], additionalPaths: [], width: 64, height: 64)
        )
        XCTAssertTrue(rendered.bytes.allSatisfy { $0 == 0 }, "顔なし・追加パスなし → 全ピクセル 0")
    }

    // MARK: - rectPath(from:in:)

    func testRectPathBoundingBoxMatchesPixelCoords() {
        let size = CGSize(width: 100, height: 200)
        let norm = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let bbox = FaceMaskBuilder.rectPath(from: norm, in: size).boundingBox

        XCTAssertEqual(bbox.origin.x, 10, accuracy: 0.001)   // 0.1 × 100
        XCTAssertEqual(bbox.origin.y, 40, accuracy: 0.001)   // 0.2 × 200
        XCTAssertEqual(bbox.width,    50, accuracy: 0.001)   // 0.5 × 100
        XCTAssertEqual(bbox.height,   60, accuracy: 0.001)   // 0.3 × 200
    }

    func testRectPathFullImageCoversEntireCanvas() {
        let size = CGSize(width: 128, height: 128)
        let bbox = FaceMaskBuilder.rectPath(
            from: CGRect(x: 0, y: 0, width: 1, height: 1), in: size
        ).boundingBox
        XCTAssertEqual(bbox, CGRect(origin: .zero, size: size))
    }

    // MARK: - additionalPaths in multi-face renderMask

    func testAdditionalRectPathIsAppliedToMask() throws {
        let builder = FaceMaskBuilder(dilation: 0)
        // Rect covering the center half of the 64×64 image in normalized coords.
        // In CG pixel coords: CGRect(x:16, y:16, w:32, h:32).
        // CGContext origin is bottom-left, so this rect maps to byte rows 16..47
        // (center rows). The image center byte-position (row=32, col=32) is inside.
        let rectPath = FaceMaskBuilder.rectPath(
            from: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: CGSize(width: 64, height: 64)
        )
        let additionalPath = FaceMaskBuilder.RegionPath(path: rectPath, value: 1.0)
        let rendered = try XCTUnwrap(
            builder.renderMask(for: [], additionalPaths: [additionalPath], width: 64, height: 64)
        )
        // Image center (byte row 32, col 32) is inside the rect.
        XCTAssertGreaterThan(rendered.bytes[32 * rendered.bytesPerRow + 32], 0, "追加パス内のピクセルはマスクされるべき")
        // Top-left corner (byte row 0, col 0) = CG y=63, x=0 — outside the rect.
        XCTAssertEqual(rendered.bytes[0], 0, "追加パス外のコーナーは 0 のまま")
    }
}
