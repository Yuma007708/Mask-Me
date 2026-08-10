import CoreGraphics
import Foundation

/// 478 点メッシュから、SFace が整列に使う 5 点を取り出す。
///
/// SFace は ArcFace 系の 5 点相似変換で 112×112 に整列した顔を前提に学習されている。
/// 与える点の**順序**が違うと変換が別物になり、同一人物の類似度が静かに落ちる
/// （エラーにはならないので気付けない）。順序は OpenCV `FaceRecognizerSF.alignCrop`
/// が読む並び＝ArcFace の正準テンプレートと同じ:
///
/// 1. 画面の**左側**に写る目（＝本人の右目）
/// 2. 画面の**右側**に写る目（＝本人の左目）
/// 3. 鼻先
/// 4. 画面の**左側**の口角
/// 5. 画面の**右側**の口角
///
/// 指標番号は `FaceMeshTopology.frontalUV`（正準顔の UV）で左右を実際に確認した:
/// 33 u=0.213 / 133 u=0.380（画面左の目）、263 u=0.787 / 362 u=0.620（画面右の目）、
/// 1 u=0.500 v=0.532（鼻先）、61 u=0.341・291 u=0.659（口角）。
///
/// 目の中心は**外端と内端の中点**で作る。虹彩点（468..477）を使わないのは、
/// どちらの虹彩がどちらの目かがモデル世代で入れ替わりうるうえ、`frontalUV` は
/// 468 頂点しか持たず**左右を検算できない**ため。中点なら検算済みの 4 点だけで済む。
public enum FaceAlignmentPoints {
    /// 画面左の目の外端・内端。
    static let leftEyeIndices = (outer: 33, inner: 133)
    /// 画面右の目の外端・内端。
    static let rightEyeIndices = (outer: 263, inner: 362)
    static let noseTipIndex = 1
    /// 画面左・右の口角。
    static let mouthCornerIndices = (left: 61, right: 291)

    /// 整列に要る最大の指標番号。これ未満の点数のメッシュは扱えない。
    static let requiredPointCount = 292

    /// 正規化座標（0〜1）の 5 点を上記の順で返す。
    /// メッシュが足りない（部分メッシュ・矩形由来の顔）場合は nil。
    public static func extract(from set: FaceLandmarkSet) -> [CGPoint]? {
        guard set.points.count >= requiredPointCount else { return nil }
        let points = set.points
        func midpoint(_ a: Int, _ b: Int) -> CGPoint {
            CGPoint(x: CGFloat(points[a].x + points[b].x) / 2,
                    y: CGFloat(points[a].y + points[b].y) / 2)
        }
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(points[i].x), y: CGFloat(points[i].y))
        }
        return [
            midpoint(leftEyeIndices.outer, leftEyeIndices.inner),
            midpoint(rightEyeIndices.outer, rightEyeIndices.inner),
            point(noseTipIndex),
            point(mouthCornerIndices.left),
            point(mouthCornerIndices.right)
        ]
    }

    /// `extract` の結果を画素座標へ直したもの（埋め込み器へ渡す形）。
    public static func extract(from set: FaceLandmarkSet, in size: CGSize) -> [CGPoint]? {
        extract(from: set)?.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }
}
