import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal
import MetalKit
import Combine

/// Parameters handed to `mosaicKernel`. The memory layout mirrors the
/// `MosaicParams` struct in `MosaicShader.metal` exactly — keep them in sync.
public struct MosaicParams: Equatable {
    /// Uniform mosaic block size (in pixels) applied to every masked region.
    /// Strength is driven by the single coarseness slider in the editor.
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

/// Drives the whole effect for a single frame: derive the contour mask from
/// landmarks, run the from-scratch Metal pixelation kernel, and publish a
/// smoothed ``TrackingStatus``.
///
/// The renderer is deliberately Metal-only and UI-agnostic. SwiftUI observers
/// subscribe to ``statusPublisher`` (or use ``TrackingStatusStore``); a live
/// preview can also be driven through ``MTKViewDelegate`` conformance.
public final class MosaicRenderer: NSObject {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLComputePipelineState
    private var maskBuilder: FaceMaskBuilder
    /// Mesh-mapped 3D mosaic renderer; used when a full face mesh is available,
    /// otherwise the contour-mask compute path is the fallback.
    private let meshRenderer: FaceMeshMosaicRenderer?

    /// Block size / edge softness. Mutate to retune the look at runtime.
    public var params: MosaicParams

    /// Which face regions are mosaicked. Toggle at runtime to enable/disable
    /// the face, eyes, or mouth independently.
    public var enabledRegions: Set<FaceRegion> {
        get { maskBuilder.enabledRegions }
        set { maskBuilder.enabledRegions = newValue }
    }

    private var evaluator: TrackingEvaluator
    private let statusSubject = CurrentValueSubject<TrackingStatus, Never>(.idle)

    /// The latest published tracking status.
    public var status: TrackingStatus { statusSubject.value }
    /// Combine stream of tracking status updates, delivered on the main queue.
    public var statusPublisher: AnyPublisher<TrackingStatus, Never> {
        statusSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    private var maskTexture: MTLTexture?
    /// Cached mask texture for the flat background mosaic (see
    /// ``renderBackground(input:into:mask:block:waitForCompletion:)``).
    var backgroundMaskTexture: MTLTexture?

    /// Creates a renderer.
    /// - Parameters:
    ///   - device: GPU to use. Defaults to the system default device; throws
    ///     ``MosaicRendererError/noDevice`` when none exists (e.g. headless CI).
    ///   - params: initial mosaic parameters.
    ///   - maskBuilder: contour-mask builder.
    ///   - evaluator: tracking-rate state machine.
    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        params: MosaicParams = MosaicParams(),
        maskBuilder: FaceMaskBuilder = FaceMaskBuilder(),
        evaluator: TrackingEvaluator = TrackingEvaluator()
    ) throws {
        guard let device = device else { throw MosaicRendererError.noDevice }
        self.device = device

        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw MosaicRendererError.libraryUnavailable
        }
        guard let function = library.makeFunction(name: "mosaicKernel") else {
            throw MosaicRendererError.functionMissing("mosaicKernel")
        }
        self.pipelineState = try device.makeComputePipelineState(function: function)

        guard let queue = device.makeCommandQueue() else {
            throw MosaicRendererError.commandQueueUnavailable
        }
        self.commandQueue = queue
        self.params = params
        self.maskBuilder = maskBuilder
        self.evaluator = evaluator
        // Optional: the mesh-mapped 3D mosaic. If its pipelines fail to build we
        // silently fall back to the contour-mask compute mosaic.
        self.meshRenderer = try? FaceMeshMosaicRenderer(
            device: device, library: library, commandQueue: queue)
        super.init()
    }

    // MARK: - Frame processing

    /// Applies the mosaic to `input`, writing into `output` (same dimensions).
    ///
    /// Passing `landmarks == nil` is fully supported and never crashes: the
    /// tracking state moves to `.lost` / `.searching`, the original frame is
    /// copied through untouched, and the very next confident detection resumes
    /// the mosaic on that frame with no warm-up delay.
    ///
    /// - Parameter waitForCompletion: when `true`, blocks until the GPU work
    ///   finishes. Offline video export needs this before reading back / writing
    ///   the output frame; live preview should leave it `false`.
    @discardableResult
    public func render(
        input: MTLTexture,
        into output: MTLTexture,
        landmarks: FaceLandmarkSet?,
        waitForCompletion: Bool = false
    ) -> TrackingStatus {
        let newStatus = evaluator.update(confidence: landmarks?.confidence)
        statusSubject.send(newStatus)

        let width = input.width
        let height = input.height

        // No usable face this frame → pass the frame through unchanged.
        guard let landmarks, newStatus.faceDetected else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return newStatus
        }

        // Preferred path: mesh-mapped 3D mosaic (needs a full 478-point mesh).
        if landmarks.isFullMesh,
           let meshRenderer,
           meshRenderer.render(
               input: input,
               output: output,
               landmarks: landmarks,
               block: params.block,
               waitForCompletion: waitForCompletion
           ) {
            return newStatus
        }

        // Fallback: contour-mask compute mosaic.
        guard let mask = updatedMaskTexture(for: landmarks, width: width, height: height) else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return newStatus
        }

        var kernelParams = params
        kernelParams.width = UInt32(width)
        kernelParams.height = UInt32(height)
        // Anchor and rotate the block grid to the face so blocks follow a tilt.
        let size = CGSize(width: width, height: height)
        kernelParams.rotation = landmarks.rollAngle(in: size)
        let faceCenter = landmarks.centroid(in: size)
        kernelParams.centerX = Float(faceCenter.x)
        kernelParams.centerY = Float(faceCenter.y)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return newStatus
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(mask, index: 2)
        withUnsafeBytes(of: &kernelParams) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }

        return newStatus
    }

    /// 複数の顔ランドマークセット（＋追加パス）でモザイクをレンダリングする。
    /// - フルメッシュ顔はメッシュレンダラーで順番にチェーン処理。
    /// - 部分メッシュ顔・追加パスはコンタマスクのコンピュートカーネルで処理。
    @discardableResult
    public func render(
        input: MTLTexture,
        into output: MTLTexture,
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath] = [],
        waitForCompletion: Bool = false
    ) -> TrackingStatus {
        let maxConfidence = landmarkSets.map(\.confidence).max()
        let newStatus = evaluator.update(confidence: maxConfidence)
        statusSubject.send(newStatus)

        let width = input.width
        let height = input.height

        guard newStatus.faceDetected || !additionalPaths.isEmpty else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return newStatus
        }

        let fullMesh = landmarkSets.filter(\.isFullMesh)
        let partial = landmarkSets.filter { !$0.isFullMesh }
        let hasContour = !partial.isEmpty || !additionalPaths.isEmpty

        // Phase 1: チェーンメッシュレンダリング（フルメッシュ顔）
        var contourInput = input
        if let meshRenderer, !fullMesh.isEmpty {
            // コンタ処理が後続する場合は中間テクスチャに書き出す
            let meshOut: MTLTexture
            if hasContour, let temp = MetalTextureUtilities.makeOutputTexture(like: input, device: device) {
                meshOut = temp
            } else {
                meshOut = output
            }
            // 1枚目: input → meshOut
            meshRenderer.render(
                input: input, output: meshOut,
                landmarks: fullMesh[0], block: params.block,
                waitForCompletion: fullMesh.count > 1 || hasContour ? true : waitForCompletion
            )
            // 2枚目以降: meshOut → meshOut (同一コマンドバッファ内で安全)
            for i in 1..<fullMesh.count {
                let isLast = i == fullMesh.count - 1
                meshRenderer.render(
                    input: meshOut, output: meshOut,
                    landmarks: fullMesh[i], block: params.block,
                    waitForCompletion: isLast ? (hasContour ? true : waitForCompletion) : true
                )
            }
            contourInput = meshOut
        }

        // Phase 2: コンタマスク（部分メッシュ顔 + 追加パス）
        if hasContour {
            guard let mask = buildCombinedMaskTexture(
                landmarkSets: partial, additionalPaths: additionalPaths,
                width: width, height: height
            ) else {
                copy(from: contourInput, to: output, waitForCompletion: waitForCompletion)
                return newStatus
            }
            applyContourKernel(input: contourInput, output: output, mask: mask, waitForCompletion: waitForCompletion)
        }

        return newStatus
    }

    private func buildCombinedMaskTexture(
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath],
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let rendered = maskBuilder.renderMask(
            for: landmarkSets, additionalPaths: additionalPaths,
            width: width, height: height
        ) else { return nil }
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

    private func applyContourKernel(
        input: MTLTexture,
        output: MTLTexture,
        mask: MTLTexture,
        waitForCompletion: Bool
    ) {
        var kernelParams = params
        kernelParams.width = UInt32(input.width)
        kernelParams.height = UInt32(input.height)
        kernelParams.rotation = 0
        kernelParams.centerX = Float(input.width) / 2
        kernelParams.centerY = Float(input.height) / 2

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            copy(from: input, to: output, waitForCompletion: waitForCompletion)
            return
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(mask, index: 2)
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
    }

    /// Resets tracking back to idle (e.g. when switching media).
    public func reset() {
        evaluator.reset()
        statusSubject.send(.idle)
    }

    // MARK: - Mask management

    private func updatedMaskTexture(
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

    private func reuseOrMakeMaskTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = maskTexture, existing.width == width, existing.height == height {
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
        maskTexture = texture
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

/// SwiftUI-friendly observable wrapper around a renderer's status stream.
///
/// ```swift
/// @StateObject private var tracking = TrackingStatusStore(renderer: renderer)
/// // ...
/// Text("追従率 \(Int(tracking.status.rate))%")
/// ```
@MainActor
public final class TrackingStatusStore: ObservableObject {
    @Published public private(set) var status: TrackingStatus = .idle
    private var cancellable: AnyCancellable?

    public init(renderer: MosaicRenderer) {
        cancellable = renderer.statusPublisher
            .sink { [weak self] in self?.status = $0 }
    }
}

#endif
