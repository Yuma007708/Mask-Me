import CoreGraphics

/// 検出した顔と、既知の顔（人物）を**重心の近さ**で対応づける純関数。
///
/// 描画の絞り込み（`MosaicEditorModel.selecting`）と、プレビュー上のタップ選択が
/// **同じ判定**を使うための置き場である。別々に書くと「枠が出ているのに
/// タップしても選べない顔」「タップでは選べるのにモザイクが乗らない顔」という、
/// 画面の上では説明のつかない食い違いが生まれる。
///
/// **座標系は素材フレーム基準**（検出したときの座標）。合成フレームへ写した後の顔と
/// 比べてはいけない。レターボックスの実測ずれは最大 0.175 あり、閾値 `spatialTolerance`
/// は素材座標で調整されてきた値なので、写した後の座標に当てると意味が変わる
/// （`MosaicEditorModel.displayFaces(at:matching:)` の doc に経緯がある）。
public enum FaceCentroidMatching {
    /// 同じ顔とみなす重心距離の上限（正規化座標）。
    ///
    /// **この値を 2 箇所に書かないこと。** 描画側とタップ選択側で食い違うと、
    /// 見えているものと触れるものがずれる。
    public static let spatialTolerance: CGFloat = 0.5

    /// 顔の重心。
    public static func centroid(of face: FaceLandmarkSet) -> CGPoint {
        SelectedFaceTracker.centroid(of: face)
    }

    /// `face` に最も近い重心の添字。許容の外しか無ければ nil。
    ///
    /// **「許容内に 1 つでもあるか」を知りたいだけなら `!= nil` で判定できる**
    /// （最近傍が許容外なら、他はもっと遠い）。
    public static func nearestIndex(for face: FaceLandmarkSet,
                                    in centroids: [CGPoint],
                                    tolerance: CGFloat = spatialTolerance) -> Int? {
        nearestIndex(to: centroid(of: face), in: centroids, tolerance: tolerance)
    }

    /// `point` に最も近い重心の添字。許容の外しか無ければ nil。
    ///
    /// 距離が完全に同じ候補が複数あるときは**添字の小さい方**を返す
    /// （`min(by:)` は等しいとき先行要素を保つ）。同点で結果が揺れると、
    /// 同じ顔をタップしたのに毎回別の人物が選ばれる。
    public static func nearestIndex(to point: CGPoint,
                                    in centroids: [CGPoint],
                                    tolerance: CGFloat = spatialTolerance) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, centroid) in centroids.enumerated() {
            let distance = hypot(centroid.x - point.x, centroid.y - point.y)
            guard distance < tolerance else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }
}
