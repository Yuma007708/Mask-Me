import AVFoundation
import Combine
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 編集セッション全体を管理するモデル。UI は Published プロパティを購読する。
@MainActor
public final class MosaicEditorModel: ObservableObject {
    public enum Mode { case photo, video }

    // プレビュー
    @Published public var previewImage: UIImage?
    @Published public private(set) var status: TrackingStatus = .idle
    @Published public private(set) var isLoading = false

    // 顔選択
    @Published public private(set) var detectedFaces: [FaceTarget] = []
    @Published public var manualRegions: [ManualRegion] = []
    @Published public private(set) var isScanning = false

    // 動画再生
    @Published public var playbackPosition: Double = 0
    @Published public private(set) var videoDuration: Double = 0
    @Published public var isPlaying = false

    // コントロール
    @Published public var blockSize: Float = 28
    @Published public var faceEnabled = true

    // エクスポート・保存
    @Published public var exportProgress: Double?
    @Published public var didSave = false
    @Published public var errorMessage: String?

    public let mode: Mode

    private let renderer: MosaicRenderer?
    private let landmarker: FaceLandmarking
    private let recents: RecentItemsStore

    private var sourceImage: UIImage?
    private var sourceTexture: MTLTexture?
    private var videoAsset: AVAsset?
    private(set) var detectionCache: [Double: [FaceLandmarkSet]] = [:]
    private(set) var previewController: MosaicPreviewController?
    private var cancellables: Set<AnyCancellable> = []
    private var scanTask: Task<Void, Never>?

    private let edgeSoftness: Float = 0.35

    public init(
        mode: Mode,
        recents: RecentItemsStore,
        landmarker: FaceLandmarking? = nil
    ) {
        self.mode = mode
        self.recents = recents
        self.landmarker = landmarker ?? makeFaceLandmarker(forVideo: mode == .video)
        self.renderer = try? MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))

        renderer?.statusPublisher
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)

        bindControls()
    }

    private func bindControls() {
        Publishers.Merge($blockSize.map { _ in () }, $faceEnabled.map { _ in () })
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.renderPreview()
                self?.previewController?.invalidate()
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    public func load(image: UIImage) {
        isLoading = true
        let normalized = image.normalizedUp()
        sourceImage = normalized
        let faces = landmarker.allLandmarks(in: normalized)
        detectedFaces = faces.map { lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalized),
                       isSelected: true)
        }
        manualRegions = []
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
            sourceImage = frame
            let faces = landmarker.allLandmarks(in: frame, timestampMs: 0)
            detectedFaces = faces.map { lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: frame),
                           isSelected: true)
            }
            sourceTexture = makeTexture(from: frame)
        }
        manualRegions = []

        Task {
            videoDuration = (try? await asset.load(.duration))?.seconds ?? 0
        }

        renderer?.reset()
        renderPreview()
        isLoading = false

        if let r = renderer {
            previewController = MosaicPreviewController(renderer: r, url: url, model: self)
        }

        startPreScan(asset: asset)
    }

    // MARK: - 顔選択

    public func toggleFace(_ id: UUID) {
        guard let idx = detectedFaces.firstIndex(where: { $0.id == id }) else { return }
        detectedFaces[idx].isSelected.toggle()
        renderPreview()
        previewController?.invalidate()
    }

    // MARK: - 矩形内クロップ検出（失敗時は動画フレームをサーチし、それでも失敗なら固定矩形）

    public func detectInRegion(_ normalizedRect: CGRect) async {
        guard let img = sourceImage, let cgImage = img.cgImage else {
            await resolveRegion(normalizedRect, referenceImage: nil)
            return
        }

        let pixW = CGFloat(cgImage.width)
        let pixH = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedRect.origin.x * pixW,
            y: normalizedRect.origin.y * pixH,
            width: normalizedRect.width * pixW,
            height: normalizedRect.height * pixH
        )

        guard let cropped = cgImage.cropping(to: pixelRect) else {
            await resolveRegion(normalizedRect, referenceImage: img)
            return
        }

        let croppedImage = UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
        let scanner = makeFaceLandmarker(forVideo: false)
        let found = scanner.allLandmarks(in: croppedImage)

        if !found.isEmpty {
            let newFaces = found.map { lm -> FaceTarget in
                let remapped = lm.remapped(into: normalizedRect)
                let thumb = generateThumbnail(for: remapped, from: img)
                return FaceTarget(id: UUID(), landmarks: remapped, thumbnail: thumb, isSelected: true)
            }
            detectedFaces += newFaces
        } else {
            // 現在フレームで検出できなければ動画全体をサーチ
            await resolveRegion(normalizedRect, referenceImage: img)
        }
        renderPreview()
        previewController?.invalidate()
        // 動画: プレスキャンを再実行して全フレームで顔を追跡する
        if mode == .video, let asset = videoAsset { startPreScan(asset: asset) }
    }

    /// 矩形内クロップが現在フレームで失敗したとき: 動画全体を1fpsでサーチして顔を探す。
    /// 見つかれば FaceTarget として追加（追跡可能）。全フレームで失敗なら固定矩形マスク。
    private func resolveRegion(_ rect: CGRect, referenceImage: UIImage?) async {
        guard mode == .video, let asset = videoAsset else {
            appendManualRect(rect)
            return
        }
        isScanning = true
        let scanner = makeFaceLandmarker(forVideo: false)
        let result = await Task.detached(priority: .userInitiated) { [scanner, asset, rect] in
            await Self.findFaceInVideo(asset: asset, rect: rect, scanner: scanner)
        }.value
        isScanning = false

        if let (landmarks, foundFrame) = result {
            let thumbSource = referenceImage ?? foundFrame
            let thumb = generateThumbnail(for: landmarks, from: thumbSource)
            detectedFaces.append(FaceTarget(id: UUID(), landmarks: landmarks, thumbnail: thumb, isSelected: true))
        } else {
            // どのフレームでも検出できなかった: 固定矩形マスクにフォールバック
            appendManualRect(rect)
        }
    }

    /// 動画を1fpsでサンプリングし、矩形クロップ内で顔を探す。最初の検出結果を返す。
    nonisolated private static func findFaceInVideo(
        asset: AVAsset,
        rect: CGRect,
        scanner: FaceLandmarking
    ) async -> (FaceLandmarkSet, UIImage)? {
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
        var t = 0.0
        while t <= dur {
            guard !Task.isCancelled else { return nil }
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                let pixelRect = CGRect(
                    x: rect.origin.x * CGFloat(cg.width),
                    y: rect.origin.y * CGFloat(cg.height),
                    width: rect.width  * CGFloat(cg.width),
                    height: rect.height * CGFloat(cg.height)
                )
                if let crop = cg.cropping(to: pixelRect) {
                    let faces = scanner.allLandmarks(in: UIImage(cgImage: crop))
                    if let first = faces.first {
                        return (first.remapped(into: rect), UIImage(cgImage: cg))
                    }
                }
            }
            t += 1.0
        }
        return nil
    }

    private func appendManualRect(_ normalizedRect: CGRect) {
        manualRegions.append(ManualRegion(id: UUID(), normalizedRect: normalizedRect))
    }

    public func removeManualRegion(_ id: UUID) {
        manualRegions.removeAll { $0.id == id }
        renderPreview()
        previewController?.invalidate()
    }

    // MARK: - 動画再生制御

    public func togglePlayback() {
        if isPlaying {
            previewController?.pause()
            isPlaying = false
        } else {
            previewController?.play()
            isPlaying = true
        }
    }

    public func seekTo(position: Double) {
        playbackPosition = position
        Task {
            await previewController?.seek(to: position)
            // シーク後のフレームで sourceTexture を更新してプレビューに反映
            if let asset = videoAsset, videoDuration > 0 {
                let t = position * videoDuration
                if let frame = Self.frame(of: asset, at: t) {
                    sourceTexture = makeTexture(from: frame)
                }
            }
        }
    }

    // MARK: - 手動再検出（動画: 現在シーク位置で再検出）

    public func redetect(at position: Double) async {
        guard let asset = videoAsset, videoDuration > 0 else { return }
        let t = position * videoDuration
        guard let frame = Self.frame(of: asset, at: t) else { return }

        let scanner = makeFaceLandmarker(forVideo: false)
        let found = scanner.allLandmarks(in: frame)
        detectionCache[t] = found

        if !found.isEmpty {
            detectedFaces = found.map { lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: frame),
                           isSelected: true)
            }
            sourceImage = frame
            sourceTexture = makeTexture(from: frame)
            renderPreview()
            previewController?.invalidate()
        }
    }

    // MARK: - レンダリング

    func renderPreview() {
        guard let renderer, let tex = sourceTexture else { return }
        applyControls(to: renderer)

        let landmarks = faceEnabled ? detectedFaces.filter(\.isSelected).map(\.landmarks) : []
        let extra = manualRegionPaths(for: CGSize(width: tex.width, height: tex.height))

        guard let result = renderer.renderToNewTexture(
            input: tex, landmarkSets: landmarks, additionalPaths: extra
        ) else { return }

        if let cg = MetalTextureUtilities.cgImage(from: result.texture) {
            previewImage = UIImage(cgImage: cg)
        }
    }

    // MARK: - 検出キャッシュ参照

    /// 指定時刻に最も近い、非空のキャッシュエントリを返す（最大1秒以内）。
    /// 空エントリは検出失敗を意味するためスキップし、直前の有効検出を再利用する。
    func lookupFaces(at time: Double) -> [FaceLandmarkSet] {
        if let exact = detectionCache[time], !exact.isEmpty { return exact }
        var best: (dist: Double, faces: [FaceLandmarkSet]) = (1.0, [])
        for (t, faces) in detectionCache {
            guard !faces.isEmpty else { continue }
            let d = abs(t - time)
            if d < best.dist { best = (d, faces) }
        }
        return best.faces
    }

    /// 選択中の顔に対応する、指定時刻のランドマークセットを返す。
    func selectedLandmarks(at time: Double) -> [FaceLandmarkSet] {
        guard faceEnabled else { return [] }
        let cached = lookupFaces(at: time)
        let selected = detectedFaces.filter(\.isSelected)
        if selected.isEmpty { return [] }
        if selected.count == detectedFaces.count { return cached }

        // 重心の近さで選択顔とキャッシュ顔を照合する（閾値0.5: 広め）
        return cached.filter { face in
            let fc = normalizedCentroid(of: face)
            return selected.contains { target in
                let tc = normalizedCentroid(of: target.landmarks)
                return hypot(fc.x - tc.x, fc.y - tc.y) < 0.5
            }
        }
    }

    /// 手動矩形を FaceMaskBuilder.RegionPath に変換する。
    func manualRegionPaths(for size: CGSize) -> [FaceMaskBuilder.RegionPath] {
        manualRegions.map { region in
            let path = FaceMaskBuilder.rectPath(from: region.normalizedRect, in: size)
            return FaceMaskBuilder.RegionPath(path: path, value: 0.4)
        }
    }

    // MARK: - 事前スキャン（バックグラウンド）

    private func startPreScan(asset: AVAsset) {
        scanTask?.cancel()
        isScanning = true
        let scanner = makeFaceLandmarker(forVideo: false)
        let initialFaceCount = detectedFaces.count
        // ManualRegion の矩形をバックグラウンドスレッドに渡す（値型なので安全）
        let cropRects = manualRegions.map(\.normalizedRect)

        scanTask = Task.detached(priority: .background) { [weak self, scanner, asset, initialFaceCount, cropRects] in
            await self?.runPreScan(
                asset: asset, scanner: scanner,
                expectedFaceCount: initialFaceCount, cropRects: cropRects
            )
        }
    }

    nonisolated private func runPreScan(
        asset: AVAsset,
        scanner: FaceLandmarking,
        expectedFaceCount: Int,
        cropRects: [CGRect] = []
    ) async {
        let dur: Double
        do { dur = try await asset.load(.duration).seconds } catch { return }
        guard dur > 0 else { return }

        let interval = 0.1   // 10fps
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval, preferredTimescale: 600)

        var sampleCount = 0
        var matchCounts = [Int](repeating: 0, count: max(expectedFaceCount, 1))

        var t = 0.0
        while t <= dur {
            guard !Task.isCancelled else { return }
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                let img = UIImage(cgImage: cg)
                var faces = scanner.allLandmarks(in: img)

                // ManualRegion の矩形クロップでも検出を試みる（小さい顔や検出しにくい顔への対応）
                for rect in cropRects {
                    let pixelRect = CGRect(
                        x: rect.origin.x * CGFloat(cg.width),
                        y: rect.origin.y * CGFloat(cg.height),
                        width: rect.width  * CGFloat(cg.width),
                        height: rect.height * CGFloat(cg.height)
                    )
                    if let crop = cg.cropping(to: pixelRect) {
                        let cropFaces = scanner.allLandmarks(in: UIImage(cgImage: crop))
                        faces += cropFaces.map { $0.remapped(into: rect) }
                    }
                }

                sampleCount += 1
                let facesForCache = faces
                let timeForCache = t
                let matchCountsCopy = matchCounts
                let updated = await MainActor.run { [weak self] () -> [Int] in
                    // 空結果はキャッシュしない（直前の有効検出を再利用させる）
                    if !facesForCache.isEmpty {
                        self?.detectionCache[timeForCache] = facesForCache
                    }
                    guard let self else { return matchCountsCopy }
                    var counts = matchCountsCopy
                    for (i, target) in self.detectedFaces.prefix(expectedFaceCount).enumerated() {
                        let tc = self.normalizedCentroid(of: target.landmarks)
                        if facesForCache.contains(where: { face in
                            let fc = self.normalizedCentroid(of: face)
                            return hypot(fc.x - tc.x, fc.y - tc.y) < 0.5
                        }) {
                            counts[i] += 1
                        }
                    }
                    return counts
                }
                matchCounts = updated
            }
            t += interval
        }

        let finalSampleCount = sampleCount
        let finalMatchCounts = matchCounts
        await MainActor.run { [weak self] in
            guard let self else { return }
            if finalSampleCount > 0 {
                for i in 0..<min(finalMatchCounts.count, self.detectedFaces.count) {
                    self.detectedFaces[i].detectionRate =
                        Double(finalMatchCounts[i]) / Double(finalSampleCount) * 100
                }
            }
            self.isScanning = false
        }
    }

    // MARK: - 保存・エクスポート

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
        let selectedIDs = Set(detectedFaces.filter(\.isSelected).map(\.id))
        do {
            let url = try await exporter.export(
                asset: videoAsset,
                selectedFaceTargets: detectedFaces.filter { selectedIDs.contains($0.id) },
                manualRegions: manualRegions,
                detectionCache: detectionCache,
                faceEnabled: faceEnabled
            ) { fraction in
                Task { @MainActor [weak self] in self?.exportProgress = fraction }
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

    // MARK: - Private helpers

    private func applyControls(to renderer: MosaicRenderer) {
        renderer.params = MosaicParams(block: blockSize, edgeSoftness: edgeSoftness)
        renderer.enabledRegions = [.faceOval]
    }

    private func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let r = renderer, let cg = image.cgImage else { return nil }
        return try? MetalTextureUtilities.texture(from: cg, device: r.device)
    }

    func generateThumbnail(for landmarks: FaceLandmarkSet, from image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let cgSize = CGSize(width: cg.width, height: cg.height)
        var bbox = FaceMaskBuilder().boundingBox(for: landmarks, in: cgSize)
        guard !bbox.isNull else { return image }
        let margin = max(bbox.width, bbox.height) * 0.4
        bbox = bbox.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(origin: .zero, size: cgSize))
        guard !bbox.isEmpty, let crop = cg.cropping(to: bbox) else { return image }
        return UIImage(cgImage: crop, scale: image.scale, orientation: image.imageOrientation)
    }

    func normalizedCentroid(of landmarks: FaceLandmarkSet) -> CGPoint {
        guard !landmarks.points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        var sx: Float = 0; var sy: Float = 0
        for p in landmarks.points { sx += p.x; sy += p.y }
        let n = Float(landmarks.points.count)
        return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
    }

    private static func firstFrame(of asset: AVAsset) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func frame(of asset: AVAsset, at time: Double) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let t = CMTime(seconds: time, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private extension UIImage {
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let r = UIGraphicsImageRenderer(size: size, format: format)
        return r.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
