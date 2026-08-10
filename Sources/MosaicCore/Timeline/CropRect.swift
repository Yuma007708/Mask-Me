import CoreGraphics
import Foundation

/// 出力枠（＝画面比率適用後の合成フレーム）に対する正規化部分矩形によるクロップ。
///
/// **これは「素材のどの範囲を使うか」ではない。** 確定した適用順序（この順でなければならない）:
///
/// ```
/// 素材正規化座標
///  → ClipOrientation.map    (クリップ単位・回転反転)
///  → AspectFit.placement    (レターボックス)
///  → CropRect.expand        (このクロップ。枠を切り、配置を新枠基準へ)
///  → ClipTransform.apply    (新枠の中での拡大縮小・位置。別ブランチで並行実装中)
/// ```
///
/// クロップが `AspectFit` の**後**にあるのは、クロップは「見えている枠」を切るものであり、
/// 素材基準にすると回転を後から変えたときに切る場所が変わって写像が2系統になってしまうため。
/// **出力枠基準を採ったので「回転した写真を切り抜くと別の場所が切れる」は定義上起こり得ない。**
///
/// `TimelineRenderLayout.remap` と同じく、ここにも**クランプ・交差・[0,1] 収めは無い**。
/// 枠外へはみ出した配置矩形はそのままはみ出した値で返る（描画側が打ち切るだけで、
/// 値そのものを押し込めてはならない。`TimelineStateAspectRatio` の doc と同じ規約）。
public struct CropRect: Equatable, Sendable, Codable {
    /// クロップの最小の一辺（正規化）。これより小さいと拡大率が極端になり、
    /// 1px のずれが致命的な誤差になる（プレビュー操作の実用上の下限でもある）。
    public static let minimumSide: CGFloat = 0.05

    /// 出力枠に対する正規化部分矩形（左上原点）。常に [0,1]×[0,1] に収まり、
    /// 各辺は `minimumSide` 以上に保たれる（`init(rect:)` / デコードが保証する）。
    public private(set) var rect: CGRect

    /// 全面（クロップなし）。
    public static let full = CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// 任意の矩形からクロップを作る。**正規化を必ず通す**:
    /// 非有限・非正のサイズは `.full` へ倒し、[0,1] を超える／はみ出す指定は収まるよう
    /// クランプし、`minimumSide` を下回る辺は引き上げる。ここで throw せずクランプすることで、
    /// 呼び出し側（UI のドラッグ・デコード）がどんな値を渡しても常に使える値が返る。
    public init(rect: CGRect) {
        self.rect = Self.normalized(rect)
    }

    /// 全面（クロップなし）か。
    public var isFull: Bool { rect == Self.full.rect }

    /// `AspectFit.placement` 等で得た配置矩形を、このクロップを新しい出力枠として
    /// 捉え直した配置へ写す。
    ///
    /// 式: `((p.minX-c.minX)/c.width, (p.minY-c.minY)/c.height, p.width/c.width, p.height/c.height)`
    /// （`c` はこのクロップの `rect`）。
    ///
    /// **クランプ・交差はしない。** 配置が新しい枠からはみ出しても、はみ出した値
    /// （負の原点・1 を超える幅）をそのまま返す。これは「クロップ後の映像がそのクリップの
    /// 全体を写しきれない」ことを表しており、描画段で打ち切られるだけでよい
    /// （`TimelineRenderLayout.remap` が同じ契約）。
    ///
    /// **呼び出し側は `snappedRect(inFrame:)` を正規化し直した値をこの `self` に使うこと。**
    /// 丸め前の生の `rect`（`init(rect:)` にそのまま渡した値）から計算すると、実際の出力
    /// ピクセル寸法（`outputSize(fittingFrame:)` は偶数へスナップ済み）と縮尺が食い違い、
    /// 映像とモザイクが 1px 以上ずれる（`RenderPlacement.make` 参照）。
    public func expand(_ placement: CGRect) -> CGRect {
        guard !isFull else { return placement }
        guard rect.width > 0, rect.height > 0 else { return placement }
        return CGRect(x: (placement.minX - rect.minX) / rect.width,
                      y: (placement.minY - rect.minY) / rect.height,
                      width: placement.width / rect.width,
                      height: placement.height / rect.height)
    }

    /// 偶数スナップまで含めた**正しい手順を実体化した唯一の関数**。
    /// `expand` の直前に必ず要る「`snappedRect` を正規化し直して分母にする」処理を
    /// ここに閉じ、`RenderPlacement.make` もテストもこれを通る。
    ///
    /// **手順をテストの中に書き写してはならない。** 書き写すと、本番側が丸め前の生の
    /// `rect` を分母に使う実装へ退行しても、テストは自分の写しを検査して緑のまま
    /// 素通りする（親の変異検証で実際に素通りした）。
    public func expandSnapped(_ placement: CGRect, inFrame frame: CGSize) -> CGRect {
        guard !isFull else { return placement }
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return placement }
        let snapped = snappedRect(inFrame: frame)
        let effective = CropRect(rect: CGRect(x: snapped.minX / frame.width,
                                              y: snapped.minY / frame.height,
                                              width: snapped.width / frame.width,
                                              height: snapped.height / frame.height))
        return effective.expand(placement)
    }

    /// `expand(_:)` の逆写像。新しい枠（このクロップの `rect`）基準の配置を、
    /// 元の出力枠基準の配置へ戻す。
    ///
    /// 式: `(c.minX + q.minX*c.width, c.minY + q.minY*c.height, q.width*c.width, q.height*c.height)`
    /// （`c` はこのクロップの `rect`）。
    ///
    /// **クランプ・交差はしない。** `expand(_:)` と同じ契約——`q` が `[0,1]` の外を
    /// 指していても、そのままはみ出した値を返す（`TimelineRenderLayout.remap` と
    /// 同じ規約）。
    public func contract(_ placement: CGRect) -> CGRect {
        guard !isFull else { return placement }
        return CGRect(x: rect.minX + placement.minX * rect.width,
                      y: rect.minY + placement.minY * rect.height,
                      width: placement.width * rect.width,
                      height: placement.height * rect.height)
    }

    /// `expandSnapped(_:inFrame:)` の逆写像。`contract(_:)` を、偶数スナップまで
    /// 含めた「正しい手順」で呼ぶ（分母に丸め前の生の `rect` を使わない、という
    /// `expandSnapped` と同じ注意がここにも当てはまる）。
    public func contractSnapped(_ placement: CGRect, inFrame frame: CGSize) -> CGRect {
        guard !isFull else { return placement }
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return placement }
        let snapped = snappedRect(inFrame: frame)
        let effective = CropRect(rect: CGRect(x: snapped.minX / frame.width,
                                              y: snapped.minY / frame.height,
                                              width: snapped.width / frame.width,
                                              height: snapped.height / frame.height))
        return effective.contract(placement)
    }

    /// クロップ矩形を `frame`（合成フレームのピクセルサイズ）へ写したピクセル矩形。
    /// スナップ前の生の値（`snappedRect(inFrame:)` が丸める前の入力）。
    public func pixelRect(inFrame frame: CGSize) -> CGRect {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: frame)
        }
        return CGRect(x: rect.minX * frame.width, y: rect.minY * frame.height,
                      width: rect.width * frame.width, height: rect.height * frame.height)
    }

    /// `pixelRect(inFrame:)` を偶数ピクセルへスナップした矩形（HEVC/H.264 の都合。
    /// `TimelineAspectRatio.renderSize` と同じ規則）。
    ///
    /// **このクロップを実際の出力へ適用するときは、必ずこの値を正規化し直してから
    /// `expand(_:)` の `self` に使うこと**（型 doc・`expand` の doc 参照）。
    public func snappedRect(inFrame frame: CGSize) -> CGRect {
        let pixel = pixelRect(inFrame: frame)
        let minX = pixel.minX.isFinite ? pixel.minX.rounded() : 0
        let minY = pixel.minY.isFinite ? pixel.minY.rounded() : 0
        return CGRect(x: minX, y: minY,
                      width: Self.evenSnap(pixel.width), height: Self.evenSnap(pixel.height))
    }

    /// クロップ後の出力サイズ（＝ `snappedRect(inFrame:)` のサイズ）。常に偶数・2 以上。
    public func outputSize(fittingFrame frame: CGSize) -> CGSize {
        snappedRect(inFrame: frame).size
    }

    // MARK: - 正規化

    private static func normalized(_ rect: CGRect) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return full }
        let standardized = rect.standardized
        guard standardized.width > 0, standardized.height > 0 else { return full }

        let clampedMinimum = min(minimumSide, 1)
        var width = min(max(standardized.width, clampedMinimum), 1)
        var height = min(max(standardized.height, clampedMinimum), 1)
        var minX = min(max(standardized.minX, 0), 1)
        var minY = min(max(standardized.minY, 0), 1)
        if minX + width > 1 { minX = max(0, 1 - width) }
        if minY + height > 1 { minY = max(0, 1 - height) }
        // 上のクランプで幅・高さそのものは変えていないので、ここで再度はみ出すことは無い。
        width = min(width, 1 - minX)
        height = min(height, 1 - minY)

        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private static func evenSnap(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return max(2, (value / 2).rounded() * 2)
    }
}

// MARK: - Codable（下書き互換）

extension CropRect {
    private enum CodingKeys: String, CodingKey { case rect }

    /// **デコードで失敗しない。** 壊れた値（型不一致・NaN・負の幅など）は `.full` へ倒す。
    /// `ClipOrientation` / `ObjectMask.Keyframe.angle` と同じ移行規約——クロップはタイムラインの
    /// 一要素でしかないので、ここで throw すると下書きが丸ごと開けなくなる。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRect: CGRect?? = try? container.decodeIfPresent(CGRect.self, forKey: .rect)
        self.init(rect: (decodedRect ?? nil) ?? Self.full.rect)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rect, forKey: .rect)
    }
}
