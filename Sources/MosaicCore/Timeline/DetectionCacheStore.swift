import Foundation

/// 検出結果を素材基準のキーで保持する。
///
/// 「エントリが無い（未検出）」と「エントリはあるが空（検出したが顔なし）」を
/// 区別する。この区別が壊れると、誤検出を空で上書きして消せなくなる。
public final class DetectionCacheStore {
    /// `didSet` でメモを破棄する。添字代入 (`storage[k] = v`) でも発火するため、
    /// このクラス内のどこから storage を書き換えても無効化が漏れない。
    /// 規律ではなく言語機能で保証している。
    private var storage: [DetectionCacheKey: [FaceLandmarkSet]] = [:] {
        didSet {
            projectionCache.removeAll()
            sortedEntriesCache.removeAll()
        }
    }
    private let bucketFPS: Double

    /// `projectedFaces(sourceID:)` の結果メモ。storage を変更したら必ず捨てる。
    ///
    /// 射影は `DetectionBridge` 用に毎フレーム呼ばれるため、エントリ数に比例した
    /// 辞書再構築が 60fps で走っていた（5分動画で約 0.5ms/フレーム）。
    /// 無効化漏れは「古い検出結果が描かれ続ける」回帰になるため、
    /// `storage` の `didSet` で破棄する。
    private var projectionCache: [UUID: [Double: [FaceLandmarkSet]]] = [:]

    /// `nearestFaces(sourceID:time:window:)` 用、bucket昇順ソート済み配列のメモ。
    ///
    /// 素朴な実装は毎回 storage 全件を走査していた（5分動画=4500エントリで
    /// 1回あたり約0.39ms、`CameraFlowAdvancer` 等から高頻度に呼ばれると無視でき
    /// ない負荷になる）。ソート済み配列を素材ごとにメモし、二分探索で `time` 近傍
    /// の候補まで一気に絞ることで O(log n + window内件数) に落とす。
    /// `projectionCache` と同様、`storage` の `didSet` で破棄して無効化漏れを防ぐ。
    private var sortedEntriesCache: [UUID: [(bucket: Double, faces: [FaceLandmarkSet])]] = [:]

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

    /// 指定素材のエントリを bucket 昇順でメモ化して返す。storage が変わるまで再利用する。
    private func sortedEntries(sourceID: UUID) -> [(bucket: Double, faces: [FaceLandmarkSet])] {
        if let cached = sortedEntriesCache[sourceID] { return cached }
        var scoped: [(bucket: Double, faces: [FaceLandmarkSet])] = []
        for (k, faces) in storage where k.sourceID == sourceID {
            scoped.append((bucket: k.bucket, faces: faces))
        }
        scoped.sort { $0.bucket < $1.bucket }
        sortedEntriesCache[sourceID] = scoped
        return scoped
    }

    /// `window` 秒以内で最も近い非空エントリ。無ければ空配列。
    ///
    /// bucket 昇順配列を二分探索で `time` の挿入位置まで絞り込み、そこから window
    /// 幅を超えるまで左右に広げるだけなので、window 内のエントリ数にしか比例しない。
    public func nearestFaces(sourceID: UUID, time: Double, window: Double) -> [FaceLandmarkSet] {
        let entries = sortedEntries(sourceID: sourceID)
        guard !entries.isEmpty else { return [] }

        // entries[insertionIndex].bucket >= time となる最小の添字（無ければ entries.count）。
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].bucket < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var best: [FaceLandmarkSet] = []
        var bestDistance = Double.greatestFiniteMagnitude
        var left = low - 1
        var right = low
        while left >= 0 || right < entries.count {
            if left >= 0 {
                let d = time - entries[left].bucket
                if d > window {
                    left = -1
                } else {
                    if !entries[left].faces.isEmpty && d < bestDistance {
                        bestDistance = d
                        best = entries[left].faces
                    }
                    left -= 1
                }
            }
            if right < entries.count {
                let d = entries[right].bucket - time
                if d > window {
                    right = entries.count
                } else {
                    if !entries[right].faces.isEmpty && d < bestDistance {
                        bestDistance = d
                        best = entries[right].faces
                    }
                    right += 1
                }
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
