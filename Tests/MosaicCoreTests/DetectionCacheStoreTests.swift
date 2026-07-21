import XCTest
@testable import MosaicCore

final class DetectionCacheStoreTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private func face(cx: Float) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [
            FaceLandmark(x: cx - 0.05, y: 0.4),
            FaceLandmark(x: cx + 0.05, y: 0.4),
            FaceLandmark(x: cx - 0.05, y: 0.6),
            FaceLandmark(x: cx + 0.05, y: 0.6)
        ], confidence: 1)
    }

    func test_storeAndRetrieve() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.faces(sourceID: sourceA, time: 1.0)?.count, 1)
    }

    /// 同一バケットに丸められる時刻は同じエントリを指すこと。
    /// 浮動小数の累積誤差でキーが分裂した回帰があるため明示的に検証する。
    func test_nearbyTimesShareBucket() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        // 1/15 秒の 1/100 だけずれた時刻は同じバケット
        XCTAssertNotNil(store.faces(sourceID: sourceA, time: 1.0 + (1.0 / 15.0) * 0.01))
        XCTAssertEqual(store.count, 1)
    }

    /// 素材が違えば別エントリになること。
    func test_differentSourcesAreIsolated() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 1.0)

        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.faces(sourceID: UUID(), time: 1.0))
    }

    /// 「検出したが顔がなかった」を空配列で記録でき、未検出と区別できること。
    /// この区別が壊れると、誤検出を空で上書きして消せなくなる。
    func test_emptyResultIsDistinctFromMissing() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([], sourceID: sourceA, time: 1.0)

        XCTAssertEqual(store.faces(sourceID: sourceA, time: 1.0)?.isEmpty, true)
        XCTAssertTrue(store.hasEntry(sourceID: sourceA, time: 1.0))
        XCTAssertFalse(store.hasEntry(sourceID: sourceA, time: 5.0))
        XCTAssertNil(store.faces(sourceID: sourceA, time: 5.0))
    }

    /// 近傍検索は window 秒以内の最も近い非空エントリを返すこと。
    func test_nearestFacesWithinWindow() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)

        XCTAssertEqual(store.nearestFaces(sourceID: sourceA, time: 1.2, window: 0.5).count, 1)
        XCTAssertTrue(store.nearestFaces(sourceID: sourceA, time: 3.0, window: 0.5).isEmpty)
    }

    /// 近傍検索は他の素材のエントリを拾わないこと。
    func test_nearestFacesDoesNotCrossSources() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertTrue(store.nearestFaces(sourceID: sourceB, time: 1.0, window: 0.5).isEmpty)
    }

    /// 素材単位で破棄できること（素材を差し替えたときに使う）。
    func test_removeBySource() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 1.0)

        store.removeAll(sourceID: sourceA)

        XCTAssertNil(store.faces(sourceID: sourceA, time: 1.0))
        XCTAssertNotNil(store.faces(sourceID: sourceB, time: 1.0))
    }

    /// 本設計の核心の回帰テスト。
    /// クリップを削除して後続クリップの合成時刻がずれても、
    /// 素材基準のキャッシュは引き続き同じ検出結果を返すこと。
    func test_detectionSurvivesClipRemoval() {
        let store = DetectionCacheStore(bucketFPS: 15)
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)

        // 素材Bの11秒地点に顔を検出済み
        store.store([face(cx: 0.7)], sourceID: sourceB, time: 11.0)

        // 削除前: 合成時刻 4.0 が素材Bの 11.0 に対応
        let before = TimelineMapping(clips: [clipA, clipB])
        let locBefore = before.sourceLocation(at: 4.0)
        XCTAssertEqual(locBefore?.sourceID, sourceB)
        XCTAssertEqual(store.faces(sourceID: locBefore!.sourceID, time: locBefore!.time)?.count, 1)

        // クリップAを削除 → 同じ映像が合成時刻 1.0 に移動
        let after = TimelineMapping(clips: [clipB])
        let locAfter = after.sourceLocation(at: 1.0)
        XCTAssertEqual(locAfter?.sourceID, sourceB)
        XCTAssertEqual(locAfter?.time ?? 0, 11.0, accuracy: 1e-9)

        // 検出結果は失われていない
        XCTAssertEqual(store.faces(sourceID: locAfter!.sourceID, time: locAfter!.time)?.count, 1)
    }

    // MARK: - 射影のメモ化

    /// 射影を取った後に store すると、次の射影に反映されること。
    /// メモの無効化漏れは「古い検出結果が描かれ続ける」最悪の回帰になる。
    func test_projectionReflectsLaterStore() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceA).count, 1)

        store.store([face(cx: 0.3)], sourceID: sourceA, time: 2.0)
        let after = store.projectedFaces(sourceID: sourceA)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[2.0]?.count, 1)
    }

    /// 既存バケットの上書き（プリスキャンによるライブ結果の上書き）も反映されること。
    func test_projectionReflectsOverwrite() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceA)[1.0]?.count, 1)

        store.store([], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceA)[1.0]?.isEmpty, true)
    }

    /// 射影を取った後に removeAll(sourceID:) すると、次の射影が空になること。
    func test_projectionInvalidatedByRemoveBySource() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 1.0)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceA).count, 1)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceB).count, 1)

        store.removeAll(sourceID: sourceA)

        XCTAssertTrue(store.projectedFaces(sourceID: sourceA).isEmpty)
        // 巻き添えで消えていないこと
        XCTAssertEqual(store.projectedFaces(sourceID: sourceB).count, 1)
    }

    /// 射影を取った後に removeAll() すると、次の射影が空になること。
    func test_projectionInvalidatedByRemoveAll() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.projectedFaces(sourceID: sourceA).count, 1)

        store.removeAll()

        XCTAssertTrue(store.projectedFaces(sourceID: sourceA).isEmpty)
    }

    /// 射影は指定した sourceID のエントリだけを含むこと。
    func test_projectionIsScopedToSource() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 2.0)

        let projected = store.projectedFaces(sourceID: sourceA)
        XCTAssertEqual(projected.count, 1)
        XCTAssertNotNil(projected[1.0])
        XCTAssertNil(projected[2.0])
        XCTAssertTrue(store.projectedFaces(sourceID: UUID()).isEmpty)
    }

    /// 同じ状態で2回射影を取ったら等しい結果になること（メモ経路と再構築経路の一致）。
    func test_projectionIsStableAcrossCalls() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([], sourceID: sourceA, time: 2.0)

        let first = store.projectedFaces(sourceID: sourceA)
        let second = store.projectedFaces(sourceID: sourceA)

        XCTAssertEqual(first.keys.sorted(), second.keys.sorted())
        for (t, faces) in first {
            XCTAssertEqual(faces.count, second[t]?.count)
        }
    }
}
