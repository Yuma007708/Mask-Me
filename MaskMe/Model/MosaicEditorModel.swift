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
    // detectedFaces / isScanning: 元は `private(set)` だったが、ライブ検出関連の
    // 書き込みを `MosaicEditorModel+LiveDetection.swift` に切り出したため、
    // 同一ファイル限定の `private(set)` では書き込めなくなり `internal(set)` に緩めた
    // （詳細は Task B1 の private→internal 変更一覧を参照）。
    @Published public internal(set) var detectedFaces: [FaceTarget] = []
    @Published public var manualRegions: [ManualRegion] = []
    @Published public internal(set) var isScanning = false

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
    /// この編集画面が扱う素材の識別子。クリップの有無とは独立に存在する。
    ///
    /// 素材の「同一性」は、その素材をどの範囲使うか（= クリップ）とは別の概念である。
    /// 動画ロード前でもキャッシュ操作が成立するよう、init で確定させる。
    let currentSourceID = UUID()
    /// 素材基準の検出キャッシュ。クラス全体が @MainActor なので同期機構は不要。
    let cacheStore = DetectionCacheStore(bucketFPS: 15.0)
    /// タイムライン上のクリップ列。フェーズ1では常に1要素。
    @Published private(set) var clips: [TimelineClip] = []
    /// 素材IDから AVAsset への対応表。
    private var sources: [UUID: AVAsset] = [:]
    /// クリップ列から構築した合成結果。プレビューと書き出しで同じものを使い回す。
    ///
    /// **不変条件（フェーズ1限定）: `composition` は `videoAsset` と時間軸が一致する。**
    /// フェーズ1のクリップ列は「素材全体を使う1本」しか無いため、
    /// composition 上の時刻 t と videoAsset 上の時刻 t は同じフレームを指す。
    /// この前提のもとで、資産を2つ並存させて用途で使い分けている:
    ///
    /// - `videoAsset`: サムネ生成とスクラブ時のフレーム抽出（`AVAssetImageGenerator`
    ///   系の同期取り出し。Composition 経由より素材直読みのほうが速く確実）
    /// - `composition`: 再生（`AVPlayerItem`）と書き出し（`AVAssetReader`）
    ///
    /// **フェーズ2でどこが壊れるか:**
    /// トリム・並べ替え・複数素材のいずれかが入った瞬間に上の一致は崩れる。
    /// 具体的には、composition 時刻 t に対応する素材と素材内時刻を解決する
    /// 写像が必要になり、以下が全て誤フレームを返すようになる:
    ///   - `seekTo(position:)` のフレーム抽出（`videoAsset` を composition 時刻で引く）
    ///   - `redetect(at:)` の再検出フレーム
    ///   - 検出キャッシュのキー（素材基準の時刻で持っているため、composition 時刻で
    ///     引くと別クリップの結果を拾う）
    ///   - `resolveRegion(_:referenceImage:)` / `findFaceInVideo(asset:rect:scanner:)`
    ///     （矩形から動画全体を1fps走査する経路）。`videoAsset` を直接渡して素材全体を
    ///     舐めるため、クリップ列が素材の一部しか使わなくなると「タイムラインに存在
    ///     しない区間」で顔を拾い、composition 上に対応時刻の無い結果を返す
    /// そのため、フェーズ2では `videoAsset` の直接参照を全て
    /// `TimelineMapping.sourceLocation(at:)` 相当の写像経由に置き換える必要がある。
    private var composition: AVMutableComposition?
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
                cacheStore.store(faces, sourceID: currentSourceID, time: seedTime)
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
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = seconds

            // フェーズ1では素材全体を使う単一クリップ。
            sources = [currentSourceID: asset]
            clips = [TimelineClip(sourceID: currentSourceID,
                                  sourceStart: 0, sourceEnd: seconds)]

            // Composition の構築は renderer の有無と無関係に行う。
            // renderer が nil でも書き出し（composition 依存）は成立させたいので、
            // 「renderer が無い ＝ composition も無い」という巻き添えを作らない。
            do {
                let built = try await TimelineCompositionBuilder()
                    .build(clips: clips, sources: sources)
                composition = built
                if let r = renderer {
                    previewController = MosaicPreviewController(
                        renderer: r, asset: built, model: self)
                }
            } catch {
                errorMessage = "動画の読み込みに失敗しました"
            }
            // 成功・失敗どちらの経路でも必ず解除する。ここより前に解除すると
            // 「読み込み完了表示なのに previewController がまだ nil」の窓ができ、
            // 再生ボタンの表示と実挙動がずれる（togglePlayback 側でも二重に防ぐ）。
            isLoading = false
        }

        // 以下は Composition ではなく先頭フレーム（sourceTexture）に対する処理なので
        // Composition 構築の完了を待たない。待たせるとプレビューの初期表示が
        // 素材ロード遅延ぶん遅れて、静止画モードとの体感差になる。
        renderer?.reset()
        renderPreview()
        resetHistory()
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
                // ユーザーが矩形を描いた意図は「この顔にモザイクを掛けたい」なので
                // 即選択する（false だとサムネをもう一度タップするまで何も起きない）。
                return FaceTarget(id: UUID(), landmarks: remapped, thumbnail: thumb, isSelected: true)
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
            // 矩形を描いた意図に合わせて即選択（上の resolveRegion 直検出と同じ理由）。
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
        // previewController が未構築（Composition 構築中）の間は状態を進めない。
        // 進めると play() が no-op なのに isPlaying だけ true になり、
        // 「UI は再生中・映像は停止」のずれが起きて2回押さないと復帰できない。
        guard let controller = previewController else { return }
        if isPlaying {
            controller.pause()
            isPlaying = false
        } else {
            controller.play()
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
        // キーはライブ検出と同じ 15fps バケットに正規化する（storePreScanResult の
        // doc コメント参照。生 t のままだとライブの空エントリを上書きできない）。
        storePreScanResult(found, at: t)

        if !found.isEmpty {
            // 旧: 全員 isSelected: false で置き換えていた。モザイクが外れた時に
            // ユーザーが押すボタンで選択が全消去され「以降一切モザイクがかからない」
            // 実機報告の直接原因だった。選択状態は重心マッチで引き継ぎ、誰も選択
            // されない結果になる場合は全選択にフォールバックする（このボタンを押す
            // 意図は常に「顔にモザイクを掛けたい」なので、消える方向に倒さない）。
            detectedFaces = carryingOverSelection(
                found.map { lm in
                    FaceTarget(id: UUID(), landmarks: lm,
                               thumbnail: generateThumbnail(for: lm, from: frame),
                               isSelected: false)
                },
                previousSelected: detectedFaces.filter(\.isSelected)
            )
            sourceImage = frame
            sourceTexture = makeTexture(from: frame)
            updateBackgroundMask(from: frame)
            renderPreview()
            previewController?.invalidate()
        }
    }

    /// redetect 用の選択引き継ぎ。新しい顔候補に旧選択状態を重心マッチ（<0.5）で
    /// 引き継ぎ、誰も選択されない結果になる場合は全選択にフォールバックする。
    /// 「再検出」を押す意図は常に「顔にモザイクを掛けたい」なので、選択が空になって
    /// 以降モザイクが一切掛からなくなる方向には決して倒さない（フェイルクローズ）。
    func carryingOverSelection(
        _ newFaces: [FaceTarget],
        previousSelected: [FaceTarget]
    ) -> [FaceTarget] {
        var result = newFaces
        for i in result.indices {
            let fc = normalizedCentroid(of: result[i].landmarks)
            result[i].isSelected = previousSelected.contains { sel in
                let sc = normalizedCentroid(of: sel.landmarks)
                return hypot(fc.x - sc.x, fc.y - sc.y) < 0.5
            }
        }
        if !result.contains(where: \.isSelected) {
            for i in result.indices { result[i].isSelected = true }
        }
        return result
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
    //
    // 検出キャッシュそのものを引く実装（lookupFaces / nearestCachedFaces /
    // nearestNonEmptyCachedFaces / sourceScopedCache）は
    // `MosaicEditorModel+DetectionCache.swift` に切り出した。
    // `blinkHoldWindow` と `liveFlowCache` は格納プロパティのため（Swift の
    // extension は格納インスタンスプロパティを持てない）、参照元の
    // `lookupFaces` が別ファイルへ移った後もここに残っている。

    /// 瞬きブリッジのホールド幅（秒）。瞬き＋モーションブラーの検出落ちは
    /// 15fps バケットで 1〜3 個（≦0.2s）に収まる実測に基づく。
    ///
    /// **アクセスレベル変更**: 元は `private let` だったが、`lookupFaces`
    /// （`MosaicEditorModel+DetectionCache.swift`）から参照されるため
    /// `internal`（無印）にした。
    let blinkHoldWindow = 0.25

    /// フロー橋渡し由来のライブ結果。実検出ではないため `detectionCache` とは分離する:
    /// エクスポート（VideoMosaicExporter）はキャッシュヒットで自前検出をスキップする
    /// ので、フロー由来を detectionCache に混ぜると書き出し品質を汚染する。
    /// 参照するのはプレビューの `lookupFaces` のみ。動画切替（resetLiveDetection）で破棄。
    ///
    /// **⚠️ フェーズ2への申し送り: 時間基準が2つ並存している。**
    /// このキャッシュのキーは **合成（composition）時刻**（プレビュー再生位置そのもの）
    /// である一方、`cacheStore` のキーは **素材時刻** である。フェーズ1では
    /// クリップが「素材全体を使う1本」しか無く両者が恒等変換で一致するため問題にならない。
    /// フェーズ2でトリム・並べ替え・複数素材が入り、`lookupFaces` の入口で合成時刻を
    /// 素材時刻へ写像するようにすると、`cacheStore` 側だけが正しくなり
    /// **`liveFlowCache` だけが合成時刻キーのまま取り残されて誤フレームの顔を返す。**
    /// 入口で一括変換して済ませず、このキャッシュの
    /// 読み書き（`nearestFlowFaces` / `storeLiveDetection`）をどちらの基準に揃えるか
    /// 明示的に決めること。
    ///
    /// **アクセスレベル変更**: 元は `private(set)` だったが、読み書きする
    /// `nearestFlowFaces` / `resetLiveDetection` / `storeLiveDetection` が
    /// `MosaicEditorModel+LiveDetection.swift` に切り出されたため `internal`
    /// （読み書き無印）にした。
    var liveFlowCache: [Double: [FaceLandmarkSet]] = [:]

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
    //
    // ふるまい本体（liveBucket / storePreScanResult / recordScannedEmptyForTesting /
    // resetLiveDetection / shouldDetectPreviewFrame / submitPreviewFrameForDetection /
    // notifyLiveSeek / storeLiveDetection / updateFacePositions / runPreScan /
    // nearestFlowFaces）は `MosaicEditorModel+LiveDetection.swift` に切り出した。
    // 以下の格納プロパティは Swift の extension が格納インスタンスプロパティを
    // 持てないため、ここに残っている。

    // 事前スキャンは廃止した。動画全編を先に検出するとフレーム数ぶんの MediaPipe 検出で
    // 実機で1〜2分待たされ、さらにスキャン用 AVAssetImageGenerator が再生用 AVPlayer と
    // ハードウェアデコーダを奪い合って途中で全滅していた（別デコーダの同時使用が原因）。
    // 代わりに、プレビューが既にデコード済みのフレームへ検出を相乗りさせ、再生しながら
    // detectionCache を埋める。検出は表示スレッドを塞がないよう常に1枚だけバックグラウンドで
    // 走らせ、再生中は最新フレームを間引く。エクスポートは未検出区間を自前でその場検出できる
    // ため、この変更で最終出力の品質は変わらない。
    // シークで時系列が巻き戻っても破綻しないよう、ライブ検出は IMAGE モードスキャナーを使う
    // （検出漏れフレームは DetectionBridge の両側補間でブリッジされる）。
    //
    // 以下6プロパティのアクセスレベル変更: 元は全て `private` だったが、
    // `MosaicEditorModel+LiveDetection.swift` に切り出した各メソッドから参照されるため
    // `internal`（無印）にした（詳細は Task B1 の private→internal 変更一覧を参照）。
    lazy var liveScanner: FaceLandmarking =
        makeFaceLandmarker(forVideo: false, settings: detectionSettings)
    let liveDetectionQueue =
        DispatchQueue(label: "com.maskme.livedetection", qos: .userInitiated)
    /// 検出は同時に1枚だけ。表示スレッドを塞がないための in-flight ガード。
    var liveDetectionInFlight = false
    /// detectionCache のバケット解像度（fps）。同一バケットは再検出しない（ループ再生で無駄検出しない）。
    let liveBucketFPS = 15.0
    var liveMatchCounts: [Int] = []
    var liveSampleCount = 0

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
        // プレビューと同じ Composition を書き出す（素の素材ではなくクリップ編集の結果）。
        //
        // composition は `load(videoURL:)` 内の Task で2回の await（duration ロード＋
        // loadTracks）を経てから入る。移行前は同期代入の `videoAsset` を見ていたため
        // この窓が存在せず、押せば必ず書き出しが始まった。窓の中で無言 return すると
        // 進捗もアラートも出ず「押しても何も起きない」になるので、必ず理由を出す。
        // （`togglePlayback` の無言 no-op は「状態を進めない」ことが目的なので黙って
        //   良いが、書き出しはユーザーが結果を待つ操作なので黙ってはいけない。）
        guard let composition else {
            errorMessage = "動画の読み込み中です。少し待ってからもう一度お試しください"
            return
        }
        guard let renderer else { return }
        exportProgress = 0
        let exporter = VideoMosaicExporter(renderer: renderer, landmarker: landmarker)
        let selected = detectedFaces.filter(\.isSelected)
        // 全顔選択（単一顔の自動選択を含む）なら選択フィルタを完全バイパスする
        // （exporter は空配列を「全顔に適用」と解釈する）。追跡マッチングの誤棄却で
        // 書き出しからモザイクが消える余地を残さないフェイルクローズ。
        let targetsForExport = selected.count == detectedFaces.count ? [] : selected
        do {
            let url = try await exporter.export(
                asset: composition,
                selectedFaceTargets: targetsForExport,
                manualRegions: manualRegions,
                detectionCache: sourceScopedCache(),
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

    /// ライブ検出・初期スキャンで使う検出入力の目標幅（px）。
    /// `MosaicPreviewController.detectionCGImage(from:)` と検証テスト
    /// （DValidLivePathTests / SampleFalsePositiveTests）もこの値を参照し、
    /// 実機・シミュレータ・テストが常に同一解像度で検出するよう一元化する。
    /// 480 → 640: 逆光・低コントラストの小顔が 480px ではモデル入力への内部縮小で
    /// 潰れて検出下限を割るため（DValidLivePathTests の backlight セット実測で
    /// liveRate 0〜14% の動画があった）、推論回数を増やさずに底上げする。
    static let liveDetectionTargetWidth = 640.0

    /// 実機ライブ検出と同じ `liveDetectionTargetWidth` px 幅の縮小 CGImage を返す。
    /// `MosaicPreviewController.detectionCGImage(from:)` と同じスケール規則。
    private static let detectionCIContext = CIContext()
    static func downscaleForDetection(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let target = liveDetectionTargetWidth
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
