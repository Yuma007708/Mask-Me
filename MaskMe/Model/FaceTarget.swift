import UIKit
import MosaicCore

/// 検出された顔1件を表すモデル。ユーザーによる選択状態と動画での検出率を持つ。
public struct FaceTarget: Identifiable {
    public let id: UUID
    /// 顔の最新既知位置。ライブ検出でマッチするたびに更新される（追加時の初期位置の
    /// まま固定すると、移動・再入した顔と重心マッチングが永久に不成立になる）。
    public var landmarks: FaceLandmarkSet
    public let thumbnail: UIImage
    public var isSelected: Bool
    /// 動画のみ: 事前スキャンで算出した検出率（0-100%）。スキャン前は nil。
    public var detectionRate: Double?
    /// この顔が検出された素材の識別子。`selectedLandmarks` の重心マッチングを
    /// 同一素材の顔に限定するために使う（別素材の似た位置の顔との誤マッチ防止）。
    /// nil は素材不問（写真モード・テスト直注入・素材ID導入前の経路）で、
    /// 従来どおり全素材の顔と照合される。
    public var sourceID: UUID?

    public init(id: UUID, landmarks: FaceLandmarkSet, thumbnail: UIImage, isSelected: Bool,
                detectionRate: Double? = nil, sourceID: UUID? = nil) {
        self.id = id; self.landmarks = landmarks; self.thumbnail = thumbnail
        self.isSelected = isSelected; self.detectionRate = detectionRate; self.sourceID = sourceID
    }
}
