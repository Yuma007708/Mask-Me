import CoreGraphics
import Foundation

/// 書き出し（＝プレビューの合成フレーム）の画面比率。ユーザーが選ぶ。
///
/// **これは「出力枠の形」だけを決める。素材は絶対に切り取らない。**
/// 枠に収まらない素材はアスペクト比を保ったまま縮小して中央へ置き、余白は黒帯になる
/// （レターボックス／ピラーボックス）。配置計算は `AspectFit.placement` の単一実装を
/// 使い、ここには書かない。
///
/// ## 座標系（プライバシー上いちばん重要な点）
///
/// 顔ランドマーク・矩形マスクは**素材フレーム基準の正規化座標**で保存されている。
/// 出力枠を変えると素材はレターボックスで縮むので、そのままでは枠基準の座標と
/// 食い違ってモザイクがずれる。この食い違いは `TimelineRenderLayout`（= 各クリップの
/// `AspectFit.placement` を持つ写像）が吸収する。
///
/// **同じ `placement` 矩形から、映像側の変換（`VideoCompositionFactory.fitTransform`）と
/// 顔座標側の写像（`TimelineRenderLayout.remap`）の両方を作ること。**
/// 片方だけがこの比率を知っていると、絵と顔位置がずれてモザイクが素通しになる。
///
/// ## 解像度の決め方
///
/// **出力枠の短辺を、素材（先頭クリップ）の表示サイズの短辺に合わせる。**
/// 長辺は比率から導く。1920x1080 の素材で
/// `.portrait9x16` → 1080x1920 / `.square1x1` → 1080x1080 / `.landscape16x9` → 1920x1080。
///
/// 「素材に内接する最大の枠」にすると 16:9 素材から 9:16 を選んだときに 608x1080 という
/// 極端に小さい出力になり、「素材に外接する最小の枠」にすると 1920x3414 とファイルだけが
/// 膨らむ。短辺基準は SNS 向けアプリの一般的な出力（1080 系）と一致し、どちらの破綻も
/// 起きない。
public enum TimelineAspectRatio: String, Codable, Equatable, Sendable, CaseIterable {
    /// 素材に合わせる（既定・従来挙動）。出力解像度は先頭クリップがそのまま決める
    /// （`VideoCompositionFactory.renderSize(for:)`）。
    case source
    /// 縦 9:16。
    case portrait9x16 = "9x16"
    /// 正方形 1:1。
    case square1x1 = "1x1"
    /// 横 16:9。
    case landscape16x9 = "16x9"

    /// 目標の縦横比（幅:高さ）。`.source` は「素材まかせ」なので nil。
    public var ratio: CGSize? {
        switch self {
        case .source: return nil
        case .portrait9x16: return CGSize(width: 9, height: 16)
        case .square1x1: return CGSize(width: 1, height: 1)
        case .landscape16x9: return CGSize(width: 16, height: 9)
        }
    }

    /// 素材基準の出力解像度から、この比率の出力枠サイズを求める。
    ///
    /// **`VideoCompositionFactory.renderSize(for:)` の結果に掛ける後処理**であり、
    /// フォーマット（naturalSize + preferredTransform）→ サイズの変換をここに再実装しない
    /// （`ExportRestrictionPolicy.clampedResolution` と同じ立ち位置）。
    ///
    /// - `.source` は**入力をビット同一で返す**。これにより呼び出し側は
    ///   「結果が入力と等しい＝出力枠を強制しない」で分岐でき、無変換タイムラインの
    ///   忠実度（`CompositionFidelityTests` の契約）が保たれる。
    /// - 偶数へ丸める（奇数サイズは HEVC/H.264 で扱いが崩れる。
    ///   `VideoCompositionFactory.renderSize` と同じ理由）。丸めで比率が厳密値から
    ///   最大 1px ぶんずれることがあるが、素材の配置は実際の枠サイズから
    ///   `AspectFit.placement` が引き直すので、絵と顔位置の一致は崩れない。
    /// - 非有限・非正のサイズは判断材料が無いので入力をそのまま返す
    ///   （`AspectFit` と同じ倒し方）。
    public func renderSize(fittingSourceSize sourceSize: CGSize) -> CGSize {
        guard let ratio else { return sourceSize }
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              ratio.width > 0, ratio.height > 0 else { return sourceSize }
        let shortSide = min(sourceSize.width, sourceSize.height)
        let shortRatio = min(ratio.width, ratio.height)
        let longRatio = max(ratio.width, ratio.height)
        let longSide = shortSide * longRatio / shortRatio
        // 正方形（幅 == 高さ）は縦扱いに倒す（どちらでも同じ値になる）。
        let isPortrait = ratio.height >= ratio.width
        return CGSize(width: Self.even(isPortrait ? shortSide : longSide),
                      height: Self.even(isPortrait ? longSide : shortSide))
    }

    /// 偶数（かつ 2 以上）へ丸める。
    private static func even(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return max(2, (value / 2).rounded() * 2)
    }
}
