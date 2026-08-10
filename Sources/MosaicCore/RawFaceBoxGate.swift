import CoreGraphics
import Foundation

/// 補助 bbox 検出器（BlazeFace / YuNet）が返す**生の矩形**を「明らかに顔でない形状」で
/// 前段ガードする純粋述語。ROI 再検出に回す前に torso / 首・胸元・肩・髪などを弾き、
/// 再検出のコストも節約する。
///
/// ここでの不変条件は **「素材の向きで判定が変わらないこと」** の一点に尽きる。
/// 入力の矩形は正規化座標なので、大きさも縦横比も画像のアスペクト比がそのまま乗る。
/// 同じ大きさ・同じ形の顔が 1280x720 と 720x1280 で別の値になり、閾値を正規化のまま
/// 持つと**素材の向きだけで実顔が落ちる**。よって両方ともピクセル換算で判定する。
///
/// 実際に踏んだ事故:
/// - 縦横比を正規化比で見ていた頃、720x1280 縦動画では正方形 bbox が w/h=1.78、
///   1280x674 横動画では同じ bbox が 0.53 になり、旧ガード 0.6...1.4 の外側へ出ていた。
/// - 大きさを正規化値（短辺 6%）で見ていた頃、1280x720 の会議室素材
///   （`probe_crowd_02`）の顔が正規化 w=0.038〜0.043 で**幅だけ**が 6% を割り、
///   生 bbox 18 件が全滅した。ピクセルでは 49〜55px あり crop すればメッシュも取れる
///   本物の顔で、6 人写った動画にモザイクが 1 つも掛からない状態だった。
public enum RawFaceBoxGate {
    /// 顔 bbox の最小辺（画像の**短辺**に対する比）。短辺基準にすることで、同じ大きさの顔が
    /// 素材の向きに関わらず同じ判定になる。
    public static let minSideRatioOfShortSide: CGFloat = 0.06

    /// 生 bbox の**ピクセル換算** w/h の許容レンジ。
    /// 実測 180 個の生 bbox は 0.53〜1.06（YuNet は 0.77 前後、MediaPipe FaceDetector は
    /// 正方形の 1.00）に収まったので、余裕を見て 0.5...1.6 を採る。
    public static let pixelWidthOverHeightRange: ClosedRange<CGFloat> = 0.5...1.6

    /// `box`（正規化座標）が ROI 再検出に回す価値のある形状かどうか。
    /// - Parameters:
    ///   - box: 補助検出器が返した正規化矩形。
    ///   - imageSize: 元画像のピクセルサイズ。
    public static func accepts(_ box: CGRect, imageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0 else { return false }
        guard box.width > 0, box.height > 0 else { return false }

        let widthPixels = box.width * imageSize.width
        let heightPixels = box.height * imageSize.height
        let minPixelSide = min(imageSize.width, imageSize.height) * minSideRatioOfShortSide
        guard widthPixels >= minPixelSide, heightPixels >= minPixelSide else { return false }

        return pixelWidthOverHeightRange.contains(widthPixels / heightPixels)
    }
}
