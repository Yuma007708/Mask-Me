import UIKit
import MosaicCore

/// 検出された顔1件を表すモデル。ユーザーによる選択状態と動画での検出率を持つ。
public struct FaceTarget: Identifiable {
    public let id: UUID
    public let landmarks: FaceLandmarkSet
    public let thumbnail: UIImage
    public var isSelected: Bool
    /// 動画のみ: 事前スキャンで算出した検出率（0-100%）。スキャン前は nil。
    public var detectionRate: Double?

    public init(id: UUID, landmarks: FaceLandmarkSet, thumbnail: UIImage, isSelected: Bool, detectionRate: Double? = nil) {
        self.id = id; self.landmarks = landmarks; self.thumbnail = thumbnail
        self.isSelected = isSelected; self.detectionRate = detectionRate
    }
}
