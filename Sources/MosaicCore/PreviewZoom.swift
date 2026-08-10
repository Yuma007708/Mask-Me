import CoreGraphics

/// プレビューのピンチズーム／パンの現在値（値型）。
///
/// `PreviewImageGeometry` に合流させ、`imageRect` を経由する全オーバーレイへ
/// 同じ拡大・平行移動を波及させる（`PreviewZoomMath` の doc 参照）。
public struct PreviewZoom: Equatable, Sendable {
    /// 拡大率。1 が等倍（fit）。`PreviewZoomMath.clampedScale` の範囲 `1...8` に収める前提。
    public var scale: CGFloat
    /// 平行移動量（pt）。`PreviewZoomMath` の各関数が可動域へクランプする。
    public var offset: CGSize

    public init(scale: CGFloat, offset: CGSize) {
        self.scale = scale
        self.offset = offset
    }

    /// 等倍・移動なし。
    public static let identity = PreviewZoom(scale: 1, offset: .zero)

    /// 等倍かつ移動なしか。
    public var isIdentity: Bool { self == .identity }
}
