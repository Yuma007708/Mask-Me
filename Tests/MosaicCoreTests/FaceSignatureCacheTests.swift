import CoreGraphics
import XCTest
@testable import MosaicCore

/// 署名キャッシュ。顔と署名を別立てで持つ以上、**対応の取り違え**が最悪の欠陥になる
/// （別人の署名で判定し、隠すべき人を素のまま映す）。ここではその潰し方を固定する。
final class FaceSignatureCacheTests: XCTestCase {

    private func makeSignature(axis: Int) -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis] = 1
        return FaceSignature(rawValues: values)!
    }

    /// 重心が (cx, cy) にある顔。
    private func face(cx: Float, cy: Float) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [FaceLandmark(x: cx, y: cy)], confidence: 1)
    }

    private let sourceID = UUID()

    func test_storesAndReturnsSignaturesByPosition() {
        let cache = FaceSignatureCache()
        let faces = [face(cx: 0.2, cy: 0.5), face(cx: 0.8, cy: 0.5)]
        let signatures = [makeSignature(axis: 0), makeSignature(axis: 1)]
        cache.store(signatures, for: faces, sourceID: sourceID, time: 1.0)

        let read = cache.signatures(for: faces, sourceID: sourceID, time: 1.0)
        XCTAssertEqual(read, signatures)
    }

    /// **並び順が変わっても、位置で正しい署名に当たること。**
    /// 添字で結び付けていた頃はここで別人の署名を掴んでいた。
    func test_signaturesFollowPositionNotOrder() {
        let cache = FaceSignatureCache()
        let left = face(cx: 0.2, cy: 0.5), right = face(cx: 0.8, cy: 0.5)
        let leftSignature = makeSignature(axis: 0), rightSignature = makeSignature(axis: 1)
        cache.store([leftSignature, rightSignature], for: [left, right],
                    sourceID: sourceID, time: 1.0)

        // 検出器の出力順が入れ替わったフレーム。
        let read = cache.signatures(for: [right, left], sourceID: sourceID, time: 1.0)
        XCTAssertEqual(read, [rightSignature, leftSignature],
                       "並び順に引きずられて別人の署名を返している")
    }

    /// 顔が動いて対応が付かないときは署名なし（＝位置追跡へ落ちる安全側）。
    func test_farFaceGetsNoSignature() {
        let cache = FaceSignatureCache()
        cache.store([makeSignature(axis: 0)], for: [face(cx: 0.2, cy: 0.5)],
                    sourceID: sourceID, time: 1.0)

        let read = cache.signatures(for: [face(cx: 0.9, cy: 0.5)],
                                    sourceID: sourceID, time: 1.0)
        XCTAssertNil(read[0], "離れた位置の顔に署名を割り当てている（別人の署名で判定する）")
    }

    /// 1 つの署名を 2 つの顔で使い回さないこと（2 人が同じ人だと判定される）。
    func test_oneSampleIsAssignedToOnlyOneFace() {
        let cache = FaceSignatureCache()
        cache.store([makeSignature(axis: 0)], for: [face(cx: 0.5, cy: 0.5)],
                    sourceID: sourceID, time: 1.0)

        // 2 つの顔がどちらも許容距離内に居る状況。
        let read = cache.signatures(for: [face(cx: 0.49, cy: 0.5), face(cx: 0.52, cy: 0.5)],
                                    sourceID: sourceID, time: 1.0)
        XCTAssertEqual(read.compactMap { $0 }.count, 1, "1 つの署名を 2 人に配っている")
        XCTAssertNotNil(read[0], "より近い顔ではなく遠い顔へ割り当てている")
    }

    /// 書き込み時に件数が合わない対応は**記録しない**。
    func test_mismatchedStoreIsRejected() {
        let cache = FaceSignatureCache()
        let faces = [face(cx: 0.2, cy: 0.5), face(cx: 0.8, cy: 0.5)]
        cache.store([makeSignature(axis: 0)], for: faces, sourceID: sourceID, time: 1.0)
        XCTAssertTrue(cache.isEmpty, "顔 2 件に署名 1 件という壊れた対応を記録している")
    }

    /// 署名が 1 本も作れなかったフレームは記録しない（引くものが無い）。
    func test_allNilStoreIsNotRecorded() {
        let cache = FaceSignatureCache()
        cache.store([nil], for: [face(cx: 0.2, cy: 0.5)], sourceID: sourceID, time: 1.0)
        XCTAssertTrue(cache.isEmpty)
    }

    /// 素材が違えば混ざらない。同じ時刻でも別素材の署名を引いてはいけない。
    func test_signaturesAreScopedToSource() {
        let cache = FaceSignatureCache()
        let faces = [face(cx: 0.5, cy: 0.5)]
        cache.store([makeSignature(axis: 0)], for: faces, sourceID: sourceID, time: 1.0)

        let read = cache.signatures(for: faces, sourceID: UUID(), time: 1.0)
        XCTAssertNil(read[0], "別素材の署名を引いている")
    }

    /// 署名は間引いて作るので、顔と同じバケットに無いのが普通。窓の中の最寄りを引くこと。
    func test_nearbyBucketIsUsedWithinWindow() {
        let cache = FaceSignatureCache()
        let faces = [face(cx: 0.5, cy: 0.5)]
        let signature = makeSignature(axis: 0)
        cache.store([signature], for: faces, sourceID: sourceID, time: 1.0)

        XCTAssertEqual(cache.signatures(for: faces, sourceID: sourceID, time: 1.2)[0], signature,
                       "窓の中の署名を引けていない（署名が滅多に効かなくなる）")
        XCTAssertNil(cache.signatures(for: faces, sourceID: sourceID, time: 5.0)[0],
                     "窓の外の古い署名を引いている")
    }

    func test_removeAllForSourceKeepsOtherSources() {
        let cache = FaceSignatureCache()
        let faces = [face(cx: 0.5, cy: 0.5)]
        let other = UUID()
        cache.store([makeSignature(axis: 0)], for: faces, sourceID: sourceID, time: 1.0)
        cache.store([makeSignature(axis: 1)], for: faces, sourceID: other, time: 1.0)

        cache.removeAll(sourceID: sourceID)
        XCTAssertNil(cache.signatures(for: faces, sourceID: sourceID, time: 1.0)[0])
        XCTAssertNotNil(cache.signatures(for: faces, sourceID: other, time: 1.0)[0],
                        "消していない素材の署名まで消えている")
    }

    /// 時刻はバケットへ丸められる。検出キャッシュと同じ丸め方でないと、
    /// 顔は引けるのに署名だけ引けない（あるいはその逆）という食い違いが起きる。
    func test_bucketingMatchesDetectionCache() {
        let cache = FaceSignatureCache(bucketFPS: 15)
        let faces = [face(cx: 0.5, cy: 0.5)]
        cache.store([makeSignature(axis: 0)], for: faces, sourceID: sourceID, time: 1.00)

        let sameBucket = DetectionCacheKey(sourceID: sourceID, time: 1.02, bucketFPS: 15)
        let storedBucket = DetectionCacheKey(sourceID: sourceID, time: 1.00, bucketFPS: 15)
        XCTAssertEqual(sameBucket, storedBucket, "前提: 1.00 と 1.02 は同じバケット")
        XCTAssertNotNil(cache.signatures(for: faces, sourceID: sourceID, time: 1.02,
                                         window: 0)[0],
                        "検出キャッシュと丸め方が食い違っている")
    }
}
