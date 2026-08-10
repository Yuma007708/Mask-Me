import CoreGraphics
import Foundation

/// 傾いた矩形をつまんで動かす／大きさを変える／回すときの幾何。
///
/// View に直接書くと確かめようがない（`XCUITest` でドラッグしても、ずれたのが
/// 計算なのか指の座標なのか切り分けられない）。ここに出して `swift test` で固定する。
///
/// **入力は画面座標のドラッグ量**（`DragGesture` の `translation`）。
/// 回転を掛けたビューの中でジェスチャを取ると座標系が一緒に回るので、
/// 呼び出し側は `coordinateSpace: .global` で取ること。
public enum RectangleHandleMath {
    /// 潰しきらない最小の一辺（画面 pt）。これ以下にすると、掴む場所ごと消えて
    /// 元へ戻せなくなる。
    public static let minimumSide: CGFloat = 24

    /// 画面上のドラッグ量を、**傾いた矩形のローカル軸に沿った量**へ直す。
    ///
    /// 45° 傾いた矩形の右下つまみを画面の真下へ引いたとき、その矩形にとっては
    /// 「右下方向へ半分・左下方向へ半分」の意味になる。この変換を挟まないと、
    /// 傾けた矩形のリサイズが指と別の方向へ伸びる。
    public static func localDelta(_ translation: CGSize, angle: Double) -> CGSize {
        guard angle.isFinite, angle != 0 else { return translation }
        let cosine = CGFloat(cos(-angle))
        let sine = CGFloat(sin(-angle))
        return CGSize(width: translation.width * cosine - translation.height * sine,
                      height: translation.width * sine + translation.height * cosine)
    }

    /// 右下つまみのドラッグ結果。**中心を固定**して大きさだけ変える。
    ///
    /// 角を固定して反対の角を動かす方が直感的に見えるが、回転が入ると
    /// 「固定したはずの角」が回転中心（＝矩形の中心）まわりに動いて見える。
    /// 中心固定なら、傾いていても指の動きと大きさの変化が一対一で対応する。
    public static func resizedAroundCenter(_ rect: CGRect, byLocal delta: CGSize) -> CGRect {
        guard rect.width.isFinite, rect.height.isFinite,
              delta.width.isFinite, delta.height.isFinite else { return rect }
        // 中心固定なので、片側へ delta 動かすと幅は 2 倍ぶん変わる。
        let width = max(rect.width + delta.width * 2, minimumSide)
        let height = max(rect.height + delta.height * 2, minimumSide)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    /// 中心から指へ向かう角度（ラジアン）。回転つまみの追従に使う。
    ///
    /// 中心と指が重なったときは 0 ではなく nil。0 を返すと、指が中心を通過した
    /// 瞬間に矩形が水平へ跳ねる。
    public static func angle(from center: CGPoint, to point: CGPoint) -> Double? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 1 else { return nil }
        return atan2(Double(dy), Double(dx))
    }

    /// 回転つまみを掴んでから今までの回転量を、元の角度へ足した結果。
    ///
    /// 指の位置そのものを角度にすると、掴んだ瞬間に矩形がつまみの方向へ跳ねる
    /// （つまみは矩形の下端にあるので、掴むだけで 90° 回る）。**掴んだ時点との差**を
    /// 足すことで、指を置いた瞬間は動かない。
    public static func rotated(from startAngle: Double, by currentAngle: Double,
                               initial: Double) -> Double {
        guard startAngle.isFinite, currentAngle.isFinite, initial.isFinite else { return initial }
        return ObjectMask.normalizedAngle(initial + (currentAngle - startAngle))
    }
}
