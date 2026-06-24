import UIKit
import MosaicCore

/// 顔ランドマーク検出器の抽象。UI / ViewModel は MediaPipe に直接依存しない。
public protocol FaceLandmarking {
    /// 静止画像で1件検出する（後方互換用）。
    func landmarks(in image: UIImage) -> FaceLandmarkSet?

    /// 動画フレームで1件検出する（後方互換用）。
    func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet?

    /// 静止画像で複数件検出する。
    func allLandmarks(in image: UIImage) -> [FaceLandmarkSet]

    /// 動画フレームで複数件検出する。
    func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet]
}

extension FaceLandmarking {
    // 既存実装から自動的に多数検出へのデフォルト実装を提供する。
    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] {
        landmarks(in: image).map { [$0] } ?? []
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        landmarks(in: image, timestampMs: timestampMs).map { [$0] } ?? []
    }
}

/// MediaPipe が利用できない環境（Simulator・プレビュー）用のスタブ。
public struct NullFaceLandmarker: FaceLandmarking {
    public init() {}
    public func landmarks(in image: UIImage) -> FaceLandmarkSet? { nil }
    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? { nil }
    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] { [] }
    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] { [] }
}
