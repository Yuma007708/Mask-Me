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

    /// エディタ下部のカスタムタブ（今後拡張）。
    public enum EffectTab: String, CaseIterable, Identifiable {
        case face
        case background
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .face: return "顔"
            case .background: return "背景"
            }
        }
    }

    /// Undo/Redo 用の編集スナップショット。
    struct EditSnapshot: Equatable {
        var faceMosaicOn: Bool
        var backgroundMosaicOn: Bool
        var faceBlockSize: Float
        var backgroundBlockSize: Float
        var selectedFaceIDs: Set<UUID>
        var manualRects: [CGRect]
    }

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

    // コントロール（効果ごと）
    @Published public var faceMosaicOn = true
    @Published public var backgroundMosaicOn = false
    @Published public var faceBlockSize: Float = 28
    @Published public var backgroundBlockSize: Float = 28
    /// 選択中タブ（nil＝未選択：調整バーは非表示）。
    @Published public var activeTab: EffectTab?

    // Undo / Redo（スタックの空判定から導出。スタックは @Published なので
    // 変化時に objectWillChange が発火し、UI は最新の値を読み直す）
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

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
    /// Source video URL (for saving a resumable draft).
    public private(set) var sourceVideoURL: URL?
    private(set) var detectionCache: [Double: [FaceLandmarkSet]] = [:]
    private(set) var previewController: MosaicPreviewController?
    private var cancellables: Set<AnyCancellable> = []
    private var scanTask: Task<Void, Never>?

    private let edgeSoftness: Float = 0.35

    // 背景セグメンテーション
    #if canImport(Vision)
    private let segmenter = PersonSegmenter(quality: .balanced)
    #endif
    /// 現在の静止プレビューフレームに対する背景マスク（人物前景を反転）。
    private var backgroundMask: MaskBuffer?
    /// 背景マスクを計算する元フレーム。背景タブを後から ON にしたときに再計算できるよう保持する。
    private var backgroundMaskSource: UIImage?

    // Undo / Redo
    @Published private var undoStack: [EditSnapshot] = []
    @Published private var redoStack: [EditSnapshot] = []
    private var lastCommitted: EditSnapshot?

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
        let changes: [AnyPublisher<Void, Never>] = [
            $faceMosaicOn.map { _ in () }.eraseToAnyPublisher(),
            $backgroundMosaicOn.map { _ in () }.eraseToAnyPublisher(),
            $faceBlockSize.map { _ in () }.eraseToAnyPublisher(),
            $backgroundBlockSize.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
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
                       isSelected: false)
        }
        manualRegions = []
        sourceTexture = makeTexture(from: normalized)
        updateBackgroundMask(from: normalized)
        renderer?.reset()
        renderPreview()
        resetHistory()
        isLoading = false
    }

    public func load(videoURL url: URL) {
        isLoading = true
        sourceVideoURL = url
        let asset = AVAsset(url: url)
        videoAsset = asset

        if let frame = Self.firstFrame(of: asset) {
            sourceImage = frame
            let faces = landmarker.allLandmarks(in: frame, timestampMs: 0)
            detectedFaces = faces.map { lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: frame),
                           isSelected: false)
            }
            sourceTexture = makeTexture(from: frame)
            updateBackgroundMask(from: frame)
        }
        manualRegions = []

        Task {
            videoDuration = (try? await asset.load(.duration))?.seconds ?? 0
        }

        renderer?.reset()
        renderPreview()
        resetHistory()
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
        commitEdit()
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
                return FaceTarget(id: UUID(), landmarks: remapped, thumbnail: thumb, isSelected: false)
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
            detectedFaces.append(FaceTarget(id: UUID(), landmarks: landmarks, thumbnail: thumb, isSelected: false))
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
        commitEdit()
    }

    public func removeManualRegion(_ id: UUID) {
        manualRegions.removeAll { $0.id == id }
        renderPreview()
        previewController?.invalidate()
        commitEdit()
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
                    updateBackgroundMask(from: frame)
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
                           isSelected: false)
            }
            sourceImage = frame
            sourceTexture = makeTexture(from: frame)
            updateBackgroundMask(from: frame)
            renderPreview()
            previewController?.invalidate()
        }
    }

    // MARK: - レンダリング

    func renderPreview() {
        guard let renderer, let tex = sourceTexture else { return }
        applyControls(to: renderer)

        var current = tex

        // 顔モザイク（立体メッシュ）＋手動矩形。
        // 手動矩形は顔検出を補助するものなので、顔タブ（faceMosaicOn）の状態に従う。
        if faceMosaicOn {
            let landmarks = detectedFaces.filter(\.isSelected).map(\.landmarks)
            let extra = manualRegionPaths(for: CGSize(width: tex.width, height: tex.height))
            if let result = renderer.renderToNewTexture(
                input: current, landmarkSets: landmarks, additionalPaths: extra
            ) {
                current = result.texture
            }
        }

        // 背景モザイク（平面）。人物前景を反転したマスクで背景だけを処理。
        if backgroundMosaicOn, let mask = backgroundMask {
            if let out = renderer.renderBackgroundToNewTexture(
                input: current,
                mask: mask,
                block: backgroundBlockSize
            ) {
                current = out
            }
        }

        if let cg = MetalTextureUtilities.cgImage(from: current) {
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
        guard faceMosaicOn else { return [] }
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
        // video モードスキャナー: temporal tracking で連続フレームの検出精度を上げる
        let scanner = makeFaceLandmarker(forVideo: true)
        // クロップ検出は独立した image モードスキャナーで行う
        // （video モードスキャナーの timestamp 系列を乱さないため）
        let cropScanner = makeFaceLandmarker(forVideo: false)
        let initialFaceCount = detectedFaces.count
        // ManualRegion の矩形をバックグラウンドスレッドに渡す（値型なので安全）
        let cropRects = manualRegions.map(\.normalizedRect)

        scanTask = Task.detached(priority: .background) { [weak self, scanner, cropScanner, asset, initialFaceCount, cropRects] in
            await self?.runPreScan(
                asset: asset, scanner: scanner, cropScanner: cropScanner,
                expectedFaceCount: initialFaceCount, cropRects: cropRects
            )
        }
    }

    nonisolated private func runPreScan(
        asset: AVAsset,
        scanner: FaceLandmarking,
        cropScanner: FaceLandmarking,
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
                // video モードで temporal tracking を活用しながら検出
                var faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))

                // ManualRegion の矩形クロップでも検出を試みる（小さい顔や検出しにくい顔への対応）
                // クロップは image モードスキャナーを使用（video モードの timestamp 系列を保護）
                for rect in cropRects {
                    let pixelRect = CGRect(
                        x: rect.origin.x * CGFloat(cg.width),
                        y: rect.origin.y * CGFloat(cg.height),
                        width: rect.width  * CGFloat(cg.width),
                        height: rect.height * CGFloat(cg.height)
                    )
                    if let crop = cg.cropping(to: pixelRect) {
                        let cropFaces = cropScanner.allLandmarks(in: UIImage(cgImage: crop))
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

    // MARK: - 下書き（状態保持・再開）

    /// 写真下書き保存用の元画像（向き補正済み）。
    public var photoSourceImage: UIImage? { sourceImage }

    /// 現在の手動矩形（正規化座標）。
    public var manualRects: [CGRect] { manualRegions.map(\.normalizedRect) }

    /// 下書きから復元したパラメータを適用してプレビューを更新する。
    public func applyRestoredParameters(
        faceMosaicOn: Bool,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect]
    ) {
        self.faceMosaicOn = faceMosaicOn
        self.backgroundMosaicOn = backgroundMosaicOn
        self.faceBlockSize = faceBlockSize
        self.backgroundBlockSize = backgroundBlockSize
        self.manualRegions = manualRects.map { ManualRegion(id: UUID(), normalizedRect: $0) }
        recomputeBackgroundMask()
        renderPreview()
        previewController?.invalidate()
        resetHistory()
    }

    // MARK: - タブ操作・確定（UI から呼ぶ）

    /// タブをタップ：未選択なら選択（効果ON＋調整バー表示）、選択中の同じタブなら効果OFF＋閉じる。
    public func tapTab(_ tab: EffectTab) {
        if activeTab == tab {
            setEffect(tab, on: false)
            activeTab = nil
        } else {
            activeTab = tab
            setEffect(tab, on: true)
        }
    }

    private func setEffect(_ tab: EffectTab, on: Bool) {
        switch tab {
        case .face: faceMosaicOn = on
        case .background:
            backgroundMosaicOn = on
            // 背景を ON にした時点で（保持中フレームから）マスクを用意する。
            recomputeBackgroundMask()
        }
        commitEdit()
    }

    /// 調整バーの粗さ（選択中タブ）への双方向バインディング。
    public var activeBlockSize: Float {
        get {
            switch activeTab {
            case .background: return backgroundBlockSize
            default: return faceBlockSize
            }
        }
        set {
            switch activeTab {
            case .background: backgroundBlockSize = newValue
            default: faceBlockSize = newValue
            }
        }
    }

    /// 調整バーの確定チェック：現在の状態を編集履歴に確定する。
    public func confirmAdjustment() {
        commitEdit()
        activeTab = nil
    }

    // MARK: - Undo / Redo

    private func snapshot() -> EditSnapshot {
        EditSnapshot(
            faceMosaicOn: faceMosaicOn,
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            selectedFaceIDs: Set(detectedFaces.filter(\.isSelected).map(\.id)),
            manualRects: manualRegions.map(\.normalizedRect)
        )
    }

    private func apply(_ snap: EditSnapshot) {
        faceMosaicOn = snap.faceMosaicOn
        backgroundMosaicOn = snap.backgroundMosaicOn
        faceBlockSize = snap.faceBlockSize
        backgroundBlockSize = snap.backgroundBlockSize
        for index in detectedFaces.indices {
            detectedFaces[index].isSelected = snap.selectedFaceIDs.contains(detectedFaces[index].id)
        }
        manualRegions = snap.manualRects.map { ManualRegion(id: UUID(), normalizedRect: $0) }
        recomputeBackgroundMask()
        renderPreview()
        previewController?.invalidate()
    }

    /// 編集履歴の基準を現在状態にリセット（メディア読み込み・復元時）。
    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCommitted = snapshot()
    }

    /// 直前確定からの変化があれば履歴に積む。
    func commitEdit() {
        let now = snapshot()
        guard now != lastCommitted else { return }
        if let last = lastCommitted { undoStack.append(last) }
        redoStack.removeAll()
        lastCommitted = now
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(lastCommitted ?? snapshot())
        lastCommitted = previous
        apply(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        if let last = lastCommitted { undoStack.append(last) }
        lastCommitted = next
        apply(next)
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
                faceEnabled: faceMosaicOn,
                backgroundEnabled: backgroundMosaicOn,
                backgroundBlock: backgroundBlockSize
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
        renderer.params = MosaicParams(block: faceBlockSize, edgeSoftness: edgeSoftness)
        renderer.enabledRegions = [.faceOval]
    }

    /// 静止プレビュー用フレームを保持し、背景マスクを更新する（人物前景を反転）。
    private func updateBackgroundMask(from image: UIImage) {
        backgroundMaskSource = image
        recomputeBackgroundMask()
    }

    /// 保持中のフレームから背景マスクを計算する。
    /// 背景モザイクが OFF のときは Vision を実行しない（読み込み・シーク毎の重い無駄処理を避ける）。
    private func recomputeBackgroundMask() {
        #if canImport(Vision)
        guard backgroundMosaicOn, let cg = backgroundMaskSource?.cgImage else {
            backgroundMask = nil
            return
        }
        backgroundMask = segmenter.backgroundMask(cgImage: cg)
        #else
        backgroundMask = nil
        #endif
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
