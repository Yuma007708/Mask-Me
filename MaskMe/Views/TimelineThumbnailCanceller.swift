import AVFoundation
import Foundation

// サムネイル生成を MainActor 外（`Task.detached` のデコードループ）と共有するための箱。
// `@MainActor` の `TimelineThumbnailStore` からは分離しておく必要があるので
// （MainActor 隔離された型の static/メンバをデコード側から触らないため）、
// ファイルごと分けてある。

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
