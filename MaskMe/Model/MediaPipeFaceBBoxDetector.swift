import UIKit

/// MediaPipe Tasks Vision の `FaceDetector` を `FaceBBoxDetecting` に適合させたラッパ。
///
/// 478 ランドマークの FaceLandmarker とは別系統の **bbox 専用** 検出器（BlazeFace ベース）。
/// 横顔・小顔・遠い顔を Apple Vision より広く拾えることを期待して、`MediaPipeFaceLandmarkerAdapter`
/// の補助検出器として使う。検出された bbox は ROI として MP IMG モードに再投入され、最終的に
/// MP の 478 メッシュとしてモザイクが描かれる。
///
/// モデル `face_detector.tflite`（BlazeFace short range, 約 200KB, Apache 2.0）が Bundle に
/// 含まれていればロードする。MediaPipe Pod 自体が無い環境（CI、Simulator 一部）では `nil`。
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

struct MediaPipeFaceBBoxDetector: FaceBBoxDetecting {
    private let detector: FaceDetector?

    init(modelName: String = "face_detector") {
        guard let path = Bundle.main.path(forResource: modelName, ofType: "tflite") else {
            self.detector = nil
            return
        }
        let options = FaceDetectorOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .image
        // 信頼度しきい値は MediaPipe デフォルト (0.5) のまま。低くしすぎると誤検出が増える。
        self.detector = try? FaceDetector(options: options)
    }

    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect] {
        guard let detector,
              let mpImage = try? MPImage(uiImage: image),
              let result = try? detector.detect(image: mpImage) else {
            return []
        }
        // 検出 bbox はピクセル座標で返ってくる。左上原点・[0, 1] 正規化に変換。
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return [] }
        return result.detections.map { det in
            let bb = det.boundingBox
            return CGRect(
                x: bb.minX / w,
                y: bb.minY / h,
                width: bb.width / w,
                height: bb.height / h
            )
        }
    }
}
#else
struct MediaPipeFaceBBoxDetector: FaceBBoxDetecting {
    init(modelName: String = "face_detector") {}
    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect] { [] }
}
#endif
