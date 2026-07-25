import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// 粗さ（`MosaicParams.block`）の**解像度非依存化**。
///
/// 顔メッシュ経路（`FaceMeshMosaicRenderer`）はブロックを固定 256px キャンバス基準へ
/// 換算しているため元から解像度に依らない。コンタ経路（部分メッシュ顔・手動矩形）と
/// 背景経路は `block` をそのテクスチャのピクセル数として使っていたため、
/// プレビュー（720px へ縮小）と書き出し（原寸）で粗さが食い違っていた。
/// ここに換算規則を 1 箇所だけ置き、両経路がそれを共有する。
extension MosaicRenderer {
    /// 粗さスライダー（`MosaicParams.block`）が校正されている基準フレーム幅（px）。
    ///
    /// プレビューはフレームをこの幅へ縮小してからモザイクを掛け（`MosaicPreviewController`）、
    /// 書き出しは原寸のまま掛ける。`block` を「そのテクスチャのピクセル数」として使うと、
    /// 同じスライダー値でも 1080p の書き出しはプレビューより 1.5 倍、4K なら 5.3 倍細かくなり、
    /// **プレビューで確認した粗さより弱い匿名化**が出力される（しかも書き出すまで気づけない）。
    /// そこでフレーム幅に対する相対値として扱う（`effectiveBlock(_:textureWidth:)`）。
    /// 顔メッシュ経路（`FaceMeshMosaicRenderer`）が固定 256px キャンバス基準へ換算して
    /// 解像度非依存になっているのと同じ流儀。
    public static let referenceFrameWidth: Float = 720

    /// テクスチャ幅に応じた実効ブロックサイズ（px）。
    ///
    /// 基準幅より大きいテクスチャでは幅に比例して粗くし、
    /// 「基準幅で見たときの見え方」を解像度に依らず再現する。
    ///
    /// **基準幅以下では縮めない**（下限 1 倍）。プレビューは基準幅以下の素材を縮小しないため
    /// もともとプレビューと書き出しは一致しており、そこで比例縮小を掛けると
    /// 両方が同じだけ細かくなる＝匿名化が弱くなるだけで、一致には何も寄与しないため。
    public static func effectiveBlock(_ block: Float, textureWidth: Int) -> Float {
        let scale = max(1, Float(textureWidth) / referenceFrameWidth)
        return max(block * scale, 2)
    }
}
#endif
