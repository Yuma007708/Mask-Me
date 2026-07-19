import Foundation

/// 検出結果を素材基準のキーで保持する。
///
/// 「エントリが無い（未検出）」と「エントリはあるが空（検出したが顔なし）」を
/// 区別する。この区別が壊れると、誤検出を空で上書きして消せなくなる。
public final class DetectionCacheStore {
    private var storage: [DetectionCacheKey: [FaceLandmarkSet]] = [:]
    private let bucketFPS: Double

    public init(bucketFPS: Double = 15.0) {
        self.bucketFPS = bucketFPS
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var allEntries: [DetectionCacheKey: [FaceLandmarkSet]] { storage }

    private func key(_ sourceID: UUID, _ time: Double) -> DetectionCacheKey {
        DetectionCacheKey(sourceID: sourceID, time: time, bucketFPS: bucketFPS)
    }

    public func store(_ faces: [FaceLandmarkSet], sourceID: UUID, time: Double) {
        storage[key(sourceID, time)] = faces
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
        storage.removeAll()
    }

    public func removeAll(sourceID: UUID) {
        storage = storage.filter { $0.key.sourceID != sourceID }
    }
}
