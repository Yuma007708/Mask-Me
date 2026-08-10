import CoreGraphics
import XCTest
@testable import MosaicCore

/// `FaceCentroidMatching` の契約。
///
/// この判定は**描画の絞り込みとプレビューのタップ選択が共有する**ので、
/// ここが崩れると「枠が出ているのにタップしても選べない顔」が生まれる。
final class FaceCentroidMatchingTests: XCTestCase {
    /// 重心が `center` に来る 4 点の顔。
    private func face(at center: CGPoint) -> FaceLandmarkSet {
        let d: Float = 0.01
        let cx = Float(center.x), cy = Float(center.y)
        let points = [
            FaceLandmark(x: cx - d, y: cy - d, z: 0),
            FaceLandmark(x: cx + d, y: cy - d, z: 0),
            FaceLandmark(x: cx - d, y: cy + d, z: 0),
            FaceLandmark(x: cx + d, y: cy + d, z: 0)
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    // MARK: - 許容の境界

    func test_nearestIndex_returnsNilWhenAllCandidatesAreOutsideTolerance() {
        let centroids = [CGPoint(x: 0.9, y: 0.9)]
        XCTAssertNil(FaceCentroidMatching.nearestIndex(to: CGPoint(x: 0.1, y: 0.1),
                                                       in: centroids))
    }

    func test_nearestIndex_returnsNilForEmptyCandidates() {
        XCTAssertNil(FaceCentroidMatching.nearestIndex(to: CGPoint(x: 0.5, y: 0.5), in: []))
    }

    /// **許容ちょうどは「外」**（`distance < tolerance`）。
    /// 境界を含める実装に変えると、離れた顔まで同一人物として掴む。
    func test_nearestIndex_treatsExactToleranceAsOutside() {
        let tolerance: CGFloat = 0.5
        let point = CGPoint(x: 0, y: 0)
        XCTAssertNil(FaceCentroidMatching.nearestIndex(to: point,
                                                       in: [CGPoint(x: tolerance, y: 0)],
                                                       tolerance: tolerance))
        XCTAssertEqual(FaceCentroidMatching.nearestIndex(to: point,
                                                         in: [CGPoint(x: tolerance - 0.001, y: 0)],
                                                         tolerance: tolerance), 0)
    }

    // MARK: - 最近傍の選び方

    func test_nearestIndex_picksTheClosestNotTheFirstWithinTolerance() {
        let centroids = [CGPoint(x: 0.30, y: 0.5), CGPoint(x: 0.52, y: 0.5)]
        XCTAssertEqual(FaceCentroidMatching.nearestIndex(to: CGPoint(x: 0.5, y: 0.5),
                                                         in: centroids), 1,
                       "許容内で最初に見つかった方を返している（最も近い方でなければならない）")
    }

    /// **同点は添字の小さい方に固定する。** 揺れると、同じ顔をタップしたのに
    /// 毎回別の人物が選ばれる。
    func test_nearestIndex_isStableWhenDistancesTie() {
        let centroids = [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]
        let point = CGPoint(x: 0.5, y: 0.5)
        for _ in 0..<10 {
            XCTAssertEqual(FaceCentroidMatching.nearestIndex(to: point, in: centroids), 0)
        }
    }

    // MARK: - 顔からの入口

    func test_nearestIndex_forFace_usesItsCentroid() {
        let centroids = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)]
        XCTAssertEqual(FaceCentroidMatching.nearestIndex(for: face(at: CGPoint(x: 0.78, y: 0.79)),
                                                         in: centroids), 1)
    }

    /// 重心の計算が `SelectedFaceTracker` と一致していること。
    /// **別実装に分岐すると、描画とタップ選択で違う顔を指す。**
    func test_centroid_matchesSelectedFaceTracker() {
        let sample = face(at: CGPoint(x: 0.31, y: 0.62))
        XCTAssertEqual(FaceCentroidMatching.centroid(of: sample).x,
                       SelectedFaceTracker.centroid(of: sample).x, accuracy: 1e-6)
        XCTAssertEqual(FaceCentroidMatching.centroid(of: sample).y,
                       SelectedFaceTracker.centroid(of: sample).y, accuracy: 1e-6)
    }

    func test_centroid_ofEmptyFace_isImageCenter() {
        let empty = FaceLandmarkSet(points: [], confidence: 0)
        XCTAssertEqual(FaceCentroidMatching.centroid(of: empty), CGPoint(x: 0.5, y: 0.5))
    }

    /// 顔が許容の外にあるなら、顔からの入口でも nil。
    func test_nearestIndex_forFace_returnsNilWhenOutsideTolerance() {
        XCTAssertNil(FaceCentroidMatching.nearestIndex(for: face(at: CGPoint(x: 0.05, y: 0.05)),
                                                       in: [CGPoint(x: 0.95, y: 0.95)]))
    }
}
