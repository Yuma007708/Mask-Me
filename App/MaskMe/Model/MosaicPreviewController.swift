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
    #if canImport(Vision)
    private let segmenter = PersonSegmenter(quality: .balanced)
    #endif
    /// 背景マスクのキャッシュ。Vision は重いので毎フレームではなく一定間隔で更新する。
    private var cachedBackgroundMask: MaskBuffer?
    private var framesUntilResegment = 0
    /// 背景マスクの再セグメント間隔（フレーム数）。30fps で約 5fps 相当。
    private let backgroundSegmentInterval = 6

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
        // シーク先では古い背景マスクを使わない
        cachedBackgroundMask = nil
        framesUntilResegment = 0
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
        // `copyPixelBuffer(forItemTime:)` は要求時刻に最も近いフレームを返すだけで、
        // 実際に返ってきたフレームの時刻は内部バッファリング次第（1〜3 フレーム遅延しうる）。
        // 第 2 引数で実フレーム時刻を受け取り、landmarks の検索もそれに揃えると一拍遅れが消える。
        var actualItemTime = CMTime()
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: currentTime,
            itemTimeForDisplay: &actualItemTime
        ) else {
            return
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)

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

        // 描画中のフレームの実際の時刻（理想時刻ではなく）で landmarks を引く。
        // これにより「顔の動きにモザイクが一拍遅れる」現象を解消する。
        let timeSec = actualItemTime.isValid ? actualItemTime.seconds : currentTime.seconds
        // 顔タブが OFF のときは顔ランドマークを使わない。
        // 検出キャッシュ欠落時の freeze はしない。lookupFaces 側で両側マッチング補間が
        // 連続する顔だけ返すようにしているため、ここで freeze するとアウト→イン時に
        // 「アウト位置にモザイクが固定」され、かつエクスポートと挙動が食い違う。
        let landmarks: [FaceLandmarkSet] = model.faceMosaicOn
            ? model.selectedLandmarks(at: timeSec)
            : []
        // 手動矩形は顔検出の補助なので顔タブ（faceMosaicOn）の状態に従う。
        // 解像度は（縮小後の）実テクスチャに合わせる（フルサイズだと 720px 縮小時に位置がずれる）。
        let additionalPaths = model.faceMosaicOn
            ? model.manualRegionPaths(for: CGSize(width: tex.width, height: tex.height))
            : []

        guard let result = renderer.renderToNewTexture(
            input: tex,
            landmarkSets: landmarks,
            additionalPaths: additionalPaths
        ) else { return }

        // 背景モザイク（平面）。人物前景を反転したマスクで背景だけを処理。
        // Vision は重いため毎フレームではなく backgroundSegmentInterval ごとに再計算し、
        // 間のフレームはキャッシュ済みマスクを再利用する。
        var finalTexture = result.texture
        if model.backgroundMosaicOn {
            #if canImport(Vision)
            if framesUntilResegment <= 0 || cachedBackgroundMask == nil {
                cachedBackgroundMask = segmenter.backgroundMask(pixelBuffer: pixelBuffer)
                framesUntilResegment = backgroundSegmentInterval
            } else {
                framesUntilResegment -= 1
            }
            if let mask = cachedBackgroundMask,
               let out = renderer.renderBackgroundToNewTexture(
                   input: finalTexture,
                   mask: mask,
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
