import Foundation

/// 検出結果を素材基準のキーで保持する。
///
/// 「エントリが無い（未検出）」と「エントリはあるが空（検出したが顔なし）」を
/// 区別する。この区別が壊れると、誤検出を空で上書きして消せなくなる。
public final class DetectionCacheStore {
    private var storage: [DetectionCacheKey: [FaceLandmarkSet]] = [:]
    private let bucketFPS: Double

    /// `projectedFaces(sourceID:)` の結果メモ。storage を変更したら必ず捨てる。
    ///
    /// 射影は `DetectionBridge` 用に毎フレーム呼ばれるため、エントリ数に比例した
    /// 辞書再構築が 60fps で走っていた（5分動画で約 0.5ms/フレーム）。
    /// 無効化漏れは「古い検出結果が描かれ続ける」回帰になるので、storage への
    /// 書き込みは必ず `mutateStorage(_:)` を通し、そこで一括破棄する。
    private var projectionCache: [UUID: [Double: [FaceLandmarkSet]]] = [:]

    public init(bucketFPS: Double = 15.0) {
        self.bucketFPS = bucketFPS
    }

    /// storage を変更する唯一の入口。ここ以外で `storage` に代入しないこと。
    private func mutateStorage(_ body: (inout [DetectionCacheKey: [FaceLandmarkSet]]) -> Void) {
        body(&storage)
        projectionCache.removeAll()
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var allEntries: [DetectionCacheKey: [FaceLandmarkSet]] { storage }

    private func key(_ sourceID: UUID, _ time: Double) -> DetectionCacheKey {
        DetectionCacheKey(sourceID: sourceID, time: time, bucketFPS: bucketFPS)
    }

    public func store(_ faces: [FaceLandmarkSet], sourceID: UUID, time: Double) {
        let k = key(sourceID, time)
        mutateStorage { $0[k] = faces }
    }

    /// 指定素材のエントリを `[素材内時刻: 顔]` へ射影する。
    ///
    /// `DetectionBridge` / `VideoMosaicExporter` が受け取る従来形式。
    /// 結果はメモされ、storage が変わるまで再構築しない。
    public func projectedFaces(sourceID: UUID) -> [Double: [FaceLandmarkSet]] {
        if let cached = projectionCache[sourceID] { return cached }
        var scoped: [Double: [FaceLandmarkSet]] = [:]
        for (k, faces) in storage where k.sourceID == sourceID {
            scoped[k.bucket] = faces
        }
        projectionCache[sourceID] = scoped
        return scoped
    }

    /// 完全一致（同一バケット）の検出結果。エントリが無ければ nil。
    public func faces(sourceID: UUID, time: Double) -> [FaceLandmarkSet]? {
        storage[key(sourceID, time)]
    }

    /// そのバケットが検出済みかどうか（空結果を含む）。
    public func hasEntry(sourceID: UUID, time: Double) -> Bool {
        storage[key(sourceID, time)] != nil
    }

    /// `window` 秒以内で最も近い非空エントリ。無ければ空配列。
    public func nearestFaces(sourceID: UUID, time: Double, window: Double) -> [FaceLandmarkSet] {
        var best: [FaceLandmarkSet] = []
        var bestDistance = Double.greatestFiniteMagnitude
        for (k, faces) in storage where k.sourceID == sourceID && !faces.isEmpty {
            let d = abs(k.bucket - time)
            if d <= window && d < bestDistance {
                bestDistance = d
                best = faces
            }
        }
        return best
    }

    public func removeAll() {
        mutateStorage { $0.removeAll() }
    }

    public func removeAll(sourceID: UUID) {
        mutateStorage { $0 = $0.filter { $0.key.sourceID != sourceID } }
    }
}
