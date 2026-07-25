import AVFoundation
import Foundation
import UIKit

/// 素材時刻の丸め幅（秒）。細かいズームでキャッシュが際限なく増えるのを防ぐ。
///
/// ファイルスコープに置いているのは、`@MainActor` の `TimelineThumbnailStore` の
/// static メンバをデコード側（`Task.detached` の中 = MainActor 外）から参照しないため。
private let timelineThumbnailBucketSeconds: Double = 0.5

/// 素材時刻 → キャッシュのバケット番号。
private func timelineThumbnailBucket(_ time: Double) -> Int {
    let seconds = max(0, time.isFinite ? time : 0)
    return Int((seconds / timelineThumbnailBucketSeconds).rounded(.down))
}

/// デコード 1 枚の結果（要求キーと、実際に返ってきたキーフレームの位置）。
private struct TimelineThumbnailProduct {
    let requestedKey: TimelineThumbnailStore.Key
    /// 実際に返ってきたコマの素材時刻バケット（キャッシュの実キー）。
    let actualBucket: Int
    let image: UIImage
}

#if DEBUG
/// テスト用: `TimelineThumbnailStore.generate` の同時実行数を数える。
///
/// 「生成は常に同時 1 バッチだけ」は HW デコーダ取り合い対策の中核不変条件だが、
/// MainActor 側の `activeBatch` を見るだけでは**デコードが実際に重なった**ことを
/// 検出できない（cancel 済みバッチのデコードは完走する）。デコード関数の入口・出口で
/// 数えることで、レビュアーと同じ形（並走回数）で実測できる。
final class TimelineThumbnailConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximumConcurrent = 0
    /// 2 個以上が同時に走った回数。
    private(set) var overlapCount = 0
    /// `copyCGImage` を実際に呼んだ回数（同一キーフレームの作り直しを数えるため）。
    private(set) var decodeCount = 0

    func countDecode() {
        lock.lock()
        decodeCount += 1
        lock.unlock()
    }

    func enter() {
        lock.lock()
        current += 1
        maximumConcurrent = max(maximumConcurrent, current)
        if current > 1 { overlapCount += 1 }
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current = max(0, current - 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        current = 0
        maximumConcurrent = 0
        overlapCount = 0
        decodeCount = 0
        lock.unlock()
    }
}

/// デコード同時実行数のプローブ（DEBUG のみ）。グローバルに置いているのは
/// `@MainActor` 型の static メンバをデコード側（MainActor 外）から触らないため。
let timelineThumbnailConcurrencyProbe = TimelineThumbnailConcurrencyProbe()
#endif

/// サムネイル生成の中断ハンドル（生成側スレッドと UI スレッドで共有する）。
///
/// `AVAssetImageGenerator.copyCGImage` は同期 API で、キャンセルできる手段は
/// `cancelAllCGImageGeneration()` だけ。Swift の `Task` キャンセルは
/// `Task.detached` の中の同期ループには伝わらない（detached は親のキャンセルを
/// 継承しない）ため、フラグと生成器の実体をこの箱で共有して明示的に打ち切る。
final class TimelineThumbnailCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var generator: AVAssetImageGenerator?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// **次の 1 枚へ進ませない**（進行中の 1 枚は完走する）。
    ///
    /// `cancelAllCGImageGeneration()` は同期 `copyCGImage` を打ち切らない、というのが
    /// 実測結果である（キャンセル開始の 1.5ms 後に呼んでも残り 2.9ms を完走して画像を
    /// 返し、throw もしない。6/6 試行で同様）。したがって実際に効いているのは
    /// フレーム間の `isCancelled` 判定だけで、**打ち切り要求から最大 1 枚ぶんの
    /// デコードは再生・シークと重なる**。1 枚のデコードは 720p で 5〜13ms、
    /// 4K/HEVC の実機ではその数倍になる。この重なりを短く保つため
    /// `TimelineThumbnailStore.batchLimit` は小さく維持すること
    /// （バッチ単位ではなく 1 枚単位で判定するので、上限を上げても重なりの長さ自体は
    /// 変わらないが、キャンセル判定の回数が増えると打ち切り後の後始末が遅れる）。
    func cancel() {
        lock.lock()
        cancelled = true
        let target = generator
        lock.unlock()
        target?.cancelAllCGImageGeneration()
    }

    /// 生成器を登録する。既にキャンセル済みなら false（生成を始めない）。
    func adopt(_ newGenerator: AVAssetImageGenerator) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        generator = newGenerator
        return true
    }

    func release() {
        lock.lock()
        generator = nil
        lock.unlock()
    }
}

/// タイムラインのサムネイル生成とキャッシュ。
///
/// **HW デコーダの取り合い対策（この構成で実機が全滅した前科がある）**:
///
/// - **プレビューがデコード資源を握っている間は 1 枚も生成しない。** 抑止条件は
///   再生（`setPlaying`）だけでは足りない。編集（分割・トリム・削除・並べ替え・速度・
///   トランジション・適用区間）は composition 差し替え + zero-tolerance seek +
///   `renderCurrentFrame` を起こし、スクラブは `onChanged` ごとに seek を撃つが、
///   どちらも `isPlaying == false` である。`setPreviewBusy` は
///   `MosaicEditorModel.isPreviewDecodeBusy`（プレビュー側の入口/出口で立つフラグ）を
///   受けて、これらの窓でも生成を止める。
/// - 生成は常に**同時 1 バッチだけ**。`cancel()` は `activeBatch` を **nil にしない**
///   （nil にすると `pump` の「生成中でない」判定が誤り、再生→即一時停止のような
///   連続トグルで生成器が 2 個・3 個と増える。実測でその窓は 1 バッチの残りデコード時間
///   = 720p で 33ms、4K 実機なら数百 ms あった）。解除は `finish` が
///   「自分がまだ現行バッチか」を照合してから行う。
/// - 素材の入れ替え（`reset`）は**世代トークン**を進める。旧バッチの `finish` は世代を
///   照合し、世代違いなら produced も再投入も丸ごと捨てる（捨てた素材のコマを
///   デコードし直したり、描画に使えないキャッシュで枠を食ったりしない）。
/// - 生成は `Task.detached` の中で行い MainActor をブロックしない。結果の書き込みだけ
///   MainActor に戻る。
///
/// **キャッシュのキーは「実際に返ってきたコマの素材時刻」**（`bucketSeconds` 丸め）。
/// 要求時刻はキーフレームへ丸められるので（`requestedTimeToleranceBefore = ∞`）、
/// 要求時刻でキャッシュすると同じコマが何枚も別エントリとして入る（実測: 60 枠の帯で
/// 異なるコマは 10 枚しかなく、50/60 が重複だった）。要求時刻バケット → 実コマバケットの
/// 対応は `alias` が持ち、描画は `image(sourceID:sourceTime:)` 経由で解決する。
///
/// **キャッシュの追い出しは FIFO**（挿入順。参照時刻は記録していないので LRU ではない）。
@MainActor
final class TimelineThumbnailStore: ObservableObject {
    /// キャッシュキー（素材 + 素材時刻バケット）。
    struct Key: Hashable {
        let sourceID: UUID
        let bucket: Int
    }

    /// 生成要求 1 件。
    struct Request {
        let sourceID: UUID
        let url: URL
        let sourceTime: Double
    }

    /// 素材時刻の丸め幅（秒）。
    static let bucketSeconds: Double = timelineThumbnailBucketSeconds
    /// 1 バッチで作る最大枚数。少なすぎると生成器の作り直しが増え、多すぎると
    /// 打ち切り要求から実際に止まるまでが遅れる（`TimelineThumbnailCanceller.cancel` の doc）。
    private static let batchLimit = 4
    /// キャッシュ上限（枚）。超えたら古い要求から捨てる（FIFO）。
    private static let cacheLimit = 240
    /// 保留キューの上限（件）。長尺を延々スクラブしても際限なく溜めない。
    /// 溢れたら**古い方**を捨てる（新しい要求のほうが今の表示に近い）。
    private static let pendingLimit = 480
    /// 同じコマの生成を諦めるまでの連続失敗回数。
    ///
    /// 1 回で恒久ブラックリストにすると、デコーダ競合・セッション枯渇・メモリ圧による
    /// 一過性の失敗で当該コマが永久に黒くなる（`reset` 以外で消えないため）。
    private static let maximumFailures = 3

    @Published private(set) var images: [Key: UIImage] = [:]

    /// 要求時刻バケット → 実コマバケット。`images` から消えた画像を指す別名は
    /// `trimCacheIfNeeded` が掃除する（残すと「要求済みだが描けない」枠になる）。
    private var alias: [Key: Key] = [:]
    private var pending: [Key: (url: URL, time: Double)] = [:]
    private var pendingOrder: [Key] = []
    private var insertionOrder: [Key] = []
    /// 生成に失敗した回数（`maximumFailures` 到達で再要求をやめる）。
    private var failureCounts: [Key: Int] = [:]
    private var isPlaying = false
    private var isPreviewBusy = false
    private var isScrubbing = false
    private var isSuspended = false
    private var activeBatch: TimelineThumbnailCanceller?
    /// 素材世代。`reset` で進み、旧バッチの結果を捨てる判定に使う。
    private var generation = 0

    /// テスト用: 生成中バッチがあるか（不変条件「同時 1 バッチ」の MainActor 側の見え方）。
    var isGeneratingForTesting: Bool { activeBatch != nil }
    /// テスト用: 現在の素材世代。
    var generationForTesting: Int { generation }
    /// テスト用: 保留件数。
    var pendingCountForTesting: Int { pendingOrder.count }

    static func key(sourceID: UUID, sourceTime: Double) -> Key {
        Key(sourceID: sourceID, bucket: timelineThumbnailBucket(sourceTime))
    }

    /// キャッシュ済みサムネイル（無ければ nil）。**生成の副作用は無い**
    /// （View の body から呼んでよい唯一のアクセサ）。
    ///
    /// 要求時刻のキーに直接無い場合は `alias`（要求時刻 → 実コマ）で引き直す。
    func image(sourceID: UUID, sourceTime: Double) -> UIImage? {
        let key = Self.key(sourceID: sourceID, sourceTime: sourceTime)
        if let image = images[key] { return image }
        guard let target = alias[key] else { return nil }
        return images[target]
    }

    /// そのコマが**まだ生成されていない**（描画できない）かどうか。
    ///
    /// View は 1 回の要求で投入する枚数に上限を持つが、その予算は
    /// **未生成のジョブに対して**使うこと。キャッシュ済みのジョブも予算を数えると、
    /// 常に同じ順で積む `clipLayouts` の先頭 2 クリップが予算を食い切り、
    /// 3 本目以降のクリップが何度 refresh しても 1 件も要求されない
    /// （実測: pps=160 / 20 秒クリップで 120 枠に収まるのは 2 クリップ）。
    func needsGeneration(sourceID: UUID, sourceTime: Double) -> Bool {
        let key = Self.key(sourceID: sourceID, sourceTime: sourceTime)
        if images[key] != nil { return false }
        if let target = alias[key], images[target] != nil { return false }
        if pending[key] != nil { return false }
        if (failureCounts[key] ?? 0) >= Self.maximumFailures { return false }
        return true
    }

    /// 生成要求をまとめて投入する。
    ///
    /// 生成できない状態（再生中・プレビューがデコード中・画面離脱中）でも**保留キューには
    /// 積む**（捨てると、編集直後の refresh が丸ごと失われて帯が空のまま残る）。
    /// 実際の生成は状態が戻った時点で `pump` が再開する。
    /// 既にキャッシュ済み・要求済み・失敗上限に達したキーは無視する。
    /// View の body ではなく `onAppear` / `onChange` から呼ぶこと。
    func request(_ jobs: [Request]) {
        for job in jobs {
            let key = Self.key(sourceID: job.sourceID, sourceTime: job.sourceTime)
            guard needsGeneration(sourceID: job.sourceID, sourceTime: job.sourceTime) else { continue }
            enqueue(key: key, url: job.url, time: Double(key.bucket) * Self.bucketSeconds)
        }
        pump()
    }

    /// 再生状態を伝える。
    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        updateGeneration()
    }

    /// プレビュー側のデコード占有を伝える（`MosaicEditorModel.isPreviewDecodeBusy`）。
    func setPreviewBusy(_ busy: Bool) {
        guard isPreviewBusy != busy else { return }
        isPreviewBusy = busy
        updateGeneration()
    }

    /// スクラブ中かどうかを伝える。
    ///
    /// `setPreviewBusy` と別フラグにしてある: スクラブ中は seek のたびに
    /// プレビュー側の busy が立ち下がるため、同じフラグを共有すると
    /// ドラッグ途中で生成が始まってしまう。
    func setScrubbing(_ scrubbing: Bool) {
        guard isScrubbing != scrubbing else { return }
        isScrubbing = scrubbing
        updateGeneration()
    }

    /// 画面離脱・バックグラウンドを伝える。
    ///
    /// 進行中の `Task` は `[weak self]` なので self が消えても `generate` は完走する
    /// （720p で 1 バッチ数十 ms、4K ならその数倍のデコードが裏で続く）。
    /// エディタから戻る・シートで隠れる・アプリが背面へ回る、のいずれでも止めること。
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        updateGeneration()
    }

    /// 素材が入れ替わったときに全て捨てる。
    ///
    /// **`activeBatch` は nil にしない**（M-B1 と同じ理由。nil にすると直後の新素材バッチが
    /// 旧バッチと並走する）。旧バッチの結果は世代照合で捨てられる。
    func reset() {
        generation += 1
        activeBatch?.cancel()
        pending.removeAll()
        pendingOrder.removeAll()
        insertionOrder.removeAll()
        failureCounts.removeAll()
        alias.removeAll()
        images.removeAll()
    }

    // MARK: - 生成ループ

    /// 生成してよい状態か（再生中・プレビューのデコード中・スクラブ中・離脱中は不可）。
    private var canGenerate: Bool { !isPlaying && !isPreviewBusy && !isScrubbing && !isSuspended }

    /// テスト用: 生成が抑止されているか。
    var isGenerationBlockedForTesting: Bool { !canGenerate }

    /// 抑止条件が変わったときの再開 / 打ち切り。
    private func updateGeneration() {
        if canGenerate {
            pump()
        } else {
            activeBatch?.cancel()
        }
    }

    private func enqueue(key: Key, url: URL, time: Double) {
        pending[key] = (url, time)
        pendingOrder.append(key)
        guard pendingOrder.count > Self.pendingLimit else { return }
        let overflow = pendingOrder.count - Self.pendingLimit
        for stale in pendingOrder.prefix(overflow) { pending.removeValue(forKey: stale) }
        pendingOrder.removeFirst(overflow)
    }

    /// 保留キューを 1 バッチぶん流す。生成不可・生成中は何もしない。
    private func pump() {
        guard canGenerate, activeBatch == nil else { return }
        guard let batch = nextBatch() else { return }
        let canceller = TimelineThumbnailCanceller()
        activeBatch = canceller
        let batchGeneration = generation
        Task { [weak self] in
            let produced = await Self.generate(url: batch.url, jobs: batch.jobs, canceller: canceller)
            guard let self else { return }
            self.finish(canceller: canceller, generation: batchGeneration,
                        url: batch.url, produced: produced, jobs: batch.jobs)
        }
    }

    /// 同一素材のジョブを先頭から最大 `batchLimit` 件取り出す。
    private func nextBatch() -> (url: URL, jobs: [(key: Key, time: Double)])? {
        guard let firstKey = pendingOrder.first, let first = pending[firstKey] else { return nil }
        var jobs: [(key: Key, time: Double)] = []
        var remaining: [Key] = []
        for key in pendingOrder {
            guard let entry = pending[key] else { continue }
            if entry.url == first.url, jobs.count < Self.batchLimit {
                jobs.append((key, entry.time))
            } else {
                remaining.append(key)
            }
        }
        pendingOrder = remaining
        for job in jobs { pending.removeValue(forKey: job.key) }
        return jobs.isEmpty ? nil : (first.url, jobs)
    }

    /// バッチ結果を反映して次のバッチへ進む。
    ///
    /// 打ち切られたバッチ（再生開始・編集）でも取れた分はキャッシュに入れる。取れなかった
    /// キーだけ保留へ戻し、抑止が解けてから取り直す（打ち切りで欠けたコマが永久に空白に
    /// ならないようにする）。世代違いのバッチは produced も再投入も丸ごと捨てる。
    private func finish(canceller: TimelineThumbnailCanceller,
                        generation batchGeneration: Int,
                        url: URL,
                        produced: [TimelineThumbnailProduct],
                        jobs: [(key: Key, time: Double)]) {
        if activeBatch === canceller { activeBatch = nil }
        canceller.release()
        guard batchGeneration == generation else {
            pump()
            return
        }
        var satisfied: Set<Key> = []
        for item in produced {
            let target = Key(sourceID: item.requestedKey.sourceID, bucket: item.actualBucket)
            store(image: item.image, at: target)
            if target != item.requestedKey { alias[item.requestedKey] = target }
            failureCounts.removeValue(forKey: item.requestedKey)
            satisfied.insert(item.requestedKey)
        }
        // 打ち切りでなく取れなかったコマは失敗として数える。無条件に保留へ戻すと
        // pump が同じジョブを無限に回す。
        let wasCancelled = canceller.isCancelled
        for job in jobs where !satisfied.contains(job.key) && images[job.key] == nil && alias[job.key] == nil {
            guard wasCancelled else {
                failureCounts[job.key, default: 0] += 1
                continue
            }
            guard pending[job.key] == nil else { continue }
            enqueue(key: job.key, url: url, time: job.time)
        }
        trimCacheIfNeeded()
        pump()
    }

    /// 画像をキャッシュへ入れる。**同一キーの再生成で挿入順を二重登録しない**
    /// （二重登録すると FIFO の追い出しが「古い方の重複」を見て、直前に入れた
    /// 新しい画像を捨てることがある）。
    private func store(image: UIImage, at key: Key) {
        if images[key] == nil { insertionOrder.append(key) }
        images[key] = image
    }

    private func trimCacheIfNeeded() {
        guard images.count > Self.cacheLimit else { return }
        var order = insertionOrder
        while images.count > Self.cacheLimit, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
        insertionOrder = order.filter { images[$0] != nil }
        alias = alias.filter { images[$0.value] != nil }
    }

    /// 1 素材ぶんのサムネイルを 1 個の生成器でまとめて作る（MainActor 外）。
    ///
    /// 各枚の前にキャンセル判定を挟むため、打ち切り後は次の 1 枚へ進まない
    /// （進行中の 1 枚は完走する。`TimelineThumbnailCanceller.cancel` の doc）。
    ///
    /// **`requestedTimeToleranceAfter = .zero`（before は ∞）にしている理由**:
    /// 返ってくるコマが「要求時刻**以前**の直近キーフレーム」に確定するため、
    /// ジョブを**時刻の降順**に処理すると 1 回のデコードで
    /// 「(実コマ時刻, 要求時刻] にキーフレームは無い」ことが分かる。残りのジョブのうち
    /// 実コマ時刻以上のものは同じコマに解決されるので、デコードせずに同じ画像を割り当てる。
    /// 両側 ∞ のままだと「最も近いキーフレーム」が前後どちらにもなり得て、この推論が
    /// 成り立たない（実測では 60 枠のうち 50 枠が同じコマの作り直しになっていた）。
    /// キーフレームからの前方デコードは発生しないので 1 枚あたりのコストは変わらない。
    private nonisolated static func generate(
        url: URL,
        jobs: [(key: Key, time: Double)],
        canceller: TimelineThumbnailCanceller
    ) async -> [TimelineThumbnailProduct] {
        await Task.detached(priority: .utility) {
            #if DEBUG
            timelineThumbnailConcurrencyProbe.enter()
            defer { timelineThumbnailConcurrencyProbe.leave() }
            #endif
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .zero
            guard canceller.adopt(generator) else { return [] }
            defer { canceller.release() }
            var result: [TimelineThumbnailProduct] = []
            let ordered = jobs.sorted { $0.time > $1.time }
            var index = 0
            while index < ordered.count {
                guard !canceller.isCancelled else { break }
                let job = ordered[index]
                index += 1
                var actual = CMTime.zero
                let requested = CMTime(seconds: max(0, job.time), preferredTimescale: 600)
                #if DEBUG
                timelineThumbnailConcurrencyProbe.countDecode()
                #endif
                guard let cgImage = try? generator.copyCGImage(at: requested, actualTime: &actual)
                else { continue }
                let image = UIImage(cgImage: cgImage)
                let seconds = actual.isValid && actual.seconds.isFinite ? max(0, actual.seconds) : job.time
                let bucket = timelineThumbnailBucket(seconds)
                result.append(TimelineThumbnailProduct(requestedKey: job.key,
                                                       actualBucket: bucket, image: image))
                // 実コマが要求時刻より後（想定外の tolerance 挙動）なら推論しない。
                guard seconds <= job.time else { continue }
                while index < ordered.count, ordered[index].time >= seconds {
                    result.append(TimelineThumbnailProduct(requestedKey: ordered[index].key,
                                                           actualBucket: bucket, image: image))
                    index += 1
                }
            }
            return result
        }.value
    }
}
