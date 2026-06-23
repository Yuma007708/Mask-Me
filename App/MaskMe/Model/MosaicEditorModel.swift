import AVFoundation
import Combine
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// Orchestrates the whole editing session: loads the chosen media, runs face
/// detection + the Metal mosaic for the preview, drives video export, and saves
/// results. Owns no UI; SwiftUI observes its published state.
@MainActor
public final class MosaicEditorModel: ObservableObject {
    public enum Mode {
        case photo
        case video
    }

    // Preview / status
    @Published public private(set) var previewImage: UIImage?
    @Published public private(set) var status: TrackingStatus = .idle
    @Published public private(set) var isLoading = false

    // Controls (bound to the editor slider / toggle)
    @Published public var blockSize: Float = 28
    @Published public var faceEnabled = true

    // Fixed: with the solid hard-edged hull mask, edge softness no longer
    // feathers the boundary, so it is not user-exposed.
    private let edgeSoftness: Float = 0.35

    // Export / save
    @Published public var exportProgress: Double?
    @Published public var didSave = false
    @Published public var errorMessage: String?

    public let mode: Mode

    private let renderer: MosaicRenderer?
    private let landmarker: FaceLandmarking
    private let recents: RecentItemsStore

    private var sourceTexture: MTLTexture?
    private var sourceLandmarks: FaceLandmarkSet?
    private var videoAsset: AVAsset?
    private var cancellables: Set<AnyCancellable> = []

    public init(
        mode: Mode,
        recents: RecentItemsStore,
        landmarker: FaceLandmarking = makeFaceLandmarker()
    ) {
        self.mode = mode
        self.recents = recents
        self.landmarker = landmarker
        self.renderer = try? MosaicRenderer()

        renderer?.statusPublisher
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)

        bindControls()
    }

    /// Re-render whenever a control changes (debounced to coalesce slider drags).
    private func bindControls() {
        Publishers.Merge($blockSize.map { _ in () }, $faceEnabled.map { _ in () })
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] in self?.renderPreview() }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    public func load(image: UIImage) {
        isLoading = true
        let normalized = image.normalizedUp()
        sourceLandmarks = landmarker.landmarks(in: normalized)
        sourceTexture = makeTexture(from: normalized)
        renderer?.reset()
        renderPreview()
        isLoading = false
    }

    public func load(videoURL url: URL) {
        isLoading = true
        let asset = AVAsset(url: url)
        videoAsset = asset
        if let frame = Self.firstFrame(of: asset) {
            sourceLandmarks = landmarker.landmarks(in: frame)
            sourceTexture = makeTexture(from: frame)
        }
        renderer?.reset()
        renderPreview()
        isLoading = false
    }

    // MARK: - Rendering

    private func renderPreview() {
        guard let renderer, let sourceTexture else { return }
        applyControls(to: renderer)
        guard let result = renderer.renderToNewTexture(
            input: sourceTexture,
            landmarks: sourceLandmarks
        ) else {
            return
        }
        if let cgImage = MetalTextureUtilities.cgImage(from: result.texture) {
            previewImage = UIImage(cgImage: cgImage)
        }
    }

    private func applyControls(to renderer: MosaicRenderer) {
        renderer.params = MosaicParams(
            block: blockSize,
            edgeSoftness: edgeSoftness
        )
        // Single whole-face mosaic (TikTok-style); finer per-region masking was
        // dropped along with the unified block size.
        renderer.enabledRegions = faceEnabled ? [.faceOval] : []
    }

    // MARK: - Saving

    public func savePhoto() async {
        guard let image = previewImage else { return }
        do {
            try await PhotosSaver.save(image: image)
            recents.add(kind: .photo, thumbnail: image)
            didSave = true
        } catch {
            errorMessage = "保存に失敗しました"
        }
    }

    public func exportVideo() async {
        guard let renderer, let videoAsset else { return }
        exportProgress = 0
        let exporter = VideoMosaicExporter(renderer: renderer, landmarker: landmarker)
        do {
            let url = try await exporter.export(asset: videoAsset) { [weak self] fraction in
                self?.exportProgress = fraction
            }
            try await PhotosSaver.save(videoURL: url)
            if let thumb = previewImage {
                recents.add(kind: .video, thumbnail: thumb)
            }
            didSave = true
        } catch {
            errorMessage = "エクスポートに失敗しました"
        }
        exportProgress = nil
    }

    // MARK: - Helpers

    private func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let renderer, let cgImage = image.cgImage else { return nil }
        return try? MetalTextureUtilities.texture(from: cgImage, device: renderer.device)
    }

    private static func firstFrame(of asset: AVAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private extension UIImage {
    /// Returns a copy with orientation baked into the pixels (`.up`), so that
    /// landmark normalized coordinates line up with the texture we render.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
