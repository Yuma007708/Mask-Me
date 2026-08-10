import CoreGraphics
import Foundation

/// クロップの縦横比の固定モード。
///
/// **ピクセル比と正規化比は別物。** `CropRect.rect` は出力枠（ピクセル寸法
/// `W×H`）に対する正規化矩形なので、正規化空間は `W:H` が 1:1 でない限り
/// 異方性を持つ。見た目の比率 `r`（ピクセル `w:h`）を正規化矩形へ落とすには
///
/// ```
/// w_n / h_n = r * H / W
/// ```
///
/// を必ず通す（`CropHandleMath` のドラッグ・比率選び直しはすべてこの 1 本の式で
/// 「見た目どおりの比率」を実現している）。ここを素の `r` のまま正規化矩形へ
/// 適用すると、出力が正方形でない限り見た目の比率がずれる。
public enum CropAspectLock: String, CaseIterable, Sendable, Codable {
    /// 比率固定なし。ハンドルは各辺・各角を独立に動かせる。
    case free
    /// 素材（出力枠）そのものの比率。
    case original
    case square
    case landscape16x9
    case portrait9x16
    case landscape4x3
    case portrait3x4

    /// 出力枠のピクセル比に対する目標 `w/h`。
    ///
    /// - `free` は制約なしを表す `nil`。
    /// - `original` は `frame.width / frame.height`（`frame.height <= 0` なら `nil` へ倒す）。
    /// - 他は名前どおりの定数比。
    public func pixelRatio(inFrame frame: CGSize) -> CGFloat? {
        switch self {
        case .free:
            return nil
        case .original:
            guard frame.height > 0, frame.width.isFinite, frame.height.isFinite else { return nil }
            return frame.width / frame.height
        case .square:
            return 1
        case .landscape16x9:
            return 16.0 / 9.0
        case .portrait9x16:
            return 9.0 / 16.0
        case .landscape4x3:
            return 4.0 / 3.0
        case .portrait3x4:
            return 3.0 / 4.0
        }
    }
}
