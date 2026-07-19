import UIKit
import MosaicCore

/// ライブプレビュー 1 フレーム分の検出結果。
/// `bridgedByFlow == true` は「検出器は全滅し、オプティカルフロー追跡が前回の顔位置を
/// 前進させて補完した」フレーム。呼び出し側（MosaicEditorModel）はこれを
/// detectionCache（エクスポートが参照する実検出の記録）に入れず、検出率バッジにも
/// 算入しない、という区別のために必要。
public struct LiveDetectionResult {
    public var faces: [FaceLandmarkSet]
    public var bridgedByFlow: Bool

    public init(faces: [FaceLandmarkSet], bridgedByFlow: Bool = false) {
        self.faces = faces
        self.bridgedByFlow = bridgedByFlow
    }
}

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

    /// ライブプレビュー用のステートフル検出。IMAGE モード検出に加えて、前フレームの
    /// 顔位置周辺の ROI 再検出・オプティカルフロー橋渡しで横顔・急な頭部回転を追跡する。
    /// `t` はメディア時刻（秒）。巻き戻り・大ジャンプ（シーク）を検知して追跡状態を
    /// 自動リセットするので、VIDEO モードと違い時系列の単調増加を要求しない。
    func liveLandmarks(in image: UIImage, atMediaSeconds t: Double) -> LiveDetectionResult

    /// シーク・動画切替時に呼び、ライブ追跡状態（track / flow）を明示的に破棄する。
    func resetLiveTracking()
}

extension FaceLandmarking {
    // 既存実装から自動的に多数検出へのデフォルト実装を提供する。
    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] {
        landmarks(in: image).map { [$0] } ?? []
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        landmarks(in: image, timestampMs: timestampMs).map { [$0] } ?? []
    }

    /// デフォルトは既存の IMAGE 検出への素通し（追跡なし）。
    /// NullFaceLandmarker やテストフェイクを壊さないための後方互換実装。
    public func liveLandmarks(in image: UIImage, atMediaSeconds t: Double) -> LiveDetectionResult {
        LiveDetectionResult(faces: allLandmarks(in: image))
    }

    public func resetLiveTracking() {}
}

/// MediaPipe が利用できない環境（Simulator・プレビュー）用のスタブ。
public struct NullFaceLandmarker: FaceLandmarking {
    public init() {}
    public func landmarks(in image: UIImage) -> FaceLandmarkSet? { nil }
    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? { nil }
    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] { [] }
    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] { [] }
}
