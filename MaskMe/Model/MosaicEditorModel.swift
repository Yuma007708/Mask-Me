import AVFoundation
import Combine
import CoreImage
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
    /// 動画の書き出し対象範囲（0...1 正規化）。タイムラインの左右ハンドルで調整。
    /// エクスポート時は `AVAssetReaderTrackOutput` からのフレームのうち、
    /// この範囲外の `presentationTime` をスキップして出力尺を短縮する。
    @Published public var trimRange: ClosedRange<Double> = 0...1

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
    /// エクスポートの速度／品質段。既定は標準。UI から変更可能。
    @Published public var exportSpeed: ExportSpeed = .balanced
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

    private let detectionSettings: DetectionSettings

    public init(
        mode: Mode,
        recents: RecentItemsStore,
        landmarker: FaceLandmarking? = nil,
        settings: DetectionSettings = DetectionSettings()
    ) {
        self.mode = mode
        self.recents = recents
        self.detectionSettings = settings
        self.landmarker = landmarker ?? makeFaceLandmarker(forVideo: mode == .video, settings: settings)
        // smoothing 0.35 は TrackingEvaluator のデフォルト。confidence が連続値化された
        // ことで境界フレーム（横顔・小顔）が 0.3〜0.7 の中間値で入るため、EMA を効かせて
        // TrackingBadge のちらつきを抑える。以前は 1.0（EMA無効）にして「動画で遅延が
        // 気になる」を回避していたが、Kalman ROI 予測と連続 confidence の導入で不要になった。
        self.renderer = try? MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 0.35))

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
        detectedFaces = faces.enumerated().map { idx, lm in
            // 顔が1つならタップ不要で即モザイクする（動画側と挙動を揃える）。
            let autoSelect = faces.count == 1 && idx == 0
            return FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalized),
                       isSelected: autoSelect)
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
        // 新しい動画では全長を選択に戻す。前の動画のトリムが残ると意図しない範囲書き出しになる。
        trimRange = 0...1
        let asset = AVAsset(url: url)
        videoAsset = asset

        if let frame = Self.firstFrame(of: asset) {
            sourceImage = frame
            sourceTexture = makeTexture(from: frame)
            updateBackgroundMask(from: frame)

            // 最初の1フレームを単独検出するのは IMAGE モードの仕事。
            // VIDEO モードは連続ストリームの時系列追跡用で、最初のフレームを
            // 単体で処理するのが苦手（init 失敗 → NullFaceLandmarker になるケースも）。
            let initialScanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)

            // t=0 の初期フレームに顔が写っていない動画（画面録画の導入カット等）だと
            // ここで空になり、再生開始でモザイクが消え・追従バッジが「探索中 0%」に落ちる。
            // 実機で「顔サムネ100%だが探索中0%、シークで初めて検出」と報告される症状の中核。
            // → 空だった場合は数秒先まで低fpsで探索し、最初に顔が取れたフレームを
            //   サムネ／検出シード用フレームとして採用する（プレビューは先頭フレームのまま）。
            // 実機のライブ検出は 480px 幅の縮小フレームで走る（MosaicPreviewController
            // 参照）。初期スキャンをフル解像度で通してしまうと「初期はシードされるが
            // 続くライブ検出では拾えない」という条件差が生まれ、ホールドフォールバック
            // が古い顔位置を体に貼り続ける原因になる。ライブと同じ 480px で判定する。
            var faces = initialScanner.allLandmarks(in: Self.downscaleForDetection(frame))
            var seedFrame = frame
            var seedTime = 0.0
            // 短尺動画（リール等）は顔が終盤にしか写らないことがある。3s 固定 probe だと
            // 例えば 4s 動画で顔を逃す → シードなし → 再生開始でモザイクが掛からない。
            // 動画長に合わせて probe 範囲を可変にする（上限 6s、下限は動画全長）。
            if faces.isEmpty {
                // 同期取得（load(videoURL:) は同期）。CMTime.seconds が nan の動画があるので
                // isFinite/正数チェックで守る。
                let rawDur = CMTimeGetSeconds(asset.duration)
                let dur = (rawDur.isFinite && rawDur > 0) ? rawDur : 3.0
                let probeEnd = min(max(dur - 0.1, 0.25), 6.0)
                for probeTime in stride(from: 0.25, through: probeEnd, by: 0.25) {
                    guard let probeFrame = Self.frame(of: asset, at: probeTime) else { continue }
                    let probeFaces = initialScanner.allLandmarks(in: Self.downscaleForDetection(probeFrame))
                    if !probeFaces.isEmpty {
                        faces = probeFaces
                        seedFrame = probeFrame
                        seedTime = probeTime
                        break
                    }
                }
            }

            // 初期スキャン結果を「実際に顔が写っていた時刻」のバケットにシードして、
            // 再生開始・スクラブ前でも MosaicPreviewController がランドマークを引ける
            // ようにする。seedTime>0（先頭に顔なし）のとき t=0 に入れてはいけない:
            // 未来の顔位置を冒頭フレームに描くことになり、顔がまだ無い場所（体や背景）
            // にモザイクが乗る。t=0 に顔が無い事実はライブ検出が空エントリとして
            // 記録し、ホールドフォールバックはそれを尊重して描かない。
            if !faces.isEmpty {
                detectionCache[liveBucket(seedTime)] = faces
            }
            detectedFaces = faces.enumerated().map { idx, lm in
                // 顔が1つだけならユーザーの意図として自動選択する（サムネを
                // タップさせないと何も起きない不親切な挙動を避ける）。複数顔なら
                // 「どれをモザイクするか」の選択余地を残す。
                let autoSelect = faces.count == 1 && idx == 0
                return FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: seedFrame),
                           isSelected: autoSelect)
            }
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
        // 事前スキャンは廃止。再生しながらプレビューのフレームに検出を相乗りさせて
        // detectionCache を埋める（ライブ検出）。詳細は「ライブ検出」セクション参照。
        resetLiveDetection()
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
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
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
        // 動画: 追加した顔は再生しながらのライブ検出で全フレーム追跡する（%はリセットして育て直す）。
        if mode == .video { resetLiveDetection() }
    }

    /// 矩形内クロップが現在フレームで失敗したとき: 動画全体を1fpsでサーチして顔を探す。
    /// 見つかれば FaceTarget として追加（追跡可能）。全フレームで失敗なら固定矩形マスク。
    private func resolveRegion(_ rect: CGRect, referenceImage: UIImage?) async {
        guard mode == .video, let asset = videoAsset else {
            appendManualRect(rect)
            return
        }
        isScanning = true
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
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

    /// タイムライン・スクラブ用: 直前の未完了シーク要求をキャンセルして最新のみ処理する。
    /// ドラッグ中の連続発火に対して、`seekTo` を毎回 await するとキューが詰まって
    /// プレビュー反応が遅れるため、常に最新1件のみに絞る。
    public func seekToLatest(position: Double) {
        playbackPosition = position
        previewController?.seekLatest(to: position)
    }


    // MARK: - 手動再検出（動画: 現在シーク位置で再検出）

    public func redetect(at position: Double) async {
        guard let asset = videoAsset, videoDuration > 0 else { return }
        let t = position * videoDuration
        guard let frame = Self.frame(of: asset, at: t) else { return }

        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
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

    /// 指定時刻の顔ランドマークを返す。補間の仕様は `DetectionBridge` を参照
    /// （プレビュー・エクスポート・精度計測で共通の挙動）。lerp 有効:
    /// ブリッジ区間の顔が before 位置のホールドではなく前後の中間位置になめらかに動く。
    ///
    /// フォールバック: DetectionBridge は "前後両側に検出がある" ことを要求するため、
    /// 再生開始直後・シーク直後の "初期スキャンしかまだ入っていない" 状態や、ライブ検出
    /// が数百ms遅れた状態では空を返しがち。それだと Play を押した瞬間に "モザイクが
    /// 消える → 追従バッジ探索中0%" になり "使い物にならない"。
    /// そこで、bridge が成立しないときは `fallbackWindow` 秒以内の直近検出を一方向で
    /// ホールドする。これは PREVIEW 専用で、エクスポート側は `VideoMosaicExporter` が
    /// 自前の bridge を持つため影響しない。
    func lookupFaces(at time: Double) -> [FaceLandmarkSet] {
        let bridged = DetectionBridge(interpolates: true).faces(in: detectionCache, at: time)
        if !bridged.isEmpty { return bridged }
        return nearestCachedFaces(at: time, window: 0.75)
    }

    /// `detectionCache` のうち時刻 `time` から `window` 秒以内で最も近い
    /// 「スキャン済み」バケットの顔リストを返す。
    ///
    /// 重要: 空エントリ（スキャン済みで顔なし）もバケット選択の対象にする。
    /// 最寄りのスキャン結果が「顔なし」なら空を返す＝ホールドしない。これが無いと
    /// 「2秒前の顔位置を、顔が居ないと判明しているフレームに描き続ける」ことになり、
    /// 動いている人の体の上にモザイクが乗る・位置がずれる誤描画の原因になる。
    /// window は「ライブ検出がまだ追いついていない直近区間」を埋めるためだけの短い値。
    private func nearestCachedFaces(at time: Double, window: Double) -> [FaceLandmarkSet] {
        var best: (dist: Double, faces: [FaceLandmarkSet])?
        for (t, faces) in detectionCache {
            let d = abs(t - time)
            if d > window { continue }
            if best == nil || d < best!.dist { best = (d, faces) }
        }
        return best?.faces ?? []
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

    // MARK: - ライブ検出（再生フレームに相乗り）

    // 事前スキャンは廃止した。動画全編を先に検出するとフレーム数ぶんの MediaPipe 検出で
    // 実機で1〜2分待たされ、さらにスキャン用 AVAssetImageGenerator が再生用 AVPlayer と
    // ハードウェアデコーダを奪い合って途中で全滅していた（別デコーダの同時使用が原因）。
    // 代わりに、プレビューが既にデコード済みのフレームへ検出を相乗りさせ、再生しながら
    // detectionCache を埋める。検出は表示スレッドを塞がないよう常に1枚だけバックグラウンドで
    // 走らせ、再生中は最新フレームを間引く。エクスポートは未検出区間を自前でその場検出できる
    // ため、この変更で最終出力の品質は変わらない。
    // シークで時系列が巻き戻っても破綻しないよう、ライブ検出は IMAGE モードスキャナーを使う
    // （検出漏れフレームは DetectionBridge の両側補間でブリッジされる）。
    private lazy var liveScanner: FaceLandmarking =
        makeFaceLandmarker(forVideo: false, settings: detectionSettings)
    private let liveDetectionQueue =
        DispatchQueue(label: "com.maskme.livedetection", qos: .userInitiated)
    /// 検出は同時に1枚だけ。表示スレッドを塞がないための in-flight ガード。
    private var liveDetectionInFlight = false
    /// detectionCache のバケット解像度（fps）。同一バケットは再検出しない（ループ再生で無駄検出しない）。
    private let liveBucketFPS = 15.0
    private var liveMatchCounts: [Int] = []
    private var liveSampleCount = 0

    private func liveBucket(_ timeSec: Double) -> Double {
        (timeSec * liveBucketFPS).rounded() / liveBucketFPS
    }

    /// テスト専用: 「この時刻をスキャンしたが顔は無かった」状態を再現する。
    /// ライブ検出の空エントリ記録（storeLiveDetection）と同じ意味のキャッシュ状態を作る。
    func recordScannedEmptyForTesting(at timeSec: Double) {
        detectionCache[liveBucket(timeSec)] = []
    }

    /// 動画読み込み・顔追加時にライブ検出の集計状態をリセットする。
    private func resetLiveDetection() {
        liveMatchCounts = []
        liveSampleCount = 0
        liveDetectionInFlight = false
    }

    /// プレビューがこの時刻のフレームを検出すべきか（表示スレッドから安価に判定する）。
    /// 既に同バケットを検出済み・検出中・顔タブOFF・写真モードのときはスキップ。
    func shouldDetectPreviewFrame(at timeSec: Double) -> Bool {
        guard mode == .video, faceMosaicOn, !liveDetectionInFlight else { return false }
        return detectionCache[liveBucket(timeSec)] == nil
    }

    /// プレビューのデコード済みフレーム（検出用に縮小済み CGImage）を受け取り、
    /// バックグラウンドで顔検出して detectionCache を埋める。
    func submitPreviewFrameForDetection(_ cgImage: CGImage, at timeSec: Double) {
        guard !liveDetectionInFlight else { return }
        liveDetectionInFlight = true
        let bucket = liveBucket(timeSec)
        liveDetectionQueue.async { [weak self, liveScanner] in
            let img = UIImage(cgImage: cgImage)
            let faces = liveScanner.allLandmarks(in: img)
            Task { @MainActor in
                self?.storeLiveDetection(faces, at: bucket, source: img)
            }
        }
    }

    @MainActor
    private func storeLiveDetection(_ faces: [FaceLandmarkSet], at t: Double, source: UIImage) {
        liveDetectionInFlight = false
        // 空の結果も保存する。「スキャン済みで顔なし」という事実が残らないと、
        // lookupFaces のホールドフォールバックが古い顔位置をこのフレームに描き続けて
        // 「体にモザイクが乗る／モザイクがずれる」誤描画になる。また、空を記録する
        // ことで shouldDetectPreviewFrame が同じ顔なしフレームを再スキャンし続ける
        // 無駄も止まる（DetectionBridge / nearestCachedFaces は空エントリを無視する）。
        detectionCache[t] = faces
        // ポーズ中のシーク先で検出が終わったとき、次の displayLink を待たずに
        // モザイクを反映する（再生中は毎フレーム描画されるので実質無害）。
        previewController?.invalidate()
        guard !faces.isEmpty else { return }

        // 先頭フレーム検出が失敗して顔候補が空だった場合の安全網。
        if detectedFaces.isEmpty {
            detectedFaces = faces.map { lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: source),
                           isSelected: false)
            }
        }

        // 検出率%を再生しながら育てる（各顔が見つかったフレームの割合）。
        liveSampleCount += 1
        while liveMatchCounts.count < detectedFaces.count { liveMatchCounts.append(0) }
        for (i, target) in detectedFaces.enumerated() {
            let tc = normalizedCentroid(of: target.landmarks)
            if faces.contains(where: { face in
                let fc = normalizedCentroid(of: face)
                return hypot(fc.x - tc.x, fc.y - tc.y) < 0.5
            }) {
                liveMatchCounts[i] += 1
            }
            detectedFaces[i].detectionRate =
                Double(liveMatchCounts[i]) / Double(liveSampleCount) * 100
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
        do { dur = try await asset.load(.duration).seconds } catch {
            print("[MMSCAN] EARLY-RETURN: duration load failed: \(error)")
            return
        }
        print("[MMSCAN] start dur=\(dur) expectedFaces=\(expectedFaceCount) cropRects=\(cropRects.count)")
        guard dur > 0 else {
            print("[MMSCAN] EARLY-RETURN: dur<=0 (\(dur))")
            return
        }

        let interval = 1.0 / 15.0   // 15fps（動きの速い顔と短時間アウトインの追従向上）
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval, preferredTimescale: 600)

        var sampleCount = 0
        var matchCounts = [Int](repeating: 0, count: max(expectedFaceCount, 1))

        var t = 0.0
        while t <= dur {
            guard !Task.isCancelled else { return }
            // 再生中はハードウェアデコーダをプレビュー(AVPlayer)に明け渡す。スキャン用
            // AVAssetImageGenerator と同時にデコーダを奪い合うと、実機では数秒後から
            // copyCGImage が nil を返し続けスキャンが全滅する（再生していなければ最後まで
            // 通ることを実機ログで確認済み）。再生が止まったら中断地点から自然に再開する。
            while await MainActor.run(body: { [weak self] in self?.isPlaying ?? false }) {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            // 各フレームで AVFoundation / MediaPipe が生成する autorelease 中間バッファを
            // 毎フレーム解放する。これが無いと full-res フレーム（例: 588×1280）と検出中間
            // バッファが蓄積し、実機のハードウェアデコーダがメモリ圧で失敗して copyCGImage が
            // 数秒後から nil を返し始め、スキャンが途中で全滅する（キャッシュが冒頭数秒しか
            // 埋まらず、再生時にほぼモザイクが出ない）。CI/DValidVideoTests は autoreleasepool を
            // 使っているためこの症状は再現しない。
            let frame: (faces: [FaceLandmarkSet], img: UIImage)? = autoreleasepool {
                let cg: CGImage
                do {
                    cg = try generator.copyCGImage(at: cmTime, actualTime: nil)
                } catch {
                    let ns = error as NSError
                    print("[MMSCAN] t=\(String(format: "%.2f", t)) copyCGImage=NIL domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                    return nil
                }
                let img = UIImage(cgImage: cg)
                // video モードで temporal tracking を活用しながら検出
                var faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                if sampleCount < 10 || sampleCount % 15 == 0 {
                    print("[MMSCAN] t=\(String(format: "%.2f", t)) sample=\(sampleCount) faces=\(faces.count) imgPx=\(cg.width)x\(cg.height)")
                }

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
                return (faces, img)
            }
            guard let frame else { t += interval; continue }
            let faces = frame.faces
            let img = frame.img

            sampleCount += 1
            let facesForCache = faces
            let timeForCache = t
            let matchCountsCopy = matchCounts
            let updated = await MainActor.run { [weak self, img] () -> [Int] in
                // 空結果はキャッシュしない（直前の有効検出を再利用させる）
                if !facesForCache.isEmpty {
                    self?.detectionCache[timeForCache] = facesForCache
                }
                guard let self else { return matchCountsCopy }
                // 初期フレーム検出が失敗して detectedFaces が空のまま残っている場合、
                // プリスキャンで最初に見つかった顔を補完する（安全網）。
                if !facesForCache.isEmpty && self.detectedFaces.isEmpty {
                    self.detectedFaces = facesForCache.map { lm in
                        FaceTarget(id: UUID(), landmarks: lm,
                                   thumbnail: self.generateThumbnail(for: lm, from: img),
                                   isSelected: false)
                    }
                }
                var counts = matchCountsCopy
                // detectedFaces がプリスキャン中に安全網で追加された場合に備えて配列を拡張する
                while counts.count < self.detectedFaces.count { counts.append(0) }
                for (i, target) in self.detectedFaces.enumerated() {
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
            t += interval
        }

        let finalSampleCount = sampleCount
        let finalMatchCounts = matchCounts
        await MainActor.run { [weak self] in
            guard let self else { return }
            print("[MMSCAN] DONE samples=\(finalSampleCount) cacheEntries=\(self.detectionCache.count) detectedFaces=\(self.detectedFaces.count)")
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
                backgroundBlock: backgroundBlockSize,
                speed: exportSpeed,
                trimRange: trimRange
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

    /// 実機ライブ検出と同じ 480px 幅の縮小 CGImage を返す。
    /// `MosaicPreviewController.detectionCGImage(from:)` と同じスケール規則。
    private static let detectionCIContext = CIContext()
    static func downscaleForDetection(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let target = 480.0
        let scale = min(target / Double(cg.width), 1.0)
        guard scale < 0.99 else { return image }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let out = detectionCIContext.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: out, scale: 1, orientation: image.imageOrientation)
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
