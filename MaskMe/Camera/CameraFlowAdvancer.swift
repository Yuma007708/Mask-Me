import UIKit
import MosaicCore

// OpticalFlowTracker / MMGrayFrame はブリッジングヘッダ
// （MaskMe-Bridging-Header.h → OpticalFlowKit）経由で見える。

/// 顔ごとの `OpticalFlowTracker` を束ねる薄いブリッジ。毎フレームの
/// 縮小グレー化（`MMGrayFrame`）は呼び出し側が 1 フレーム 1 回だけ作り、
/// 全トラッカーで共有する（3 顔でグレー化 3 回 → 1 回）。
///
/// OpenCV（OpticalFlowKit）への依存をこの層に閉じ込め、前進ロジック本体は
/// `MosaicCore.LiveFacePropagator`（純 Swift・swift test 可能）が持つ。
///
/// スレッド規約: 全メソッドを映像キャプチャキュー（videoQueue）専有で呼ぶこと。
final class CameraFlowAdvancer {
    /// 前進層の縮小長辺（px）。検出縮小幅と同じオーダーに揃えたコスト上限。
    static let maxLongSide = 640.0

    private var trackers: [OpticalFlowTracker] = []

    var isEmpty: Bool { trackers.isEmpty }

    /// 全トラッカーを現フレームへ前進させ、顔ごとの対応点ペアを返す。
    /// 添字は直近の `reseed(frame:faceBoxes:)` の並びに一致する。
    /// フロー品質ゲート落ちの顔は `nil`（呼び出し側が外挿へ切り替える）。
    func advance(frame: MMGrayFrame) -> [LiveFacePropagator.FlowObservation?] {
        trackers.map { tracker in
            guard let match = tracker.advance(grayFrame: frame) else { return nil }
            return LiveFacePropagator.FlowObservation(
                from: match.previousPoints.map(\.cgPointValue),
                to: match.currentPoints.map(\.cgPointValue))
        }
    }

    /// 検出合流後に呼ぶ。補正後の顔 bbox（正規化）で全トラッカーを蒔き直す。
    func reseed(frame: MMGrayFrame, faceBoxes: [CGRect]) {
        trackers = faceBoxes.map { box in
            let tracker = OpticalFlowTracker()
            _ = tracker.seed(grayFrame: frame, faceBox: box)
            return tracker
        }
    }

    func reset() {
        trackers = []
    }
}
