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

    /// 正面顔（既定レンジ内）は plausibilityScore が 1.0（フル合格）で返る。
    func testPlausibilityScoreForFrontalFaceIsOne() {
        let face = plausibleFace()
        let score = face.plausibilityScore(
            minSpan: 0.02,
            eyeRatioRange: FaceLandmarkSet.Plausibility.eyeWidthRatioRange
        )
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    /// 目間比が下限をわずかに割った境界顔は、完全棄却ではなくソフトマージンで 0.3〜1.0 の中間値で残る。
    /// A-3 の連続 confidence 化と組合わせて、横顔・小顔のちらつきを EMA が均せるようにするため。
    func testPlausibilityScoreSoftMargin() {
        var points = plausibleFace().points
        // 目間比 ~0.32（下限 0.40 未満、softLower=0.24 超）を作る。
        // plausibleFace の oval width ≈ 0.42 なので eyeDistance ≈ 0.32*0.42 ≈ 0.134
        points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.433, y: 0.42)
        points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.567, y: 0.42)
        let set = FaceLandmarkSet(points: points, confidence: 1)
        let score = set.plausibilityScore(minSpan: 0.02, eyeRatioRange: 0.40...1.0)
        XCTAssertGreaterThan(score, 0.0)
        XCTAssertLessThan(score, 1.0)
    }

    /// 目間比が softLower を大きく下回るケースは完全棄却（体誤フィット等）。
    func testPlausibilityScoreHardRejectBelowSoftLower() {
        var points = plausibleFace().points
        // 目間比 ~0.05 = 極端に狭い（softLower=0.24 未満）
        points[FaceLandmarkSet.rightEyeOuterIndex] = FaceLandmark(x: 0.494, y: 0.42)
        points[FaceLandmarkSet.leftEyeOuterIndex] = FaceLandmark(x: 0.506, y: 0.42)
        let set = FaceLandmarkSet(points: points, confidence: 1)
        let score = set.plausibilityScore(minSpan: 0.02, eyeRatioRange: 0.40...1.0)
        XCTAssertEqual(score, 0.0, accuracy: 0.001)
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

    /// plausibleFace の oval を縦に stretchY 倍した顔（正規化 h/w = stretchY）を作る。
    private func stretchedFace(stretchY: Float) -> FaceLandmarkSet {
        var points = [FaceLandmark](
            repeating: FaceLandmark(x: 0.5, y: 0.5),
            count: FaceLandmarkSet.fullMeshCount
        )
        for (offset, index) in FaceRegion.faceOvalIndices.enumerated() {
            let theta = Float(offset) / Float(FaceRegion.faceOvalIndices.count) * 2 * .pi
            points[index] = FaceLandmark(
                x: 0.5 + 0.15 * cos(theta),
                y: 0.5 + 0.15 * stretchY * sin(theta)
            )
        }
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    func testPixelAspectRatioUndoesVideoAspect() {
        // 正規化で正方形の顔は、16:9 横長動画では縦横比が正しく 1.0 に換算される
        // （正規化のままだと h/w=1.78 に見えて全件 body 扱いになる旧バグの回帰確認）。
        let square = stretchedFace(stretchY: 1.0)
        let aspect = square.pixelAspectRatio(in: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(Double(aspect ?? 0), 1080.0 / 1920.0, accuracy: 0.01)
        XCTAssertFalse(square.isBodyLikeShape(in: CGSize(width: 1920, height: 1080)))
    }

    func testBodyLikeTallFitRejected() {
        // ピクセル換算 h/w = 1.6 の縦長フィット（首・胸への誤フィット形状）は body 判定。
        let tall = stretchedFace(stretchY: 1.6)
        let unit = CGSize(width: 1000, height: 1000)
        XCTAssertTrue(tall.isBodyLikeShape(in: unit))
        // 実顔の上限近く（1.3）は通る。
        XCTAssertFalse(stretchedFace(stretchY: 1.3).isBodyLikeShape(in: unit))
    }

    func testDegenerateOvalIsBodyLike() {
        let collapsed = FaceLandmarkSet(
            points: [FaceLandmark](repeating: FaceLandmark(x: 0.5, y: 0.5),
                                   count: FaceLandmarkSet.fullMeshCount),
            confidence: 1
        )
        XCTAssertTrue(collapsed.isBodyLikeShape(in: CGSize(width: 100, height: 100)))
    }

    /// `stretchedFace` を丸ごと dy だけ縦に平行移動する（boundingBox.midY を動かすため）。
    private func translated(_ face: FaceLandmarkSet, dy: Float) -> FaceLandmarkSet {
        FaceLandmarkSet(
            points: face.points.map { FaceLandmark(x: $0.x, y: $0.y + dy) },
            confidence: face.confidence
        )
    }

    /// 画面下半分（midY > suspectMidY）は、形状が正方形（実顔相当）でも疑わしいと判定する
    /// （従来の位置だけによる疑わしさ判定を維持）。
    func testSuspectBodyRegion_belowThreshold_isSuspectRegardlessOfShape() {
        let square = stretchedFace(stretchY: 1.0) // boundingBox.midY == 0.5
        XCTAssertTrue(square.isSuspectBodyRegion(in: CGSize(width: 1000, height: 1000), suspectMidY: 0.4))
    }

    /// 画面上半分（midY <= suspectMidY）かつ正方形形状（実顔相当）は疑わしくない。
    func testSuspectBodyRegion_aboveThreshold_squareShapeIsNotSuspect() {
        let square = translated(stretchedFace(stretchY: 1.0), dy: -0.3) // midY == 0.2
        XCTAssertFalse(square.isSuspectBodyRegion(in: CGSize(width: 1000, height: 1000), suspectMidY: 0.4))
    }

    /// 画面上半分でも、縦長の体誤フィット形状（h/w > maxPixelAspect）なら疑わしいと判定する。
    /// これが今回の追加ロジックの核心: 従来は位置のみで判定し、画面上部の体誤フィットを
    /// 検証対象から漏らしていた。
    func testSuspectBodyRegion_aboveThreshold_tallShapeIsSuspect() {
        let tall = translated(stretchedFace(stretchY: 1.6), dy: -0.3) // midY == 0.2, h/w == 1.6
        XCTAssertTrue(tall.isSuspectBodyRegion(in: CGSize(width: 1000, height: 1000), suspectMidY: 0.4))
    }
}
