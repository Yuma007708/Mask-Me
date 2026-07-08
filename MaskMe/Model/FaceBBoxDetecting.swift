import UIKit

/// 顔の外接矩形（bounding box）だけを返す検出器の共通インターフェース。
///
/// MediaPipe FaceLandmarker の 478 メッシュ取得とは別系統で「画像内のどこに顔があるか」を
/// 探す役割。`MediaPipeFaceLandmarkerAdapter.augmentWithBBoxDetector` が、ここで見つかった
/// bbox のうち MP の検出と重ならないものを ROI として MP IMG モードに再投入し、メッシュを得る。
///
/// 戻り値の座標系は **左上原点・`[0, 1]` 正規化** に統一する（MediaPipe の `FaceLandmark` と同じ）。
/// Apple Vision のように左下原点でも、Core ML 出力のようにピクセル座標でも、実装側で必ず変換すること。
public protocol FaceBBoxDetecting {
    /// 画像から顔 bbox の配列を返す。検出がなければ空配列。
    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect]
}
