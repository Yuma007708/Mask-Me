import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// Flat "background only" mosaic. Kept in its own file (same module, so it can
/// still touch the renderer's internal members) to keep `MosaicRenderer.swift`
/// within the file/type length limits.
extension MosaicRenderer {
    /// Applies a flat (axis-aligned) mosaic to the regions marked by `mask`
    /// (`0` = keep original, `255` = mosaic). The mask is sampled in normalized
    /// UV, so it need not match the input resolution — a lower-res person /
    /// background mask from Vision works directly. The subject (mask `0`) stays
    /// sharp. Independent of the face block size (`block` is passed explicitly).
    @discardableResult
    public func renderBackground(
        input: MTLTexture,
        into output: MTLTexture,
        mask: MaskBuffer,
        block: Float,
        waitForCompletion: Bool = false
    ) -> Bool {
        guard mask.width > 0, mask.height > 0,
              mask.bytes.count >= mask.width * mask.height,
              let maskTexture = reuseOrMakeR8Texture(
                  &backgroundMaskTexture, width: mask.width, height: mask.height
              ) else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return false
        }
        mask.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            maskTexture.replace(
                region: MTLRegionMake2D(0, 0, mask.width, mask.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: mask.width
            )
        }

        var kernelParams = params
        kernelParams.block = block
        kernelParams.edgeSoftness = 0.5
        kernelParams.rotation = 0
        kernelParams.centerX = Float(input.width) / 2
        kernelParams.centerY = Float(input.height) / 2
        kernelParams.width = UInt32(input.width)
        kernelParams.height = UInt32(input.height)
        // 顔パスと同じ compute カーネル発行経路を共有する。
        dispatchMosaicKernel(
            input: input, output: output, mask: maskTexture,
            params: kernelParams, waitForCompletion: waitForCompletion
        )
        return true
    }
}
#endif
