import CoreGraphics
import Foundation

/// クリップ単位の拡大縮小・位置（変形）。
///
/// **変形の唯一の適用点は `applied(to:)` であり、その呼び出しは
/// `VideoCompositionFactory.make` の 1 箇所に閉じている。** `AspectFit.placement(of:in:)`
/// が作る配置矩形（`rect`）が `layoutRects`（顔座標の写像用）と `fitTransform`（映像用）の
/// 両方へ渡っているため、その `rect` へ 1 回だけこの変形を掛ければ、映像とモザイクが
/// 構造的に一致する（`ClipOrientation` と同じ「共有した写像から作る」設計）。
///
/// **`offset` は出力枠（配置矩形自身の幅・高さ）に対する正規化平行移動として定義する。**
/// `applied(to:)` は配置矩形しか受け取らないため、`renderSize` を別引数で渡す設計も
/// あり得たが、配置矩形自身のサイズを基準に取ることで signature を 1 引数のまま保てる。
/// これは「配置矩形の何%動かすか」という体感（scale を掛けたあとの見た目のサイズ基準で
/// 動く）にも自然に合う。renderSize 全体に対する割合ではないことに注意
/// （scale と offset を両方動かすと、offset の実効移動量は scale 前の配置矩形基準になる）。
public struct ClipTransform: Hashable, Sendable, Codable {
    /// 拡大縮小の許容範囲。UI のスライダー範囲（0.25x〜4x）と一致させる。
    public static let scaleRange: ClosedRange<Double> = 0.25...4.0
    /// 平行移動の許容範囲（配置矩形の幅・高さに対する比率）。
    public static let offsetRange: ClosedRange<Double> = -1.0...1.0

    /// 拡大縮小率。1.0 がアスペクトフィットのまま（既定）。
    /// init・直接代入・`init(from:)` のどの経路でも `scaleRange` にクランプされる
    /// （`ColorGrade` / `TimelineClip.rate` と同じ手口）。
    public var scale: Double {
        // didSet 内の再代入はオブザーバを再帰呼び出ししない。
        didSet { scale = Self.clampedScale(scale) }
    }

    /// 平行移動（出力枠の幅・高さに対する正規化オフセット）。既定は `.zero`。
    /// init・直接代入・`init(from:)` のどの経路でも各成分が `offsetRange` にクランプされる。
    public var offset: CGPoint {
        didSet { offset = Self.clampedOffset(offset) }
    }

    /// 無変形（既定値）。
    public static let identity = ClipTransform()

    public init(scale: Double = 1.0, offset: CGPoint = .zero) {
        // init 中は didSet が走らないため、明示的にクランプする。
        self.scale = Self.clampedScale(scale)
        self.offset = Self.clampedOffset(offset)
    }

    /// 無変形か（恒等写像として扱ってよいか）。
    public var isIdentity: Bool { scale == 1.0 && offset == .zero }

    /// 拡大縮小率を許容範囲へクランプする。NaN は min/max を素通りして配置矩形の
    /// サイズ計算を汚染するため、既定値（1.0 = 無変形）へ倒す。
    public static func clampedScale(_ value: Double) -> Double {
        value.isNaN ? 1.0 : min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// 平行移動の 1 成分を許容範囲へクランプする。NaN は既定値（0）へ倒す。
    public static func clampedOffsetComponent(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// 平行移動を許容範囲へクランプする（x・y 独立にクランプする）。
    public static func clampedOffset(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clampedOffsetComponent(Double(point.x)),
               y: clampedOffsetComponent(Double(point.y)))
    }

    /// **変形の唯一の適用点。** 出力正規化空間の配置矩形を変形後の矩形へ写す。
    ///
    /// 中心を保って `scale` 倍したあと、`offset × 配置矩形自身のサイズ` を中心へ加える。
    /// **`isIdentity` のときは入力をビット同一で返す**（無変形タイムラインの忠実度を
    /// 守るため。`ClipOrientation.map(_ rect:)` と同じ規約）。
    ///
    /// **`placement` はすでに `ClipOrientation` を掛けた後の出力空間の矩形であること。**
    /// つまりこの変形はクリップ内部の向きより**後**、画面（出力）座標系で効く。
    /// 90 度回転したクリップに `offset=(0.2, 0)` を掛けても、画面上は常に横方向へ動く
    /// （向きを先に掛けているので、素材の縦横に引きずられない）。
    public func applied(to placement: CGRect) -> CGRect {
        guard !isIdentity else { return placement }
        let width = placement.width * CGFloat(scale)
        let height = placement.height * CGFloat(scale)
        let centerX = placement.midX + CGFloat(offset.x) * placement.width
        let centerY = placement.midY + CGFloat(offset.y) * placement.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2,
                      width: width, height: height)
    }

    // MARK: - 可視領域（検出の被覆台帳へ渡す）

    /// **出力枠に実際に入っている素材の範囲**を、素材の正規化座標（配置矩形自身を
    /// [0,1]×[0,1] とみなす）で返す。
    ///
    /// `scale > 1` はこのアプリで初めて「フレーム外への切り取り」を作る（従来の
    /// `AspectFit` は必ず内接で素材が切れることが無かった）。切り取られた領域の顔は
    /// ライブ検出から**見えない**ため、この矩形を検出エントリの被覆として記録し、
    /// `DetectionCoverage.covers` で「縮小して新しく見えた領域」を検出し直させる。
    ///
    /// - Parameter placement: **変形適用後**の配置矩形（出力枠を [0,1]×[0,1] とみなす
    ///   正規化矩形。`ClipTransform.applied(to:)` の結果、アプリでは
    ///   `TimelineRenderLayout.placement(for:)` が持っている値）。
    /// - Returns: 素材正規化座標の可視矩形。完全に枠外なら `.zero`（何も見えていない）。
    ///   配置矩形が非有限・面積 0 なら判断材料が無いので素材全体（＝従来どおり
    ///   全部見えている扱い）へ倒す。
    ///
    /// **向き（`ClipOrientation`）はここでは戻さない。** この関数は出力枠と配置矩形しか
    /// 知らない純関数で、向きの逆写像は呼び出し側（アプリ層）が
    /// `ClipOrientation.inverseMap(_:)` で掛ける。
    public static func visibleSourceRect(placement: CGRect) -> CGRect {
        let rect = placement.standardized
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.width > 0, rect.height > 0 else { return DetectionCoverage.full }
        let clipped = rect.intersection(DetectionCoverage.full)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .zero }
        return CGRect(x: (clipped.minX - rect.minX) / rect.width,
                      y: (clipped.minY - rect.minY) / rect.height,
                      width: clipped.width / rect.width,
                      height: clipped.height / rect.height)
    }

    /// 変形**前**の配置矩形（`AspectFit.placement(of:in:)` の結果）から可視領域を求める。
    /// `applied(to:)` を掛けてから `visibleSourceRect(placement:)` に渡すだけの薄い口で、
    /// 変形の算術をここに書き足さないこと（適用点は `applied(to:)` の 1 箇所だけ）。
    public func visibleSourceRect(basePlacement: CGRect) -> CGRect {
        Self.visibleSourceRect(placement: applied(to: basePlacement))
    }

    // MARK: - Codable

    /// `offset` を `x`/`y` のフラットなキーへ分解してエンコードする。
    /// `CGPoint` を直接 `Codable` に任せると、壊れた片方の成分（型不一致・巨大値）が
    /// 全体の decode を throw させ、下書き 1 本が丸ごと消える事故になる
    /// （`init(from:)` の doc 参照）。成分ごとに `try?` で受けるため、フラットな
    /// キーの方が扱いやすい。
    private enum CodingKeys: String, CodingKey {
        case scale, offsetX, offsetY
    }

    /// **`init(from:)` は didSet を経由しない**ため、`scale`・`offset` の両方を
    /// 明示的にクランプする（`ColorGrade.init(from:)` と同じ注意）。
    ///
    /// **型が壊れていても throw しない。** `{"scale": "abc"}` のような型不一致は
    /// `decodeIfPresent` が投げるが、`try?` で握り潰して既定値へ倒す。ここで throw すると
    /// `TimelineClip` ごとデコードが失敗し、下書き 1 本が丸ごと消える
    /// （`ClipOrientation.init(from:)` の doc が警告している事故と同型）。
    /// `1e300` のような巨大値は型としては正しく decode できるので、`clampedScale` /
    /// `clampedOffsetComponent` が範囲へ倒す。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scaleValue: Double? = try? container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        self.scale = Self.clampedScale(scaleValue ?? 1.0)
        let xValue: Double? = try? container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        let yValue: Double? = try? container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        self.offset = Self.clampedOffset(CGPoint(x: xValue ?? 0, y: yValue ?? 0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scale, forKey: .scale)
        try container.encode(Double(offset.x), forKey: .offsetX)
        try container.encode(Double(offset.y), forKey: .offsetY)
    }
}
