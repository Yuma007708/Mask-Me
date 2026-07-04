import XCTest
@testable import MosaicCore

final class SimilarityTransformTests: XCTestCase {

    // MARK: - estimate

    func test_estimate_pureTranslation() throws {
        let from = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10),
                    CGPoint(x: 50, y: 60), CGPoint(x: 10, y: 60),
                    CGPoint(x: 30, y: 35), CGPoint(x: 20, y: 50)]
        let to = from.map { CGPoint(x: $0.x + 12, y: $0.y + 7) }
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.tx, 12, accuracy: 0.01)
        XCTAssertEqual(t.ty, 7, accuracy: 0.01)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(t.rotation, 0.0, accuracy: 0.001)
    }

    func test_estimate_scaleAndRotation() throws {
        // 原点中心に 1.2 倍 + 30度回転 + 平行移動(5, -3)
        let s: CGFloat = 1.2, r: CGFloat = .pi / 6
        let from = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0),
                    CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40),
                    CGPoint(x: 20, y: 10), CGPoint(x: 10, y: 30)]
        let to = from.map { p in
            CGPoint(x: s * (cos(r) * p.x - sin(r) * p.y) + 5,
                    y: s * (sin(r) * p.x + cos(r) * p.y) - 3)
        }
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.scale, 1.2, accuracy: 0.001)
        XCTAssertEqual(t.rotation, .pi / 6, accuracy: 0.001)
        XCTAssertEqual(t.tx, 5, accuracy: 0.01)
        XCTAssertEqual(t.ty, -3, accuracy: 0.01)
    }

    func test_estimate_rejectsTooFewPairs() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertNil(SimilarityTransform.estimate(from: pts, to: pts))
    }

    func test_estimate_robustToOutliers() throws {
        // 20点中2点だけ大きく外す → 外れ値除去後の再フィットで正解に収束
        var from: [CGPoint] = []
        for i in 0..<20 {
            from.append(CGPoint(x: CGFloat(i % 5) * 20, y: CGFloat(i / 5) * 20))
        }
        var to = from.map { CGPoint(x: $0.x + 10, y: $0.y + 4) }
        to[3] = CGPoint(x: 500, y: 500)
        to[11] = CGPoint(x: -200, y: 300)
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.tx, 10, accuracy: 0.5)
        XCTAssertEqual(t.ty, 4, accuracy: 0.5)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.01)
    }

    // MARK: - apply

    func test_apply_toLandmarkSet_translatesNormalizedPoints() {
        // 画像 100x200px、平行移動 (10px, 20px) → 正規化では (+0.1, +0.1)
        let set = FaceLandmarkSet(
            points: [FaceLandmark(x: 0.5, y: 0.5, z: 0.3)], confidence: 0.9)
        let t = SimilarityTransform(scale: 1, rotation: 0, tx: 10, ty: 20)
        let moved = t.apply(to: set, imageSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(moved.points[0].x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.points[0].y, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.points[0].z, 0.3)   // z は保持
        XCTAssertEqual(moved.confidence, 0.9)    // confidence は保持
    }

    func test_apply_toNormalizedRect_scalesAroundTransformedCenter() {
        // 2倍拡大 + 移動なし。中心(50,50)px の 20x20px 矩形 →
        // 中心(100,100)px の 40x40px 矩形（axis-aligned 近似）
        let t = SimilarityTransform(scale: 2, rotation: 0, tx: 0, ty: 0)
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let out = t.apply(toNormalizedRect: rect,
                          imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(out.midX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(out.midY, 1.0, accuracy: 0.0001)
        XCTAssertEqual(out.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(out.height, 0.4, accuracy: 0.0001)
    }
}
