import AVFoundation
import UIKit

/// フリーズフレーム挿入のための **1 コマ抽出**。
///
/// `MosaicEditorModel+Freeze.swift` から呼ばれる。ここを別ファイルに切り出したのは、
/// AVFoundation まわりの決め事（tolerance / trackTransform）を 1 箇所へ集約し、
/// 呼び出し側で条件を書き換えられないようにするため。
///
/// **合成フレームではなく素材（`AVAsset`）を直接読むこと。** 合成フレームは
/// `AVVideoComposition` が比率フィット・向き補正を既に掛けた結果であり、
/// その上から `appliesPreferredTrackTransform` を再度適用すると二重適用になる
/// （縦動画が二重に回転して真横に倒れる）。
enum FreezeFrameFactory {
    enum ExtractionError: Error {
        /// 指定時刻のコマを取り出せなかった（壊れた素材・範囲外の時刻など）。
        case extractionFailed
    }

    /// 素材 `asset` の**素材内時刻** `sourceTime` の 1 コマを取り出す。
    ///
    /// - `requestedTimeToleranceBefore` / `After` は必ず `.zero` にする。
    ///   既存の `MosaicEditorModel.makeFrameGenerator` は 0.1 秒の許容を持つが、
    ///   それを流用すると「画面に見えているのと違うコマ」が凍ってしまう
    ///   （フリーズフレームの存在意義そのものを壊す）。
    /// - `appliesPreferredTrackTransform = true` にする。既存の検出経路
    ///   （`MosaicEditorModel.makeFrameGenerator` / `seedVideoDetection`）と同じ座標系にするため
    ///   ——検出キャッシュの顔座標はこの座標系（デバイス回転を織り込んだ「素材フレーム基準」）
    ///   で保存されている。
    /// - 返す `UIImage` は常に `.up` 向きになる（`copyCGImage` が回転をピクセルへ
    ///   焼き込んで返すため。`UIImage(cgImage:)` の既定 orientation は `.up`）。
    ///   **クリップの `orientation`（ユーザーの回転・反転操作）はここでは一切適用しない**
    ///   ——それは合成時にだけ掛かるレイヤーであり、ピクセルへ焼き込むと
    ///   合成時にもう一度掛かって二重適用になる。呼び出し側が新規クリップの
    ///   `orientation` へ元クリップの値をそのままコピーすること。
    static func extractFrame(from asset: AVAsset, atSourceTime sourceTime: Double) throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            throw ExtractionError.extractionFailed
        }
        return UIImage(cgImage: cgImage)
    }
}
