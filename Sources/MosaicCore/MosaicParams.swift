import Foundation

#if canImport(Metal) && canImport(MetalKit)

/// Parameters handed to `mosaicKernel`. The memory layout mirrors the
/// `MosaicParams` struct in `MosaicShader.metal` exactly — keep them in sync.
public struct MosaicParams: Equatable {
    /// Uniform mosaic block size applied to every masked region.
    /// Strength is driven by the single coarseness slider in the editor.
    ///
    /// This is a **nominal** size calibrated against
    /// `MosaicRenderer.referenceFrameWidth` (720px), not a raw pixel count:
    /// the contour path (partial-mesh faces, manual rects) and the background path
    /// scale it by the texture width via `MosaicRenderer.effectiveBlock(_:textureWidth:)`
    /// before it reaches the shader, so the same slider value looks the same in the
    /// 720px preview and in a full-resolution export. The face-mesh path
    /// (`FaceMeshMosaicRenderer`) is resolution independent for the same reason:
    /// it maps the value onto a fixed 256px canvas. Only the value the shader
    /// finally receives is in pixels of the texture being drawn.
    public var block: Float
    public var edgeSoftness: Float
    /// Face roll in radians; the block grid rotates by this so the mosaic
    /// follows a tilted face. Set per frame from the landmarks.
    public var rotation: Float
    /// Face center (pixels) the grid is anchored to and rotated about.
    public var centerX: Float
    public var centerY: Float
    public var width: UInt32
    public var height: UInt32

    public init(
        block: Float = 28,
        edgeSoftness: Float = 0.35,
        rotation: Float = 0,
        centerX: Float = 0,
        centerY: Float = 0,
        width: UInt32 = 0,
        height: UInt32 = 0
    ) {
        self.block = block
        self.edgeSoftness = edgeSoftness
        self.rotation = rotation
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
}

/// Errors thrown while setting up the Metal pipeline. The most common in CI /
/// headless contexts is ``noDevice`` — there simply is no GPU to bind to.
public enum MosaicRendererError: Error, Equatable {
    case noDevice
    case libraryUnavailable
    case functionMissing(String)
    case commandQueueUnavailable
}
#endif
