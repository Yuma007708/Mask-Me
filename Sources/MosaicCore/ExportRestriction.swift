import CoreGraphics
import Foundation

/// 書き出し時に適用する無料プランの制限（コア判定結果）。
///
/// **制限の当て方は種類ごとに違う**（呼び出し側はここを分岐の唯一の根拠にすること）:
/// - `.exceedsDuration`: 書き出しを**止める**。切り詰めて保存すると事故に見えるため、
///   途中終わりの動画を勝手に作らない。
/// - `.exceedsResolution`: 止めず、1080p 相当へ**縮小して**書き出す。素材が 4K というだけで
///   何も書き出せないのは体験として悪いため。
/// - `.watermarkOnly`: 尺・解像度は範囲内。無料プランなら常に透かしを載せる
///   （透かしの描画そのものは P2 で実装。ここでは判定のみ）。
/// - `.none`: Pro。制限なし。
public enum ExportRestriction: Equatable, Sendable {
    case none
    case watermarkOnly
    case exceedsDuration(limit: Double)
    case exceedsResolution(limit: Int)

    /// このケースで透かしを載せるか。
    ///
    /// **`.exceedsResolution` でも載せる**（縮小して書き出すが、無料プランであることに
    /// 変わりはない）。enum が排他なので「解像度超過かつ透かし」を case で表現できず、
    /// ここを導出にしないと 4K 素材の無料ユーザーだけ透かしが抜ける。
    /// `.exceedsDuration` は書き出しそのものを止めるので不要。
    public var needsWatermark: Bool {
        switch self {
        case .none, .exceedsDuration:
            return false
        case .watermarkOnly, .exceedsResolution:
            return true
        }
    }
}

/// `ExportRestriction` を決める純粋関数群。
///
/// **MediaPipe / AVFoundation / `EntitlementProvider` に一切依存しない**
/// （`MosaicCore` はアプリの課金 Provider を知らない。`isPro` は呼び出し側が
/// `LocalEntitlementProvider.shared.isPro` 等から Bool として渡す）。
public enum ExportRestrictionPolicy {
    /// 無料プランの書き出し尺の上限（秒）。ちょうど上限は許容（`<=`）。
    public static let freeMaxDurationSeconds: Double = 60
    /// 無料プランの書き出し解像度の上限（**短辺** px）。
    ///
    /// 「1080p」は一般に短辺（横動画なら高さ、縦動画なら幅）が 1080 の解像度を指す
    /// （例: 1920x1080 と 1080x1920 はどちらも短辺 1080）。長辺で判定すると、
    /// 向きによって同じ 1080p 素材の可否が入れ替わってしまう。
    public static let freeMaxResolutionShortSide: Int = 1080

    /// 判定の唯一の入口。
    ///
    /// 尺超過を最優先で返す（尺・解像度の両方が超過していても `.exceedsDuration` を
    /// 返し、書き出しを止める。「止める」判定に「縮小すれば通る」余地を残さないため）。
    ///
    /// - Parameters:
    ///   - isPro: Pro 権限が解放されているか。
    ///   - durationSeconds: 実際に書き出す尺（トリム後）。非有限・負は 0 として扱う
    ///     （判定を「常に超過」側へ倒して書き出しを止めるのは事故なので、安全側は
    ///     「制限なし」に倒す）。
    ///   - resolution: 書き出し解像度。**`VideoCompositionFactory.renderSize(for:)` の
    ///     結果をそのまま渡すこと**（このコア層に解像度算出ロジックを再実装しない）。
    /// - Returns: 適用すべき制限。
    public static func decide(isPro: Bool,
                              durationSeconds: Double,
                              resolution: CGSize) -> ExportRestriction {
        guard !isPro else { return .none }

        let duration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0
        guard duration <= freeMaxDurationSeconds else {
            return .exceedsDuration(limit: freeMaxDurationSeconds)
        }

        guard let shortSide = shortSidePixels(of: resolution),
              shortSide > freeMaxResolutionShortSide else {
            return .watermarkOnly
        }
        return .exceedsResolution(limit: freeMaxResolutionShortSide)
    }

    /// 解像度超過のとき、短辺が `shortSideLimit` になるまでアスペクト比を保って縮小する。
    ///
    /// 既存の解像度決定（`VideoCompositionFactory.renderSize(for:)`）の**結果に掛ける
    /// 後処理**であり、フォーマット→サイズの変換ロジックを再実装しない。短辺が既に
    /// 上限以下なら入力をそのまま返す（拡大はしない）。
    ///
    /// 偶数へ丸める（`VideoCompositionFactory.renderSize` と同じ理由。奇数サイズは
    /// HEVC/H.264 エンコーダで扱いが崩れる）。
    public static func clampedResolution(_ size: CGSize, shortSideLimit: Int) -> CGSize {
        guard let shortSide = shortSidePixels(of: size), shortSide > shortSideLimit,
              shortSideLimit > 0 else {
            return size
        }
        let scale = CGFloat(shortSideLimit) / CGFloat(shortSide)
        return CGSize(width: even(size.width * scale), height: even(size.height * scale))
    }

    /// 短辺（px、整数丸め）。非有限・非正の入力は判定不能として nil。
    private static func shortSidePixels(of size: CGSize) -> Int? {
        let shortSide = min(size.width, size.height)
        guard shortSide.isFinite, shortSide > 0 else { return nil }
        return Int(shortSide.rounded())
    }

    /// 偶数（かつ 2 以上）へ丸める。
    private static func even(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        let rounded = (value / 2).rounded() * 2
        return max(2, rounded)
    }
}
