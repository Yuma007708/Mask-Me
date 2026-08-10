import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal
import CoreVideo
import CoreGraphics

/// Helpers that bridge the platform image types the app works with
/// (`CGImage`, `CVPixelBuffer`) to and from the `MTLTexture`s that
/// ``MosaicRenderer/render(input:into:landmarks:)`` consumes and produces.
///
/// Kept in `MosaicCore` (behind a Metal availability gate) so both the live
/// preview and the offline video exporter can share one conversion path.
public enum MetalTextureUtilities {
    public enum TextureError: Error {
        case allocationFailed
        case contextFailed
    }

    /// Pixel format used throughout the pipeline. `bgra8Unorm` matches the
    /// layout that `CVMetalTextureCache` and most camera/video buffers expose.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Draws a `CGImage` into a `bgra8Unorm` texture. Keeping the still-image
    /// path on the same format as the video path guarantees that ``cgImage(from:)``
    /// reads channels back in the right order.
    public static func texture(
        from image: CGImage,
        device: MTLDevice
    ) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TextureError.allocationFailed
        }

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw TextureError.contextFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
        }
        return texture
    }

    /// Wraps a `CVPixelBuffer` as a Metal texture via a texture cache. The
    /// returned texture shares storage with the pixel buffer, so keep the
    /// buffer alive while the texture is in use.
    public static func texture(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Creates an empty texture matching `like`, usable as a compute output.
    public static func makeOutputTexture(
        like source: MTLTexture,
        device: MTLDevice
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat == .invalid ? pixelFormat : source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    /// Reads a texture back into a `CGImage` (for still-image export / thumbnails).
    public static func cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)

        raw.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA bytes → little-endian + premultiplied-first matches bgra8Unorm.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return context.makeImage()
    }
}

extension MosaicRenderer {
    /// 既存の単一顔 API（後方互換）。
    @discardableResult
    public func renderToNewTexture(
        input: MTLTexture,
        landmarks: FaceLandmarkSet?
    ) -> (texture: MTLTexture, status: TrackingStatus)? {
        let sets = landmarks.map { [$0] } ?? []
        return renderToNewTexture(input: input, landmarkSets: sets)
    }

    /// 複数顔ランドマーク＋追加パスでレンダリングし、新規テクスチャを返す。
    @discardableResult
    public func renderToNewTexture(
        input: MTLTexture,
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath] = [],
        faceOptions: [FaceRenderOption]? = nil
    ) -> (texture: MTLTexture, status: TrackingStatus)? {
        guard let output = MetalTextureUtilities.makeOutputTexture(like: input, device: device) else {
            return nil
        }
        let status = render(
            input: input,
            into: output,
            landmarkSets: landmarkSets,
            additionalPaths: additionalPaths,
            faceOptions: faceOptions,
            waitForCompletion: true
        )
        return (output, status)
    }

    /// 背景マスク（人物前景を反転したもの）で平面モザイクをかけ、新規テクスチャを返す。
    /// マスクは正規化UVでサンプリングするので入力解像度と一致しなくてよい。
    @discardableResult
    public func renderBackgroundToNewTexture(
        input: MTLTexture,
        mask: MaskBuffer,
        block: Float
    ) -> MTLTexture? {
        guard let output = MetalTextureUtilities.makeOutputTexture(like: input, device: device) else {
            return nil
        }
        let ok = renderBackground(
            input: input,
            into: output,
            mask: mask,
            block: block,
            waitForCompletion: true
        )
        return ok ? output : nil
    }

    /// `textTexture` を `layout` の位置・サイズ・不透明度で重ね、新規テクスチャを返す（E3-2）。
    /// 描画対象が無い（サイズ 0 / 不透明度 0）ときも `input` と同サイズのコピーを返す
    /// （呼び出し側がチェーンで `current = ...` と使い回せるよう、常に非 nil を保つ）。
    @discardableResult
    public func renderTextToNewTexture(
        input: MTLTexture,
        textTexture: MTLTexture,
        layout: TextQuadLayout
    ) -> MTLTexture? {
        guard let output = MetalTextureUtilities.makeOutputTexture(like: input, device: device) else {
            return nil
        }
        renderText(input: input, into: output, textTexture: textTexture, layout: layout, waitForCompletion: true)
        return output
    }

    /// `grade` の色調補正を適用し、新規テクスチャを返す。
    ///
    /// **呼び出し側が `grade.isIdentity` を見て呼ぶかどうかを決めること**
    /// （`renderColorGrade` の doc 参照）。ここは常に 1 パス発行する
    /// （出力テクスチャの確保に失敗したら nil）。
    @discardableResult
    public func renderColorGradeToNewTexture(
        input: MTLTexture,
        grade: ColorGrade
    ) -> MTLTexture? {
        guard let output = MetalTextureUtilities.makeOutputTexture(like: input, device: device) else {
            return nil
        }
        renderColorGrade(input: input, into: output, grade: grade, waitForCompletion: true)
        return output
    }
}
#endif
