import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore
import UIKit

/// 範囲指定で見つけた顔（シード）を起点に、素材の前後方向へ ROI を絞って走査するための
/// **フレーム供給層**。
///
/// `RegionSeedTracker`（`MosaicCore`。フレームの読み方も検出器も知らない純ロジック）が
/// `nextStep()` で「次はこの時刻のこの矩形を見て」を決め、ここでは実際に
///
/// 1. その素材内時刻のフレームを取り出し（`AVAssetImageGenerator`。実測時刻が
///    返る＝要求時刻とはずれうる）、
/// 2. ROI でクロップして顔検出器へ掛け、
/// 3. 見つかった候補を `remapped(into:)` で素材フレーム全体の正規化座標へ戻す
///
/// という配線だけを担う。呼び出し側（`MosaicEditorModel+RegionSeeding`）が
/// `tracker.accept(candidates:similarities:)` へ結果を渡し、次のステップを回す。
enum RegionFaceSeeder {
    /// 1 ステップぶんの検出結果。
    struct StepResult {
        /// 素材フレーム基準へ戻し済みの候補（`RegionSeedTracker.accept` へそのまま渡せる）。
        let candidates: [FaceLandmarkSet]
        /// クロップに使ったのと同じ ROI（`remapped(into:)` に使ったのと同一の矩形）。
        let roi: CGRect
        /// 実際にフレームを取り出せた**実測**素材内時刻（要求時刻ではない）。
        let sourceTime: Double
        /// 連続ミス3回目の全画面フォールバックだったか（`RegionSeedTracker.Step.isFullFrame`）。
        /// **書き戻しの分岐には使わない**（`recordRegionSeedFinding` は候補が空なら理由に
        /// 関わらず一切書かないため）。ここに残しているのはテストが「全画面フォールバックの
        /// ステップまで到達できたか」を確認・アサートするための診断用途のみ。
        let isFullFrame: Bool
        /// 検出に使った素材フレーム全体。署名計測（`FaceSignatureProvider`）と
        /// フォールバック `FaceTarget` のサムネ生成に使う。
        let frame: UIImage
    }

    /// `RegionSeedTracker.nextStep()` が返した 1 ステップぶんのフレームを取り出し検出する。
    ///
    /// フレームそのものが取り出せなかった（デコード失敗・区間外）ときは `nil` を返す。
    /// 呼び出し側はこれを「候補ゼロ」と同じ扱いにはせず、`tracker.accept(candidates: [], ...)`
    /// を呼ぶだけに留めること（`nil` はフレーム取得の失敗であって「顔なしと確認できた
    /// フレーム」ではない）。
    ///
    /// **呼び出し側の責務**: `autoreleasepool` の中から呼ぶこと。プリスキャン・追跡と同じ
    /// 既知事故（溜めるとハードウェアデコーダがメモリ圧で失敗し途中から全滅する）が
    /// ここにも当てはまる。この関数自体は同期処理なので、呼び出し側の
    /// `autoreleasepool { }` に包めばそのまま効く。
    static func detect(
        step: RegionSeedTracker.Step,
        generator: AVAssetImageGenerator,
        scanner: FaceLandmarking
    ) -> StepResult? {
        var actualTime = CMTime.zero
        guard let cg = try? generator.copyCGImage(
            at: CMTime(seconds: step.sourceTime, preferredTimescale: 600),
            actualTime: &actualTime
        ) else { return nil }
        let seconds = actualTime.isNumeric ? actualTime.seconds : step.sourceTime
        guard seconds.isFinite else { return nil }
        let frame = UIImage(cgImage: cg)

        let pixW = CGFloat(cg.width)
        let pixH = CGFloat(cg.height)
        let pixelRect = CGRect(
            x: step.roi.origin.x * pixW,
            y: step.roi.origin.y * pixH,
            width: step.roi.width * pixW,
            height: step.roi.height * pixH
        )
        guard let cropped = cg.cropping(to: pixelRect) else {
            return StepResult(candidates: [], roi: step.roi, sourceTime: seconds,
                              isFullFrame: step.isFullFrame, frame: frame)
        }
        let croppedImage = UIImage(cgImage: cropped, scale: frame.scale, orientation: frame.imageOrientation)
        let found = scanner.allLandmarks(in: croppedImage)
        // クロップに使ったのと**同じ** ROI で戻す（要求元 `normalizedRect` ではなく
        // `step.roi`。全画面フォールバックでは `step.roi` が単位矩形なので恒等）。
        let candidates = found.map { $0.remapped(into: step.roi) }
        return StepResult(candidates: candidates, roi: step.roi, sourceTime: seconds,
                          isFullFrame: step.isFullFrame, frame: frame)
    }
}
