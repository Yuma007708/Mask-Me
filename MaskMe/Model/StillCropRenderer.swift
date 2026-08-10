import CoreGraphics
import MosaicCore
import UIKit

/// 写真モードのクロップをピクセル単位で実際に切り出す。
///
/// 動画のクロップは AVFoundation 段（Metal より前）で効くため、`sourceTexture` に届く
/// 時点で既に切られている。写真にはその段が無いので、`renderPreview()` が描くのは
/// **常に全画素**（`MosaicEditorModel+Crop.swift` 型 doc 参照）。クロップは表示直前・
/// 保存直前でこの関数を通して初めて掛かる。
///
/// **ピクセル矩形の決定は `CropRect.snappedRect(inFrame:)` をそのまま使う**
/// （動画の書き出し経路 `RenderPlacement.make` と同じ関数）。偶数スナップは静止画の
/// 書き出しには本質的に不要だが、経路を割ると「動画側の丸めだけ直って写真側は別の
/// 場所が切れる」という食い違いが起きるので、あえて同じ関数を共有する
/// （`test_写真のクロップ寸法が動画と同じ関数から出る` が番人）。
public enum StillCropRenderer {
    /// `image` を `crop` の指す部分矩形へ切り出す。`crop.isFull` なら `image` をそのまま返す。
    ///
    /// `image.cgImage` が取れない（起こり得ないはずだが `UIImage` は理論上 nil を許す）
    /// ときも `image` をそのまま返す——クロップに失敗して全画素が漏れる方向は「モザイクが
    /// 減る」側にはならない（切れなかっただけで、掛けたモザイクはそのまま残っている）ので、
    /// ここで throw せずクランプする `CropRect` の規約に揃える。
    public static func cropped(_ image: UIImage, crop: CropRect) -> UIImage {
        guard !crop.isFull, let cgImage = image.cgImage else { return image }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }

        let snapped = crop.snappedRect(inFrame: pixelSize)
        guard let pixelRect = clampedIntegerRect(snapped, within: pixelSize),
              let cropped = cgImage.cropping(to: pixelRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// `CGImage.cropping(to:)` に渡す前に、丸め誤差でピクセル境界をはみ出した矩形を
    /// 画像の実寸へ収める。`CropRect` 自身は `[0,1]` 内へ正規化済みだが、
    /// `snappedRect` の `.rounded()` / 偶数スナップが端数を生むことがあるため、
    /// ここでもう一段クランプする。
    private static func clampedIntegerRect(_ rect: CGRect, within bounds: CGSize) -> CGRect? {
        let minX = max(0, min(rect.minX.rounded(), bounds.width))
        let minY = max(0, min(rect.minY.rounded(), bounds.height))
        let maxX = max(minX, min(rect.maxX.rounded(), bounds.width))
        let maxY = max(minY, min(rect.maxY.rounded(), bounds.height))
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}
