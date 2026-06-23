import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal
import simd

/// Renders the TikTok-style mesh-mapped mosaic: warp the posed face into a
/// frontal canvas, pixelate it with crisp squares, then warp it back onto the
/// posed face so the blocks foreshorten with the 3D surface.
///
/// Two render passes + one compute pass; the face mesh itself defines the masked
/// region (no separate contour mask needed). Requires a full 478-point mesh.
///
/// GPU-only; behaviour can only be verified on a device / simulator.
final class FaceMeshMosaicRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let frontalizePipeline: MTLRenderPipelineState
    private let rewarpPipeline: MTLRenderPipelineState
    private let pixelatePipeline: MTLComputePipelineState
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let canvasSize: Int

    private var frontTexture: MTLTexture?
    private var frontPixTexture: MTLTexture?
    /// Output-sized render target we draw into, then blit to the caller's
    /// `output` (which — e.g. a CVPixelBuffer-backed video texture — may not
    /// carry `.renderTarget` usage).
    private var posedTexture: MTLTexture?

    /// Reference face width (px) the coarseness slider is calibrated against, so
    /// the screen-space block size maps to a sensible canvas block size.
    private let referenceFaceWidth: Float = 380

    init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue, canvasSize: Int = 256) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.canvasSize = canvasSize
        let format = MTLPixelFormat.bgra8Unorm

        func makeRenderPipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            guard let vfn = library.makeFunction(name: vertex) else {
                throw MosaicRendererError.functionMissing(vertex)
            }
            guard let ffn = library.makeFunction(name: fragment) else {
                throw MosaicRendererError.functionMissing(fragment)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vfn
            descriptor.fragmentFunction = ffn
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.frontalizePipeline = try makeRenderPipeline(
            vertex: "meshFrontalizeVertex", fragment: "meshSampleLinear")
        self.rewarpPipeline = try makeRenderPipeline(
            vertex: "meshRewarpVertex", fragment: "meshSampleNearest")

        guard let pixfn = library.makeFunction(name: "meshPixelateKernel") else {
            throw MosaicRendererError.functionMissing("meshPixelateKernel")
        }
        self.pixelatePipeline = try device.makeComputePipelineState(function: pixfn)

        let tris = FaceMeshTopology.triangles
        self.indexCount = tris.count
        guard let ibuf = device.makeBuffer(
            bytes: tris,
            length: tris.count * MemoryLayout<UInt16>.stride,
            options: []
        ) else {
            throw MosaicRendererError.commandQueueUnavailable
        }
        self.indexBuffer = ibuf
    }

    /// Returns `true` if the mesh mosaic was rendered into `output`.
    func render(
        input: MTLTexture,
        output: MTLTexture,
        landmarks: FaceLandmarkSet,
        block: Float,
        waitForCompletion: Bool
    ) -> Bool {
        let vertexCount = FaceMeshTopology.vertexCount
        guard landmarks.points.count >= vertexCount else { return false }
        guard let vertexBuffer = makeVertexBuffer(landmarks: landmarks, vertexCount: vertexCount) else {
            return false
        }
        guard ensureCanvasTextures(),
              let frontTexture, let frontPixTexture,
              let posed = ensurePosedTexture(width: output.width, height: output.height),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        copy(input: input, to: posed, in: commandBuffer)
        frontalize(input: input, into: frontTexture, vertices: vertexBuffer, in: commandBuffer)
        pixelate(from: frontTexture, into: frontPixTexture, block: block, in: commandBuffer)
        rewarp(from: frontPixTexture, into: posed, vertices: vertexBuffer, in: commandBuffer)
        copy(input: posed, to: output, in: commandBuffer)

        commandBuffer.commit()
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }
        return true
    }

    // MARK: - Steps

    private func makeVertexBuffer(landmarks: FaceLandmarkSet, vertexCount: Int) -> MTLBuffer? {
        let frontal = FaceMeshTopology.frontalUV
        var verts = [SIMD4<Float>](repeating: .zero, count: vertexCount)
        for index in 0..<vertexCount {
            let point = landmarks.points[index]
            // xy = frontal UV, zw = posed UV (landmarks are already normalized).
            verts[index] = SIMD4<Float>(frontal[index * 2], frontal[index * 2 + 1], point.x, point.y)
        }
        return device.makeBuffer(
            bytes: verts,
            length: vertexCount * MemoryLayout<SIMD4<Float>>.stride,
            options: []
        )
    }

    private func copy(input: MTLTexture, to output: MTLTexture, in buffer: MTLCommandBuffer) {
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(
            width: min(input.width, output.width),
            height: min(input.height, output.height),
            depth: 1
        )
        blit.copy(
            from: input, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
            to: output, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    private func frontalize(
        input: MTLTexture, into target: MTLTexture,
        vertices: MTLBuffer, in buffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(frontalizePipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount,
            indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0
        )
        encoder.endEncoding()
    }

    private func pixelate(
        from source: MTLTexture, into target: MTLTexture,
        block: Float, in buffer: MTLCommandBuffer
    ) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pixelatePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        var canvasBlock = max(block * Float(canvasSize) / referenceFaceWidth, 2)
        encoder.setBytes(&canvasBlock, length: MemoryLayout<Float>.size, index: 0)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (canvasSize + 15) / 16,
            height: (canvasSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
    }

    private func rewarp(
        from source: MTLTexture, into target: MTLTexture,
        vertices: MTLBuffer, in buffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load   // keep the blitted original
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(rewarpPipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount,
            indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0
        )
        encoder.endEncoding()
    }

    private func ensurePosedTexture(width: Int, height: Int) -> MTLTexture? {
        if let posedTexture, posedTexture.width == width, posedTexture.height == height {
            return posedTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)
        posedTexture = texture
        return texture
    }

    private func ensureCanvasTextures() -> Bool {
        if frontTexture != nil, frontPixTexture != nil { return true }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: canvasSize, height: canvasSize, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        frontTexture = device.makeTexture(descriptor: descriptor)

        let pixDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: canvasSize, height: canvasSize, mipmapped: false
        )
        pixDescriptor.usage = [.shaderRead, .shaderWrite]
        frontPixTexture = device.makeTexture(descriptor: pixDescriptor)
        return frontTexture != nil && frontPixTexture != nil
    }
}
#endif
