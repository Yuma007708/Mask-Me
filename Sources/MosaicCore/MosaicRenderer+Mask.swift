import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// マスクテクスチャの確保・更新とテクスチャ間コピー。同一モジュールなので
/// レンダラーの internal メンバへそのまま触れる。`MosaicRenderer.swift` を
/// file / type の行数上限内に保つために切り出してある（`MosaicRenderer+Background.swift`
/// と同じ流儀）。
extension MosaicRenderer {
    // MARK: - Mask management

    func updatedMaskTexture(
        for landmarks: FaceLandmarkSet,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let rendered = maskBuilder.renderMask(
            for: landmarks,
            width: width,
            height: height
        ) else {
            return nil
        }

        let texture = reuseOrMakeMaskTexture(width: width, height: height)
        guard let texture else { return nil }

        rendered.bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: rendered.bytesPerRow
            )
        }
        return texture
    }

    func reuseOrMakeMaskTexture(width: Int, height: Int) -> MTLTexture? {
        reuseOrMakeR8Texture(&maskTexture, width: width, height: height)
    }

    /// r8Unorm のマスクテクスチャを、サイズが一致すれば再利用し、なければ生成して
    /// `cache` に格納する。顔コンタ用・背景用で同じ確保ロジックを共有する。
    func reuseOrMakeR8Texture(
        _ cache: inout MTLTexture?,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        if let existing = cache, existing.width == width, existing.height == height {
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
        cache = texture
        return texture
    }

    func copy(
        from source: MTLTexture,
        to destination: MTLTexture,
        waitForCompletion: Bool = false
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(
            width: min(source.width, destination.width),
            height: min(source.height, destination.height),
            depth: 1
        )
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }
    }
}
#endif
