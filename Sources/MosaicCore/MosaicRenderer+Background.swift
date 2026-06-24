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
              let maskTexture = reuseOrMakeBackgroundMaskTexture(width: mask.width, height: mask.height) else {
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

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return false
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        withUnsafeBytes(of: &kernelParams) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (input.width + 15) / 16,
            height: (input.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        if waitForCompletion { commandBuffer.waitUntilCompleted() }
        return true
    }

    private func reuseOrMakeBackgroundMaskTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = backgroundMaskTexture, existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)
        backgroundMaskTexture = texture
        return texture
    }
}
#endif
