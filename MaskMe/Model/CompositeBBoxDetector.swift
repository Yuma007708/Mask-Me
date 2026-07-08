import UIKit
import CoreGraphics

/// 複数の `FaceBBoxDetecting` を並走させて結果を union する集約検出器。
///
/// 子検出器の検出結果を全て集め、IoU > `iouThreshold` で重なる bbox を「同じ顔」とみなして
/// 1 つにまとめる（先勝ち、後発の重複は捨てる）。配列順は最初の検出器 → 次の検出器 → ... となる。
///
/// 計算コストは含まれる検出器の合計（並列化はせず逐次実行）。最高検出率を狙うときに使う。
struct CompositeBBoxDetector: FaceBBoxDetecting {
    let detectors: [FaceBBoxDetecting]
    let iouThreshold: CGFloat

    init(_ detectors: [FaceBBoxDetecting], iouThreshold: CGFloat = 0.3) {
        self.detectors = detectors
        self.iouThreshold = iouThreshold
    }

    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect] {
        var accumulated: [CGRect] = []
        for detector in detectors {
            for box in detector.detectFaceBoundingBoxes(in: image) {
                if !accumulated.contains(where: { iou($0, box) > iouThreshold }) {
                    accumulated.append(box)
                }
            }
        }
        return accumulated
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
