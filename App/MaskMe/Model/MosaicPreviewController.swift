import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 動画のリアルタイムモザイクプレビューを駆動する。
/// AVPlayer + AVPlayerItemVideoOutput + CADisplayLink を組み合わせ、
/// フレームごとに Metal レンダリングして model.previewImage を更新する。
@MainActor
final class MosaicPreviewController {
    private let renderer: MosaicRenderer
    private weak var model: MosaicEditorModel?

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var displayLink: CADisplayLink?
    private let ciContext: CIContext
    private var videoURL: URL?
    /// 直前フレームで有効だったランドマーク。キャッシュ欠落時のフリーズ用。
    private var lastKnownLandmarks: [FaceLandmarkSet] = []
    #if canImport(Vision)
    private let segmenter = PersonSegmenter(quality: .balanced)
    #endif

    private(set) var duration: Double = 0

    init(renderer: MosaicRenderer, url: URL, model: MosaicEditorModel) {
        self.renderer = renderer
        self.model = model
        self.videoURL = url
        self.ciContext = CIContext(mtlDevice: renderer.device, options: [.useSoftwareRenderer: false])

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &cache)
        self.textureCache = cache

        setupPlayer(url)
    }

    private func setupPlayer(_ url: URL) {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        self.videoOutput = output

        let item = AVPlayerItem(url: url)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        self.player = player

        // 再生終了を監視
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        // 尺を非同期で取得
        Task {
            let d = try? await item.asset.load(.duration)
            self.duration = d?.seconds ?? 0
        }
    }

    // MARK: - 再生制御

    func play() {
        player?.play()
        startDisplayLink()
    }

    func pause() {
        player?.pause()
        stopDisplayLink()
    }

    func seek(to position: Double) async {
        guard let player, duration > 0 else { return }
        let sec = position * duration
        let time = CMTime(seconds: sec, preferredTimescale: 600)
        // シーク先では古いフリーズランドマークを使わない
        lastKnownLandmarks = []
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        renderCurrentFrame()
    }

    /// コントロール（blockSize など）が変化したときに現在フレームを再描画する。
    func invalidate() {
        renderCurrentFrame()
    }

    // MARK: - DisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        renderCurrentFrame()
    }

    @objc private func playerDidFinish() {
        model?.isPlaying = false
        stopDisplayLink()
    }

    // MARK: - レンダリング

    private func renderCurrentFrame() {
        guard let player,
              let videoOutput,
              let model,
              let cache = textureCache else { return }

        let currentTime = player.currentTime()
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else {
            return
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)

        // 720px 幅に縮小してから Metal 処理（GPU→CPU 転送量を削減）
        let maxWidth = 720
        let scale = min(Double(maxWidth) / Double(bufferWidth), 1.0)

        let inputTex: MTLTexture?
        if scale < 0.99 {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                inputTex = try? MetalTextureUtilities.texture(from: cg, device: renderer.device)
            } else {
                inputTex = nil
            }
        } else {
            inputTex = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache)
        }

        guard let tex = inputTex else { return }

        let timeSec = currentTime.seconds
        var landmarks = model.selectedLandmarks(at: timeSec)
        // キャッシュにヒットしなければ直前の有効ランドマークで freeze する
        if landmarks.isEmpty {
            landmarks = lastKnownLandmarks
        } else {
            lastKnownLandmarks = landmarks
        }
        let additionalPaths = model.manualRegionPaths(
            for: CGSize(width: bufferWidth, height: bufferHeight)
        )

        guard let result = renderer.renderToNewTexture(
            input: tex,
            landmarkSets: landmarks,
            additionalPaths: additionalPaths
        ) else { return }

        // 背景モザイク（平面）。人物前景を反転したマスクで背景だけを処理。
        var finalTexture = result.texture
        if model.backgroundMosaicOn {
            #if canImport(Vision)
            if let mask = segmenter.backgroundMask(pixelBuffer: pixelBuffer),
               let out = renderer.renderBackgroundToNewTexture(
                   input: finalTexture,
                   maskBytes: mask.bytes, maskWidth: mask.width, maskHeight: mask.height,
                   block: model.backgroundBlockSize
               ) {
                finalTexture = out
            }
            #endif
        }

        guard let cgImage = MetalTextureUtilities.cgImage(from: finalTexture) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        model.previewImage = uiImage
        if duration > 0 {
            model.playbackPosition = max(0, min(timeSec / duration, 1))
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}
#endif
