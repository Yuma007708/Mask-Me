import UIKit
import Vision

/// Apple Vision (`VNDetectFaceRectanglesRequest`) を薄くラップした `FaceBBoxDetecting` 実装。
///
/// 戻り値は左上原点・`[0, 1]` 正規化座標系（プロトコル契約）。MediaPipe が苦手なケース
/// （横顔・暗所・小顔）を補うために、`MediaPipeFaceLandmarkerAdapter.augmentWithBBoxDetector` から
/// 呼ばれる。
///
/// iOS Simulator の Apple Vision は arm64 macOS 上で顔検出が機能しないことが確認されている
/// （5本×4 orientation で 0 検出）。実機 (Apple Neural Engine 有) でのみ意味のある結果を返す。
struct AppleVisionFaceDetector: FaceBBoxDetecting {
    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect] {
        guard let cg = image.cgImage else { return [] }
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        guard let observations = req.results, !observations.isEmpty else { return [] }
        return observations.map { obs in
            // Vision の boundingBox は左下原点・[0,1] 正規化なので、左上原点へ y を反転する。
            let bb = obs.boundingBox
            return CGRect(x: bb.minX, y: 1.0 - bb.maxY, width: bb.width, height: bb.height)
        }
    }
}
