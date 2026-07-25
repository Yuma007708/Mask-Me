import AVFoundation
import Combine
import CoreImage
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

// フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
// swiftlint:disable file_length type_body_length

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
    /// 最後に `load(videoURL:)` した素材の識別子。クリップの有無とは独立に存在する。
    ///
    /// 素材の「同一性」は、その素材をどの範囲使うか（= クリップ）とは別の概念である。
    /// 動画ロード前でもキャッシュ操作が成立するよう、init 時点で初期値を持ち、
    /// `load(videoURL:)` のたびに新規発行して差し替える（同一モデルで別動画を
    /// ロードし直しても前の素材のキャッシュと混ざらない）。
    ///
    /// **S3 で「固定 sourceID」の役割は終了**: 検出キャッシュ等の各経路は合成時刻を
    /// `resolveSourceTime(atComposition:)` で写像した素材IDを使う。このプロパティは
    /// 「クリップ未構築時（ロード直後・写真モード・テスト直注入）のフォールバック先」
    /// と「新規ロード素材の登録名」としてだけ残っている。
    private(set) var currentSourceID = UUID()
    /// 素材基準の検出キャッシュ。クラス全体が @MainActor なので同期機構は不要。
    let cacheStore = DetectionCacheStore(bucketFPS: 15.0)
    /// タイムライン編集の単一情報源（クリップ列＋トランジション＋モザイク適用範囲）。
    ///
    /// 編集はすべて `MosaicEditorModel+Timeline.swift` の公開 API（`TimelineState` の
    /// 編集ラッパを呼ぶ薄い層）を経由する。UI からの接続は S9。
    /// 変更のたびに `mapping` を追随させ、`timelineGeneration` を進める。
    ///
    /// **アクセスレベル**: `applyTimelineEdit`（`MosaicEditorModel+Timeline.swift`）が
    /// 書き込むため setter も `internal`（無印）。書き込みは load / 編集 API /
    /// テストバックドア（`setClipsForTesting`）以外から行わないこと。
    @Published var timeline = TimelineState() {
        didSet {
            mapping = timeline.mapping
            // 進行中の非同期処理（rebuild・ライブ検出の in-flight submit）を
            // 旧世代として破棄できるよう、タイムラインが変わった瞬間に世代を進める。
            timelineGeneration += 1
            // 公開する動画尺は常に合成尺（mapping.totalDuration）基準にする。
            // マルチクリップ・rate≠1 では素材尺と一致しないため、素材尺のままだと
            // `position * videoDuration` の各所（seekTo / redetect / detectInRegion）
            // がずれる（S3 の TODO を解消。変換は compositionTime(forPosition:) に集約）。
            if !timeline.clips.isEmpty { videoDuration = mapping.totalDuration }
        }
    }
    /// タイムライン上のクリップ列（`timeline` への読み取りショートカット）。
    var clips: [TimelineClip] { timeline.clips }
    /// タイムラインの世代トークン。`timeline` が変わるたびに 1 進む。
    ///
    /// 非同期処理は開始時点の値を閉じ込め、完了時に一致しなければ結果を破棄する:
    /// - `rebuildComposition(generation:)`: 旧世代の合成結果でプレビューを上書きしない
    /// - ライブ検出の in-flight submit: 旧タイムラインの合成時刻を新しい写像で
    ///   素材キーへ落とすと誤った素材時刻に記録される（S3 レビューの観測事項）
    private(set) var timelineGeneration = 0
    /// 進行中のタイムライン再構築タスク（世代付き）。
    ///
    /// 編集直後〜非同期 rebuild 完了までは `mapping`（同期更新）と `composition`
    /// （非同期差し替え）が不整合な窓になる。`exportVideo` はこのタスクを await して
    /// から書き出すことで、旧 composition を新 mapping で写像する事故を防ぐ
    /// （`awaitPendingTimelineRebuild()` 参照）。書き込みは `applyTimelineEdit` と
    /// rebuild 完了時の後始末のみ（いずれも `MosaicEditorModel+Timeline.swift`）。
    var pendingRebuild: (generation: Int, task: Task<Void, Never>)?
    /// 現在の `composition` を構築した時点の世代トークン。
    ///
    /// `timelineGeneration` と一致していれば composition と mapping は同じ
    /// タイムラインに由来する（エクスポート前の整合性照合に使う）。
    /// 書き込みは load / `rebuildComposition` の composition 差し替え箇所のみ。
    var compositionGeneration = 0
    /// `timeline` から再構築される合成時刻⇔素材時刻の変換層（didSet で追随）。
    ///
    /// S3 で配線済み: 検出キャッシュの読み書き・フレーム抽出・矩形サーチ・顔選択照合は
    /// すべて `resolveSourceTime(atComposition:)`（`MosaicEditorModel+DetectionCache.swift`）
    /// を経由してこの写像を参照する。フェーズ1相当の「素材全体1クリップ」では恒等写像に
    /// なるため、配線前と観測可能な挙動は変わらない。
    private(set) var mapping = TimelineMapping(clips: [])
    /// テスト専用: クリップ列を直接差し替える（`didSet` 経由で `mapping` の再構築・
    /// 世代インクリメント・`videoDuration` 追随も走る）。
    /// 複数クリップ状態を再現するためのバックドア（正規の書き込み経路は
    /// load / 編集 API のみ、という規約をテスト側にも明示する意図で残している）。
    func setClipsForTesting(_ clips: [TimelineClip]) {
        timeline = TimelineState(clips: clips)
    }
    /// 素材IDから AVAsset への対応表。
    ///
    /// **アクセスレベル変更**: 元は `private` だったが、`rebuildComposition`
    /// （`MosaicEditorModel+Timeline.swift`）から参照されるため `internal`（無印）にした。
    var sources: [UUID: AVAsset] = [:]
    /// クリップ列から構築した合成結果。プレビューと書き出しで同じものを使い回す。
    ///
    /// **不変条件（フェーズ1限定）: `composition` は `videoAsset` と時間軸が一致する。**
    /// フェーズ1のクリップ列は「素材全体を使う1本」しか無いため、
    /// composition 上の時刻 t と videoAsset 上の時刻 t は同じフレームを指す。
    /// この前提のもとで、資産を2つ並存させて用途で使い分けている:
    ///
    /// - `videoAsset`: サムネ生成とスクラブ時のフレーム抽出の**素材側フォールバック**
    ///   （`AVAssetImageGenerator` 系の同期取り出し。Composition 経由より素材直読みの
    ///   ほうが速く確実。クリップ未構築の間だけ恒等時刻で直接使われる）
    /// - `composition`: 再生（`AVPlayerItem`）と書き出し（`AVAssetReader`）
    ///
    /// **S3 で写像を配線済み:** かつてここに列挙していた「composition 時刻で
    /// `videoAsset` / 検出キャッシュを直接引くと誤フレームになる箇所」
    /// （`seekTo` / `redetect` のフレーム抽出、検出キャッシュのキー、
    /// `resolveRegion` / `findFaceInVideo` の全体走査）は、すべて
    /// `resolveSourceTime(atComposition:)` / `frameAtCompositionTime(_:)` /
    /// クリップ使用区間走査（`scanSegments()`）経由に置き換えた。
    ///
    /// **アクセスレベル変更（S4）**: 元は `private` だったが、タイムライン編集後の
    /// `rebuildComposition`（`MosaicEditorModel+Timeline.swift`）が差し替えるため
    /// `internal`（無印）にした。
    var composition: AVMutableComposition?
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
        // 素材ごとに新規 sourceID を発行する。init 固定のままだと、同一モデルで
        // 別動画をロードし直したとき前の素材の検出キャッシュと同じキー空間に混ざる。
        currentSourceID = UUID()
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
                           isSelected: autoSelect,
                           sourceID: currentSourceID)
            }
        }
        manualRegions = []

        Task {
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = seconds

            // 読み込み直後は素材全体を使う単一クリップ（編集はここから始まる）。
            sources = [currentSourceID: asset]
            timeline = TimelineState(clips: [TimelineClip(sourceID: currentSourceID,
                                                          sourceStart: 0, sourceEnd: seconds)])

            // Composition の構築は renderer の有無と無関係に行う。
            // renderer が nil でも書き出し（composition 依存）は成立させたいので、
            // 「renderer が無い ＝ composition も無い」という巻き添えを作らない。
            do {
                // rebuildComposition(generation:) と同じく、build の await を跨ぐ前に
                // 世代をローカルへ閉じ込める。await 後に「現在の」世代を刻むと、
                // build 中に編集が割り込んだとき旧クリップ列の合成結果へ新世代が
                // 刻まれ、exportVideo の世代照合が素通しになる（レビューの実測）。
                let loadGeneration = timelineGeneration
                let built = try await TimelineCompositionBuilder()
                    .build(clips: clips, sources: sources)
                let isStale = loadGeneration != timelineGeneration
                if !isStale {
                    composition = built
                    compositionGeneration = loadGeneration
                }
                if let r = renderer {
                    // stale の場合、割り込んだ編集側の rebuild が composition を
                    // 先に差し替えていればそちらを使う（無ければ built を暫定表示し、
                    // 直後の再構築で現行世代の合成結果に置き換わる）。
                    previewController = MosaicPreviewController(
                        renderer: r, asset: composition ?? built, model: self)
                }
                if isStale {
                    // 旧クリップ列の合成結果は適用せず、現行世代で作り直す。
                    // 割り込んだ編集側の rebuild が先に完了していた場合も、その時点では
                    // previewController が無く asset 差し替えをスキップしているため、
                    // ここで必ず現行世代へ揃える。
                    await rebuildComposition(keepingCompositionSeconds: nil)
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
            // 動画では「いま表示中のフレームが属する素材」を顔の帰属先にする
            // （恒等写像下では常に currentSourceID）。写真は素材の概念が無いので nil。
            let faceSourceID: UUID? = mode == .video
                ? resolveSourceTime(atComposition: compositionTime(forPosition: playbackPosition)).sourceID
                : nil
            let newFaces = found.map { lm -> FaceTarget in
                let remapped = lm.remapped(into: normalizedRect)
                let thumb = generateThumbnail(for: remapped, from: img)
                // ユーザーが矩形を描いた意図は「この顔にモザイクを掛けたい」なので
                // 即選択する（false だとサムネをもう一度タップするまで何も起きない）。
                return FaceTarget(id: UUID(), landmarks: remapped, thumbnail: thumb,
                                  isSelected: true, sourceID: faceSourceID)
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

    /// 矩形サーチ（`resolveRegion`）の走査対象1件。素材と、その中で走査する区間。
    private struct RegionScanSegment {
        let asset: AVAsset
        /// nil は素材全体（`findFaceInVideo` が duration をロードして決める）。
        let range: ClosedRange<Double>?
        let sourceID: UUID
    }

    /// 矩形サーチの検出結果。どの素材で見つかったかを顔の帰属（`FaceTarget.sourceID`）
    /// に引き継ぐため、ランドマークとフレームに素材IDを添える。
    private struct RegionScanHit {
        let landmarks: FaceLandmarkSet
        let frame: UIImage
        let sourceID: UUID
    }

    /// 矩形内クロップが現在フレームで失敗したとき: クリップが使う素材区間を1fpsで
    /// サーチして顔を探す（タイムラインに存在しない区間で顔を拾い、composition 上に
    /// 対応時刻の無い結果を返さないため。恒等＝素材全体1クリップでは従来の全体走査と
    /// 同一の時刻列になる）。見つかれば FaceTarget として追加（追跡可能）。
    /// 全フレームで失敗なら固定矩形マスク。
    private func resolveRegion(_ rect: CGRect, referenceImage: UIImage?) async {
        guard mode == .video, videoAsset != nil else {
            appendManualRect(rect)
            return
        }
        isScanning = true
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let segments = scanSegments()
        let result: RegionScanHit? = await Task.detached(
            priority: .userInitiated
        ) { [scanner, segments, rect] in
            // タイムライン順に各クリップの使用区間を走査し、最初の検出を採用する。
            for segment in segments {
                guard !Task.isCancelled else { return nil }
                if let (landmarks, frame) = await Self.findFaceInVideo(
                    asset: segment.asset, rect: rect, scanner: scanner, scanRange: segment.range) {
                    return RegionScanHit(landmarks: landmarks, frame: frame, sourceID: segment.sourceID)
                }
            }
            return nil
        }.value
        isScanning = false

        if let hit = result {
            let thumbSource = referenceImage ?? hit.frame
            let thumb = generateThumbnail(for: hit.landmarks, from: thumbSource)
            // 矩形を描いた意図に合わせて即選択（上の resolveRegion 直検出と同じ理由）。
            detectedFaces.append(FaceTarget(id: UUID(), landmarks: hit.landmarks, thumbnail: thumb,
                                            isSelected: true, sourceID: hit.sourceID))
        } else {
            // どのフレームでも検出できなかった: 固定矩形マスクにフォールバック
            appendManualRect(rect)
        }
    }

    /// 矩形サーチ（`resolveRegion`）が走査すべき素材と使用区間の列。
    /// クリップ列があればその使用区間のみ。クリップ未構築（Composition 構築前）の間は
    /// 従来どおり素材全体。
    private func scanSegments() -> [RegionScanSegment] {
        guard !clips.isEmpty else {
            guard let asset = videoAsset else { return [] }
            return [RegionScanSegment(asset: asset, range: nil, sourceID: currentSourceID)]
        }
        return clips.compactMap { clip in
            guard let asset = sources[clip.sourceID], clip.sourceEnd > clip.sourceStart else { return nil }
            return RegionScanSegment(asset: asset,
                                     range: clip.sourceStart...clip.sourceEnd,
                                     sourceID: clip.sourceID)
        }
    }

    /// 素材の指定区間（nil なら全体）を1fpsでサンプリングし、矩形クロップ内で顔を探す。
    /// 最初の検出結果を返す。
    nonisolated private static func findFaceInVideo(
        asset: AVAsset,
        rect: CGRect,
        scanner: FaceLandmarking,
        scanRange: ClosedRange<Double>? = nil
    ) async -> (FaceLandmarkSet, UIImage)? {
        let start: Double
        let end: Double
        if let scanRange {
            start = scanRange.lowerBound
            end = scanRange.upperBound
        } else {
            guard let dur = try? await asset.load(.duration).seconds else { return nil }
            start = 0
            end = dur
        }
        guard end > start else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
        var t = start
        while t <= end {
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
            // シーク後のフレームで sourceTexture を更新してプレビューに反映。
            // 合成時刻を素材＋素材時刻へ写像して抽出する（videoAsset 直参照だと
            // トリム・並べ替え後に誤フレームを返す。恒等では従来と同一フレーム）。
            // 位置→合成時刻の変換は compositionTime(forPosition:) に集約済み
            // （videoDuration はクリップ構築後 mapping.totalDuration に追随する）。
            if videoDuration > 0,
               let frame = frameAtCompositionTime(compositionTime(forPosition: position)) {
                sourceTexture = makeTexture(from: frame)
                updateBackgroundMask(from: frame)
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
        guard videoAsset != nil, videoDuration > 0 else { return }
        let t = compositionTime(forPosition: position)
        // 合成時刻 t を素材＋素材時刻へ写像してフレームを取り出す（恒等では従来と同一）。
        guard let frame = frameAtCompositionTime(t) else { return }

        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let found = scanner.allLandmarks(in: frame)
        // storePreScanResult が合成時刻→素材キーの写像と 15fps バケット正規化を行う
        // （doc コメント参照。生 t のままだとライブの空エントリを上書きできない）。
        storePreScanResult(found, at: t)

        if !found.isEmpty {
            // 旧: 全員 isSelected: false で置き換えていた。モザイクが外れた時に
            // ユーザーが押すボタンで選択が全消去され「以降一切モザイクがかからない」
            // 実機報告の直接原因だった。選択状態は重心マッチで引き継ぎ、誰も選択
            // されない結果になる場合は全選択にフォールバックする（このボタンを押す
            // 意図は常に「顔にモザイクを掛けたい」なので、消える方向に倒さない）。
            let faceSourceID = resolveSourceTime(atComposition: t).sourceID
            detectedFaces = carryingOverSelection(
                found.map { lm in
                    FaceTarget(id: UUID(), landmarks: lm,
                               thumbnail: generateThumbnail(for: lm, from: frame),
                               isSelected: false,
                               sourceID: faceSourceID)
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
    // sourceScopedCache(for:)）と、合成時刻→素材時刻の写像ヘルパ
    // （resolveSourceTime(atComposition:)）は
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
    /// **素材基準キー化（S3 で写像まで配線済み）**: このキャッシュは `cacheStore`
    /// と同じ `DetectionCacheKey`（sourceID + bucket）でキーする。書き込み
    /// （`storeLiveDetection`）と参照（`nearestFlowFaces`）の入口で合成時刻を
    /// `resolveSourceTime(atComposition:)` により素材ID・素材時刻へ写像し、その
    /// **写像済み**の時刻でキーを構築する（丸めは `DetectionCacheKey.init`。
    /// 必ず写像の後）。detectionCache（`cacheStore`）と混ぜない規約は従来どおり。
    ///
    /// **アクセスレベル変更**: 元は `private(set)` だったが、読み書きする
    /// `nearestFlowFaces` / `resetLiveDetection` / `storeLiveDetection` が
    /// `MosaicEditorModel+LiveDetection.swift` に切り出されたため `internal`
    /// （読み書き無印）にした。
    var liveFlowCache: [DetectionCacheKey: [FaceLandmarkSet]] = [:]

    /// 選択中の顔に対応する、指定した合成時刻のランドマークセットを返す。
    func selectedLandmarks(at time: Double) -> [FaceLandmarkSet] {
        guard faceMosaicOn else { return [] }
        let cached = lookupFaces(at: time)
        let selected = detectedFaces.filter(\.isSelected)
        if selected.isEmpty { return [] }
        if selected.count == detectedFaces.count { return cached }

        // 照合対象をこの合成時刻が属する素材の顔に限定する（別素材の「似た位置の顔」
        // との誤マッチ防止）。sourceID が nil の顔（写真モード・素材ID導入前の経路・
        // テスト直注入）は従来どおり素材不問で照合する。恒等（単一素材）では
        // 全員が同一 sourceID なのでスコープは何も落とさない（挙動不変）。
        let sourceID = resolveSourceTime(atComposition: time).sourceID
        let scoped = selected.filter { $0.sourceID == nil || $0.sourceID == sourceID }

        // 重心の近さで選択顔とキャッシュ顔を照合する（閾値0.5: 広め）
        return cached.filter { face in
            let fc = normalizedCentroid(of: face)
            return scoped.contains { target in
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
        // 編集直後〜非同期 rebuild 完了までは mapping（同期更新）と composition
        // （非同期差し替え）が不整合な窓になる。この窓で書き出すと旧 composition を
        // 新 mapping で写像してしまうため、進行中の rebuild を待ってから始める。
        await awaitPendingTimelineRebuild()
        guard let composition else {
            errorMessage = "動画の読み込み中です。少し待ってからもう一度お試しください"
            return
        }
        // rebuild の失敗・スキップで composition が旧世代のまま残ることがある
        // （エラー時など）。不整合な組で黙って書き出さず、安全側に倒して知らせる。
        guard compositionGeneration == timelineGeneration else {
            errorMessage = "タイムラインの更新が完了していません。もう一度お試しください"
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
        // exporter は素材IDごとのキャッシュ辞書＋合成時刻→素材位置の写像を受け取る（S4）。
        // タイムラインが参照する全素材ぶんを射影して渡す。フレーム PTS（合成時刻）を
        // 素材キーへ写像するのは exporter 側（丸め・近傍補間は写像の後）。
        // クリップ未構築の窓は composition guard で弾かれるため clips は実質常に非空だが、
        // 万一空でも「キャッシュなし・全フレーム自前検出」で完走する（品質は落ちない）。
        var detectionCaches: [UUID: [Double: [FaceLandmarkSet]]] = [:]
        for sourceID in Set(clips.map(\.sourceID)) {
            detectionCaches[sourceID] = sourceScopedCache(for: sourceID)
        }
        do {
            let url = try await exporter.export(
                asset: composition,
                selectedFaceTargets: targetsForExport,
                manualRegions: manualRegions,
                detectionCaches: detectionCaches,
                mapping: mapping,
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

    /// 合成時刻に対応するフレームを「写像した素材 asset ＋ 素材内時刻」から取り出す。
    /// Composition 経由の抽出より素材直読みのほうが速く確実、という従来方針を
    /// 写像込みで維持する（`composition` プロパティの doc コメント参照）。
    /// クリップ未構築（Composition 構築前の窓・`sources` 未登録）の間は従来どおり
    /// `videoAsset` の恒等参照にフォールバックする。
    func frameAtCompositionTime(_ compositionTime: Double) -> UIImage? {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: compositionTime)
        guard let asset = sources[sourceID] ?? videoAsset else { return nil }
        return Self.frame(of: asset, at: sourceTime)
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
// swiftlint:enable type_body_length

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
// swiftlint:enable file_length
