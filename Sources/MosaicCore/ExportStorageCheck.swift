import Foundation

/// 書き出し前の空き容量チェックの純ロジック。
///
/// 書き出しは原寸のまま tmp に書くため、長尺 4K では容量不足が現実的に起きる。
/// 書き終わってから失敗するのではなく、開始前に見積もりと空き容量を比べて弾く。
/// 実際の空き容量取得（`URLResourceValues.volumeAvailableCapacity*`）は
/// ファイルシステムに触るのでアプリ層の仕事。ここは**判断だけ**を担う。
public enum ExportStorageCheck {
    /// 音声の既定ビットレート（bps）。AAC ステレオの一般的な設定値。
    public static let defaultAudioBitsPerSecond: Double = 128_000

    /// 出力サイズの見積もり（バイト）。
    ///
    /// `duration × (映像 bps + 音声 bps) / 8` に `headroom` を掛け、`floorBytes` を下限とする。
    /// コンテナのオーバーヘッドやビットレート変動を吸収するため既定で 30% 上乗せする。
    ///
    /// - Parameters:
    ///   - durationSeconds: 出力の長さ（秒）。
    ///   - videoBitsPerSecond: 映像のビットレート。素材の `estimatedDataRate` が
    ///     取れない（0 / 非有限）ときは呼び出し側が解像度から粗く見積もって渡す。
    ///   - audioBitsPerSecond: 音声のビットレート（既定 128kbps）。
    ///   - headroom: 上乗せ係数。1 未満・非有限は 1.0 に倒す（見積もりを縮めないため）。
    ///   - floorBytes: 見積もりの下限。極端に小さい見積もりで
    ///     「空きゼロでも書き出せる」と誤判定しないための保険。
    /// - Returns: 見積もりバイト数（負にはならない）。
    ///   入力が非有限などで計算不能な場合は `floorBytes` を返す。
    public static func estimatedBytes(durationSeconds: Double,
                                      videoBitsPerSecond: Double,
                                      audioBitsPerSecond: Double = defaultAudioBitsPerSecond,
                                      headroom: Double = 1.3,
                                      floorBytes: Int64 = 50 * 1024 * 1024) -> Int64 {
        let floor = max(0, floorBytes)
        // 非有限・負の入力は「その分の寄与なし」として 0 に倒す。
        // NaN は比較を素通りするので isFinite で先に落とす。
        let duration = sanitized(durationSeconds)
        let videoRate = sanitized(videoBitsPerSecond)
        let audioRate = sanitized(audioBitsPerSecond)
        let margin = (headroom.isFinite && headroom > 1) ? headroom : 1.0

        let bytes = duration * (videoRate + audioRate) / 8 * margin
        guard bytes.isFinite else { return floor }
        // Double → Int64 の変換は範囲外だとトラップする（`Double(Int64.max)` は
        // 2^63 に丸め上がるので `min` で挟むだけでは防げない）。厳密比較で先に飽和させる。
        guard bytes < Double(Int64.max) else { return Int64.max }
        return max(floor, Int64(bytes))
    }

    /// 見積もりが空き容量に収まるか。
    ///
    /// 空き容量が負（取得失敗をそのまま渡された等）の場合は安全側に倒して `false` を返す。
    public static func hasEnoughSpace(requiredBytes: Int64, availableBytes: Int64) -> Bool {
        guard availableBytes >= 0 else { return false }
        return availableBytes >= max(0, requiredBytes)
    }

    /// 非有限・負の値を 0 に倒す。
    private static func sanitized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
