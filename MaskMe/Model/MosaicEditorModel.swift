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
    ///
    /// S5 で `timeline` / `trimRange` を追加した。タイムライン編集
    /// （split/remove/move/trim/setRate）もパラメータ編集と同じ履歴に積まれ、
    /// undo/redo でクリップ ID・順序・rate まで完全復元される。
    struct EditSnapshot: Equatable {
        var faceMosaicOn: Bool
        var backgroundMosaicOn: Bool
        var faceBlockSize: Float
        var backgroundBlockSize: Float
        var selectedFaceIDs: Set<UUID>
        var manualRects: [CGRect]
        /// 書き出し範囲。S9 以降ユーザー操作からの書き込み経路は無い
        /// （`MosaicEditorModel.trimRange` の doc 参照）。常に `0...1`。
        var trimRange: ClosedRange<Double>
        var timeline: TimelineState
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
    @Published public internal(set) var detectedFaces: [FaceTarget] = [] {
        didSet { applyPendingFaceSelectionAnchorsIfNeeded() }
    }
    @Published public var manualRegions: [ManualRegion] = []
    @Published public internal(set) var isScanning = false

    // 動画再生
    @Published public var playbackPosition: Double = 0
    /// タイムラインを指で操作している最中か（`VideoTimelineView` の
    /// `onScrubbingChanged` が立てる）。
    ///
    /// **この間は再生位置の所有者がタイムライン側**であり、描画経路は
    /// `playbackPosition` を書き戻してはならない
    /// （理由は `MosaicPreviewController.renderCurrentFrame` の doc）。
    /// `@Published` にしないのは、毎スクロールで画面全体を再評価させないため
    /// （読むのは描画経路だけ）。
    public var isTimelineScrubbing = false
    @Published public private(set) var videoDuration: Double = 0
    @Published public var isPlaying = false

    /// 現在のタイムラインの出力解像度（先頭クリップ基準。クリップ未構築なら nil）。
    ///
    /// **UI はここを読むこと。`videoComposition?.renderSize` を直接読んではならない**
    /// （`videoComposition` は `@Published` ではないので更新が届かず、そもそも
    /// 無装着構成では nil になる）。値の算出は `VideoCompositionFactory.renderSize(for:)`
    /// の単一実装で、`TimelineCompositionBuilder.Built.outputSize` を経由して届く。
    /// 書き込みは `apply(built:generation:)` 一箇所だけ（別ファイルの extension なので
    /// `private(set)` は使えない。`detectedFaces` と同じく `internal(set)`）。
    @Published public internal(set) var outputRenderSize: CGSize?
    /// 出力枠より大きく、縮小されて収まるクリップがあるか（UI の注意表示用）。
    /// 並べ替えで先頭クリップ＝出力解像度が変わると true / false が入れ替わる。
    @Published public internal(set) var hasDownscaledClips = false

    /// 動画の書き出し対象範囲（0...1 正規化）。
    /// エクスポート時は `AVAssetReaderTrackOutput` からのフレームのうち、
    /// この範囲外の `presentationTime` をスキップして出力尺を短縮する。
    ///
    /// **S9 現在、ユーザー操作からの書き込み経路は存在しない**（意図的に残している）。
    /// 全体 In/Out トリムの UI はクリップ単位のトリム（`TimelineClip.sourceStart/End`）へ
    /// 置き換わり、下書きにも保存されない（`DraftStore` にフィールドが無く、復元時は
    /// 常に `0...1` が代入される）。値は常に `0...1` なので `VideoMosaicExporter` の
    /// PTS シフト経路（`trimRange` 引数）も恒等で通る。
    ///
    /// 削除せず残す理由: 書き出し範囲の指定は将来の再導入候補であり、
    /// エクスポータ側の PTS シフトと写像の二重適用回避は
    /// `MultiClipExportTests` が固定している資産（消すとテストごと失われる）。
    /// **新しい UI をここへ繋ぐまでは到達不能コードであることを前提に読むこと。**
    @Published public var trimRange: ClosedRange<Double> = 0...1

    // コントロール（効果ごと）
    @Published public var faceMosaicOn = true
    @Published public var backgroundMosaicOn = false
    @Published public var faceBlockSize: Float = 28
    @Published public var backgroundBlockSize: Float = 28
    /// 選択中タブ（nil＝未選択：調整バーは非表示）。
    @Published public var activeTab: EffectTab? {
        didSet {
            // 顔タブを離れたら矩形ツールは必ず下ろす（モードが残っていると、
            // 別の作業をしている最中のプレビューのドラッグが矩形作成に化ける）。
            if activeTab != .face { isRectangleToolActive = false }
        }
    }

    /// 手動矩形ツール（プレビューをドラッグして範囲を指定するモード）が ON か。
    ///
    /// **既定は OFF。** 常時有効だった頃は、プレビューを少しなぞっただけで矩形が
    /// できてしまい「間違えて指定して使いづらい」状態だった
    /// （`RectangleDrawingOverlay` はこれが true のときだけドラッグ面を張る）。
    /// 顔タブ専用の道具なので、タブを離れると `activeTab` の didSet が下ろす。
    @Published public var isRectangleToolActive = false

    // Undo / Redo（スタックの空判定から導出。スタックは @Published なので
    // 変化時に objectWillChange が発火し、UI は最新の値を読み直す）
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 確定編集のカウンタ（自動保存のトリガ）。
    ///
    /// `commitEdit()` が実際に履歴を進めたとき、および undo/redo のたびに 1 進む。
    /// `commitEdit` は確定操作（顔選択トグル・手動矩形の追加削除・効果 ON/OFF・
    /// 調整バーの ✓・タイムライン編集）でしか呼ばれず、**スライダーのドラッグ中には
    /// 呼ばれない**ため、変化回数は「タップ数」オーダーに収まる。
    /// それでも undo 連打で無駄な IO が出るので、購読側（`EditorView`）でデバウンスする。
    @Published public private(set) var editVersion = 0

    // エクスポート・保存
    @Published public var exportProgress: Double?
    /// エクスポートの速度／品質段。既定は標準。UI から変更可能。
    @Published public var exportSpeed: ExportSpeed = .balanced
    @Published public var didSave = false
    @Published public var errorMessage: String?
    /// キャンセル要求を出してから書き出しが実際に畳まれるまでの状態。
    ///
    /// `requestMediaDataWhenReady` のブロックは writer 入力が ready になるまで
    /// 再呼び出しされないため、中断が効くまでに遅延がある（writer が完全に
    /// ストールした場合は効かないこともある）。UI はこの間「中止しています…」を
    /// 出して進捗オーバーレイを保つ。
    @Published public private(set) var isExportCancelling = false
    /// エンコード完了後の「写真ライブラリへ保存中」フェーズ。
    ///
    /// このフェーズは**キャンセルできない**。`PHPhotoLibrary` の変更リクエストは
    /// アセットを作り切るか失敗するかの二択で、途中で畳むと中途半端なアセットや
    /// 孤児ファイルが残り得るためである（一般的な動画編集アプリも「書き出し」は
    /// 中断可・「ライブラリへの保存」は中断不可で、保存中はキャンセル導線を出さない）。
    /// UI はこのフラグでキャンセルボタンを引っ込め、文言を保存中へ切り替える。
    ///
    /// これが無いと「エンコード完了 → iCloud 写真ライブラリへ保存中（数十秒あり得る）」の
    /// 窓でキャンセルを押せてしまい、`activeExporter?.cancel()` は完了済み exporter への
    /// 無効なフラグ立てで終わり、保存だけ完走して「中止しています…」が貼り付いたまま
    /// 「保存完了」になる。
    @Published public private(set) var isExportSaving = false
    /// 進行中の exporter（キャンセル要求の宛先）。
    private var activeExporter: VideoMosaicExporter?
    /// 書き出しセッションのトークン。進捗コールバックは別スレッドから
    /// `Task { @MainActor }` で飛んでくるため、**完了後に遅延到着した通知が
    /// `exportProgress` を書き戻して進捗オーバーレイを復活させ得る**。
    /// 開始時に 1 進め、コールバック側で照合して古いセッションを弾く。
    private var exportSession = 0

    /// 進行中の書き出しを中断する（実際に畳まれるのは exporter が中断点に達した時点）。
    ///
    /// **写真ライブラリへの保存フェーズに入った後は何もしない**（`isExportSaving` の doc 参照）。
    /// UI もそのフェーズではキャンセルボタンを出さないが、押下と遷移が競合しても
    /// 「中止しています…」で固まらないようモデル側でも弾く。
    public func cancelExport() {
        guard exportProgress != nil, !isExportCancelling, !isExportSaving else { return }
        isExportCancelling = true
        activeExporter?.cancel()
    }

    /// 保存・書き出しの失敗をユーザー向け文言へ落とす。
    ///
    /// `PhotosSaver.SaveError` は Swift enum で `NSError` の domain/code に
    /// 載らないため、`ExportFailureReason.classify` に渡す**前**に型で拾う。
    private func failureMessage(for error: Error) -> String {
        if let saveError = error as? PhotosSaver.SaveError {
            switch saveError {
            case .notAuthorized:
                return "写真ライブラリへの保存が許可されていません。"
                    + "設定 > プライバシーとセキュリティ > 写真 から、このアプリに追加を許可してください。"
            case .failed:
                return "写真ライブラリへの保存に失敗しました。時間をおいてから、もう一度お試しください。"
            }
        }
        let ns = error as NSError
        return ExportFailureReason.classify(domain: ns.domain, code: ns.code).message
    }

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
    /// 検出顔に対応する人物署名の置き場。`cacheStore` と**同じバケット**で丸めること
    /// （食い違うと顔は引けるのに署名だけ引けない）。取り違え対策は
    /// `FaceSignatureCache` の doc コメント参照。
    let signatureCache = FaceSignatureCache(bucketFPS: 15.0)
    /// 署名を人物へまとめる台帳。顔一覧を「検出顔の数」ではなく「人の数」で見せる土台。
    var personRegistry = PersonRegistry()
    /// 素材ごとに「最後に署名を計算した素材時刻」。署名 1 本あたり実測 4.8ms かかるので、
    /// 全フレーム × 全顔で回さずこの間隔まで間引く（`signatureIntervalSec`）。
    /// 人物の同定は数フレームに 1 回取れれば足り、判断は署名が無い間も
    /// 位置追跡→安全側（隠す）で成立する。
    /// （`MosaicEditorModel+LiveDetection.swift` から触るため internal。格納プロパティは
    /// extension に置けない Swift の制約でここに残っている。）
    var lastSignatureSourceTime: [UUID: Double] = [:]
    /// 署名を計算する最小間隔（素材時刻・秒）。
    let signatureIntervalSec = 0.5
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
            // 孤児区間（どのクリップの使用範囲とも交差しない適用区間）を除いた
            // 「実際に効いている区間」をここで 1 回だけ作る。O(クリップ数 × 区間数) を
            // 30fps の描画やエクスポートの全フレームで回さないためのキャッシュであり、
            // タイムラインが変わらない限り結果も変わらない（純関数）。
            effectiveApplyRanges = MosaicApplyGate.effectiveRanges(timeline.applyRanges, mapping: mapping)
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
    /// **描画ゲートが見る唯一の適用区間**（`timeline` の didSet で追随。S10 レビュー修正）。
    ///
    /// `timeline.applyRanges` から「どのクリップの使用範囲とも交差しない区間（孤児区間）」を
    /// 除いたもの。区間データそのものは温存する（トリムを戻せば復活する）という
    /// S9 の決定は変えず、**ゲート側で除外**する。
    ///
    /// これにより「見えている帯の本数 ⇔ 有効区間の個数」「帯 0 本 ⇔ ゲート全区間 OFF」
    /// （不変条件 I1）が成立する。絞り込みの実体は
    /// `MosaicApplyGate.effectiveRanges(_:mapping:)` の 1 本だけで、
    /// 顔ゲート・合成時刻ゲート・エクスポートの全経路がこの結果を通る。
    ///
    /// **毎フレーム計算しないこと**（O(クリップ数 × 区間数)）。だから didSet でキャッシュしている。
    private(set) var effectiveApplyRanges: [MosaicApplyRange] = []
    /// テスト専用: クリップ列を直接差し替える（`didSet` 経由で `mapping` の再構築・
    /// 世代インクリメント・`videoDuration` 追随も走る）。
    /// 複数クリップ状態を再現するためのバックドア（正規の書き込み経路は
    /// load / 編集 API のみ、という規約をテスト側にも明示する意図で残している）。
    func setClipsForTesting(_ clips: [TimelineClip]) {
        timeline = TimelineState(clips: clips)
    }
    /// テスト専用: タイムライン全体（sources の素材種別を含む）を直接差し替える。
    /// 写真クリップ（`TimelineSource.kind == .photo`）入りの状態を再現するために使う。
    func setTimelineForTesting(_ state: TimelineState) {
        timeline = state
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
    /// `composition` に装着する映像合成（S8）。トランジション・rate≠1・
    /// フォーマット混在のときだけ非 nil（判定は `VideoCompositionPlan.decide`）。
    /// プレビュー（`AVPlayerItem.videoComposition`）と書き出し
    /// （`AVAssetReaderVideoCompositionOutput`）の両経路に同じものを渡す。
    var videoComposition: AVMutableVideoComposition?
    /// `composition` に装着する音声ミックス（S8）。トランジションの音声クロスフェード・
    /// `TimelineClip.originalAudioVolume` があるときだけ非 nil。
    var audioMix: AVMutableAudioMix?
    /// 素材フレーム基準の顔座標を合成フレーム基準へ写すレイアウト（S8）。
    /// 解像度混在（レターボックス）で効く。無変換構成では恒等。
    var renderLayout: TimelineRenderLayout = .identity
    private(set) var previewController: MosaicPreviewController?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - プレビューのデコード資源占有

    /// **プレビュー側が HW デコーダを握っているか。**
    ///
    /// サムネイル生成（`TimelineThumbnailStore`）の抑止条件は `isPlaying` では足りない。
    /// 分割・トリム・削除・並べ替え・速度・トランジション・適用区間の**すべての編集**が
    /// `replaceCurrentItem` + `toleranceBefore/After: .zero` の seek + `renderCurrentFrame`
    /// を起こし、スクラブも `onChanged` ごとに zero-tolerance seek を撃つ。どちらも
    /// `isPlaying == false` なので、`isPlaying` ガードは実際の競合を 1 つも覆っていない
    /// （実測: `copyCGImage` の平均コストは idle 6.57ms → 再生中 10.41ms（+58%）→
    /// スクラブ中 10.16ms（+55%）。事故の機序はデコーダの取り合いであって再生ではない）。
    ///
    /// **`@Published` にしないこと。** `renderCurrentFrame` は再生中 30fps で
    /// 立ち下げ・立ち上げを繰り返すため、`@Published` にするとエディタ画面全体が
    /// 毎フレーム再描画される。購読は `onPreviewDecodeBusyChanged` の 1 本だけ。
    private(set) var isPreviewDecodeBusy = false
    /// `beginPreviewDecode` / `endPreviewDecode` の入れ子深さ。
    /// **必ず対で呼ぶこと**（早期 return・throw でも下がるよう `defer` で下げる）。
    private var previewDecodeDepth = 0
    /// busy の立ち上がり・立ち下がりの通知（値が変わったときだけ呼ばれる）。
    var onPreviewDecodeBusyChanged: ((Bool) -> Void)?

    /// デコード資源の占有を宣言する（`defer { endPreviewDecode() }` と対で使う）。
    func beginPreviewDecode() {
        previewDecodeDepth += 1
        setPreviewDecodeBusy(true)
    }

    /// デコード資源の占有を解除する。深さが 0 に戻ったときだけ busy が下がる。
    func endPreviewDecode() {
        previewDecodeDepth = max(0, previewDecodeDepth - 1)
        guard previewDecodeDepth == 0 else { return }
        setPreviewDecodeBusy(false)
    }

    /// テスト用: 立ち下げ漏れ（`begin` と `end` の非対称）を検出するための深さ。
    var previewDecodeDepthForTesting: Int { previewDecodeDepth }

    private func setPreviewDecodeBusy(_ busy: Bool) {
        guard isPreviewDecodeBusy != busy else { return }
        isPreviewDecodeBusy = busy
        onPreviewDecodeBusyChanged?(busy)
    }

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

    /// **アクセスレベル変更（S6）**: 元は `private let` だったが、`appendPhotoClip`
    /// （`MosaicEditorModel+Timeline.swift`）が写真の検出 seed 用スキャナーを
    /// `makeFaceLandmarker(forVideo:settings:)` で作るため `internal`（無印）にした。
    let detectionSettings: DetectionSettings

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
        // 別メディアの復元待ち目印を持ち越さない（これから入る顔は別素材のもの）。
        clearPendingFaceSelectionAnchors()
        let normalized = image.normalizedUp()
        sourceImage = normalized
        let faces = landmarker.allLandmarks(in: normalized)
        // 写真モードは素材ID・検出キャッシュを使わないので、人物 ID を決めるだけ。
        let personIDs = seedPersonIDs(for: faces, in: normalized, sourceID: nil, time: 0)
        detectedFaces = faces.enumerated().map { idx, lm in
            // 顔が1つならタップ不要で即モザイクする（動画側と挙動を揃える）。
            let autoSelect = faces.count == 1 && idx == 0
            return FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalized),
                       isSelected: autoSelect, personID: personIDs[idx])
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
        // 別メディアの復元待ち目印を持ち越さない（下書き復元は load の**後**に
        // `applyRestoredParameters` で予約されるので、ここで消しても取りこぼさない）。
        clearPendingFaceSelectionAnchors()
        sourceVideoURL = url
        // 新しい動画では全長を選択に戻す。前の動画のトリムが残ると意図しない範囲書き出しになる。
        trimRange = 0...1
        // 素材ごとに新規 sourceID を発行する。init 固定のままだと、同一モデルで
        // 別動画をロードし直したとき前の素材の検出キャッシュと同じキー空間に混ざる。
        // 下書き復元（queueTimelineRestore 済み）では保存時の素材IDを引き継ぐ:
        // 新規発行すると初期スキャンのシード・顔サムネの帰属が復元タイムラインの
        // どの素材とも一致せず、選択照合（selectedLandmarks の sourceID スコープ）
        // から外れる。
        currentSourceID = pendingTimelineRestore?.primarySourceID ?? UUID()
        let asset = AVAsset(url: url)
        videoAsset = asset

        manualRegions = []
        // 新しい素材を読み込むので顔は一旦空にする。**初期スキャンが非同期になった**
        // （下の Task）ため、ここで空にしないと「前の素材の顔が残ったまま復元が走る」
        // 窓ができる。スキャン結果はこの空の列へ**追記**される（`loadSeedFaces` の doc）。
        detectedFaces = []

        // 読み込みの所要時間を段ごとに出す（`[MMEXPORT]` / `[MMLIVE]` と同じ流儀の
        // DEBUG 計測。「編集画面に遷移するのに時間がかかる」の再発を実機で測るため）。
        #if DEBUG
        let loadStart = Date()
        print("[MMLOAD] sync done (main thread released)")
        #endif

        Task {
            // **先頭フレーム取り出し・背景マスク（Vision）・顔シード探索は
            // ここから先で行う（同期部では行わない）。** どれも主スレッドで数百ms〜
            // 数秒かかり、`.task { loadMedia() }` から同期で走らせると画面遷移
            // そのものが止まる（ユーザー報告「動画選択後、編集画面に遷移するのに
            // 時間がかかる（最近のプロジェクトを開くときも）」）。順序は同期部に
            // あった頃と同じ——先頭フレーム → 顔シード → 尺 → タイムライン →
            // composition → 初期フレーム描画——に保つ:
            // `installInitialTimeline` 末尾の `resetHistory()` が履歴の基準を
            // 取り直すので、初期スキャンの自動選択を含んだ状態が起点になる。
            // 下書きの顔選択は `detectedFaces` が空のあいだ
            // `pendingFaceSelectionAnchors` に保留され、埋まった時点で didSet が適用する
            // （`restoreFaceSelection` の doc）。
            await Task.yield()
            await loadSeedFaces(from: asset)
            #if DEBUG
            print(String(format: "[MMLOAD] seed scan done %.2fs faces=%d",
                         Date().timeIntervalSince(loadStart), detectedFaces.count))
            #endif
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = seconds

            installInitialTimeline(primaryAsset: asset, seconds: seconds)

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
                    .build(clips: clips, transitions: timeline.transitions, sources: sources)
                let isStale = loadGeneration != timelineGeneration
                if !isStale {
                    apply(built: built, generation: loadGeneration)
                }
                if let r = renderer {
                    // stale の場合、割り込んだ編集側の rebuild が composition を
                    // 先に差し替えていればそちらを使う（無ければ built を暫定表示し、
                    // 直後の再構築で現行世代の合成結果に置き換わる）。
                    // composition と videoComposition / audioMix は**必ず同じ組**で使う
                    // （別世代の組み合わせは尺・向き・音量が食い違う）。
                    let useBuilt = composition == nil
                    let asset: AVAsset = composition ?? built.composition
                    previewController = MosaicPreviewController(
                        renderer: r, asset: asset, model: self,
                        videoComposition: useBuilt ? built.videoComposition : videoComposition,
                        audioMix: useBuilt ? built.audioMix : audioMix)
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
            // タイムライン（＝適用区間）と previewController が揃った**この時点**で、
            // 現在の再生位置のフレームを必ず 1 枚描き直す。一般的な動画編集アプリと同じく
            // 「開いた瞬間に、いまの編集状態どおりの絵が出ている」状態にするため。
            //
            // ここが無いと、同期部の `renderPreview()`（素材の生フレームに対する暫定表示。
            // 合成もモザイク適用区間も反映されない）が残り続ける。下書き復元では
            // `applyRestoredParameters()` を含む 3 回の `renderPreview` がすべてこの Task より
            // 先に、クリップ 0 本・適用区間 0 個の状態で走り終わっており、displayLink は
            // `play()` でしか回らないため描き直す機会が二度と来ない
            // （実測: 復元後 2 秒放置で `renderCurrentFrame` 実行 0 回、previewImage の中央画素は
            // 適用区間外なのに [127,127,127]＝モザイクのまま。シークして初めて素の映像になる）。
            await previewController?.renderInitialFrame(at: playbackPosition)
            #if DEBUG
            print(String(format: "[MMLOAD] first frame done %.2fs",
                         Date().timeIntervalSince(loadStart)))
            #endif
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

    /// 先頭フレームの用意（表示・背景マスク）と初期スキャン（顔シード）。
    ///
    /// `load(videoURL:)` の**非同期**部から呼ぶ。同期部でやると画面遷移が止まる
    /// （呼び出し元のコメント参照）。検出条件・シード時刻・自動選択規則は
    /// 同期部にあった頃と同一。
    ///
    /// **`detectedFaces` は置き換えず追記する**（`seedVideoDetection` と同じ規則）。
    /// 非同期になった結果、`load` が返ってから結果が届くまでのあいだに
    /// 顔が入りうる——下書き復元（`applyRestoredParameters` は `load` の直後に走る）や
    /// ライブ検出の安全網——ため、置き換えるとそれらを黙って消す
    /// （実測: 復元した顔選択が丸ごと失われ、`detectedFaces` が空になった）。
    /// 列は `load` の同期部で空にしてあるので、通常経路では追記＝置き換えと同じ結果になる。
    private func loadSeedFaces(from asset: AVAsset) async {
        guard let frame = Self.firstFrame(of: asset) else { return }
        sourceImage = frame
        sourceTexture = makeTexture(from: frame)
        updateBackgroundMask(from: frame)

        let scan = await scanSeedFaces(of: asset, firstFrame: frame)
        let faces = scan.faces
        let seedFrame = scan.frame
        let seedTime = scan.time

        // 初期スキャン結果を「実際に顔が写っていた時刻」のバケットにシードして、
        // 再生開始・スクラブ前でも MosaicPreviewController がランドマークを引ける
        // ようにする。seedTime>0（先頭に顔なし）のとき t=0 に入れてはいけない:
        // 未来の顔位置を冒頭フレームに描くことになり、顔がまだ無い場所（体や背景）
        // にモザイクが乗る。t=0 に顔が無い事実はライブ検出が空エントリとして
        // 記録し、ホールドフォールバックはそれを尊重して描かない。
        if !faces.isEmpty {
            cacheStore.store(faces, sourceID: currentSourceID, time: seedTime)
        }
        // 人物 ID は `detectedFaces` へ載せる**前に**決める。下書き復元の顔選択は
        // これを使って結び直すため（`seedPersonIDs` の doc）。
        // `cacheStore.store` と同じ `seedTime` で入れること。
        let personIDs = seedPersonIDs(for: faces, in: seedFrame,
                                      sourceID: currentSourceID, time: seedTime)
        detectedFaces += faces.enumerated().map { idx, lm in
            // 顔が1つだけならユーザーの意図として自動選択する（サムネを
            // タップさせないと何も起きない不親切な挙動を避ける）。複数顔なら
            // 「どれをモザイクするか」の選択余地を残す。
            let autoSelect = faces.count == 1 && idx == 0
            return FaceTarget(id: UUID(), landmarks: lm,
                              thumbnail: generateThumbnail(for: lm, from: seedFrame),
                              isSelected: autoSelect,
                              sourceID: currentSourceID,
                              personID: personIDs[idx])
        }
        // 素材の生フレームでの暫定表示（この後 composition が揃った時点で
        // `renderInitialFrame` が合成・適用区間まで反映した絵へ差し替える）。
        // **顔を反映した後に描くこと。** 先に描くと、初期スキャンが終わるまでの
        // あいだ素の顔がプレビューに出る（モザイクの不足は事故、という原則に反する）。
        renderPreview()
    }

    /// 動画素材の初期スキャン（検出シード用の「顔が写っているフレーム」探し）。
    ///
    /// `load(videoURL:)`（最初の素材）と `appendVideoClip(url:)`（追加素材）の
    /// **共通処理**。検出条件（IMAGE モード・480px 縮小・probe 範囲）が経路ごとに
    /// ずれると「最初の動画では拾えるが、追加した動画では拾えない」が黙って成立するため
    /// 二重実装しないこと。
    ///
    /// 最初の1フレームを単独検出するのは IMAGE モードの仕事。
    /// VIDEO モードは連続ストリームの時系列追跡用で、最初のフレームを
    /// 単体で処理するのが苦手（init 失敗 → NullFaceLandmarker になるケースも）。
    ///
    /// t=0 の初期フレームに顔が写っていない動画（画面録画の導入カット等）だと
    /// ここで空になり、再生開始でモザイクが消え・追従バッジが「探索中 0%」に落ちる。
    /// 実機で「顔サムネ100%だが探索中0%、シークで初めて検出」と報告される症状の中核。
    /// → 空だった場合は数秒先まで低fpsで探索し、最初に顔が取れたフレームを
    ///   サムネ／検出シード用フレームとして採用する（プレビューは先頭フレームのまま）。
    /// 実機のライブ検出は 480px 幅の縮小フレームで走る（MosaicPreviewController
    /// 参照）。初期スキャンをフル解像度で通してしまうと「初期はシードされるが
    /// 続くライブ検出では拾えない」という条件差が生まれ、ホールドフォールバック
    /// が古い顔位置を体に貼り続ける原因になる。ライブと同じ 480px で判定する。
    ///
    /// **`async` である理由**: probe は最大 24 コマぶんのデコード + 検出になり、
    /// 同期で回すと画面遷移が丸ごと止まる（ユーザー報告「動画選択後、編集画面に
    /// 遷移するのに時間がかかる」の主因）。1 コマごとに `Task.yield()` を挟んで
    /// 実行の機会を返し、`isLoading` の表示と遷移アニメーションを動かし続ける。
    /// 検出条件（IMAGE モード・480px 縮小・probe 範囲）は変えていない。
    ///
    /// - Returns: 検出できた顔（空あり）と、それが写っていたフレーム・素材時刻。
    func scanSeedFaces(of asset: AVAsset, firstFrame frame: UIImage) async -> SeedScan {
        let initialScanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let faces = initialScanner.allLandmarks(in: Self.downscaleForDetection(frame))
        guard faces.isEmpty else { return SeedScan(faces: faces, frame: frame, time: 0) }
        // 短尺動画（リール等）は顔が終盤にしか写らないことがある。3s 固定 probe だと
        // 例えば 4s 動画で顔を逃す → シードなし → 再生開始でモザイクが掛からない。
        // 動画長に合わせて probe 範囲を可変にする（上限 6s、下限は動画全長）。
        // 同期取得（asset.duration の直読み）。CMTime.seconds が nan の動画があるので
        // isFinite/正数チェックで守る。
        let rawDur = CMTimeGetSeconds(asset.duration)
        let dur = (rawDur.isFinite && rawDur > 0) ? rawDur : 3.0
        let probeEnd = min(max(dur - 0.1, 0.25), 6.0)
        // **generator は 1 個を使い回す。** probe ごとに作り直すとコマ数ぶん
        // デコーダを立ち上げ直すことになり、探索が丸ごと遅くなる。
        let generator = Self.makeFrameGenerator(for: asset)
        for probeTime in stride(from: 0.25, through: probeEnd, by: 0.25) {
            await Task.yield()
            guard let probeFrame = Self.frame(from: generator, at: probeTime) else { continue }
            let probeFaces = initialScanner.allLandmarks(in: Self.downscaleForDetection(probeFrame))
            if !probeFaces.isEmpty {
                return SeedScan(faces: probeFaces, frame: probeFrame, time: probeTime)
            }
        }
        return SeedScan(faces: [], frame: frame, time: 0)
    }

    /// `scanSeedFaces(of:firstFrame:)` の結果（検出顔・その顔が写っていたフレーム・素材時刻）。
    struct SeedScan {
        let faces: [FaceLandmarkSet]
        let frame: UIImage
        let time: Double
    }

    /// `load(videoURL:)` の Task 内でタイムラインを初期化する。
    ///
    /// 下書き復元の予約（`queueTimelineRestore`）があれば保存されていた素材表と
    /// タイムラインをそのまま適用し（primary はロード済み asset を使い回して
    /// 同一ファイルの二重ロードを避ける）、無ければ素材全体を使う単一クリップ
    /// （編集はここから始まる）。
    ///
    /// 最後に履歴基準を取り直す: load 末尾の同期 `resetHistory()` はこの Task より先に
    /// 走るため、基準スナップショットの timeline が空のまま残る。そのまま最初の編集を
    /// commit すると「空タイムラインの undo エントリ」が積まれ、undo が実質 no-op の
    /// 履歴になる（`apply(_:)` は空タイムラインを復元しない）。下書き再開時も
    /// `applyRestoredParameters`（同期）→ ここ、の順なので、復元済みパラメータ＋
    /// 復元タイムラインが揃った状態が基準になる。
    private func installInitialTimeline(primaryAsset asset: AVAsset, seconds: Double) {
        if let restore = pendingTimelineRestore {
            pendingTimelineRestore = nil
            var restoredSources: [UUID: AVAsset] = [:]
            for (id, url) in restore.sourceURLs {
                restoredSources[id] = (id == restore.primarySourceID) ? asset : AVAsset(url: url)
            }
            sources = restoredSources
            timeline = restore.timeline
        } else {
            sources = [currentSourceID: asset]
            // **適用区間の自動生成はここ（新しいクリップが生まれる瞬間）だけ**（不変条件 I5）。
            // 新仕様では区間 0 本 = 全区間 OFF なので、生成しないと新規プロジェクトが
            // 「どこにもモザイクが乗らない」状態で始まる。
            // restore 分岐では**何もしない**: 旧データの変換は `TimelineState.init(from:)` で
            // 完了済みであり、ここで再生成すると「意図的に全削除した下書き」が復活する。
            let clip = TimelineClip(sourceID: currentSourceID, sourceStart: 0, sourceEnd: seconds)
            // 初期クリップは常に動画素材（写真モードはこの経路を通らない）。
            timeline = TimelineState(clips: [clip],
                                     applyRanges: MosaicApplyGate.fullCoverRanges(
                                        for: [clip], photoSourceIDs: []))
        }
        // 直後の resetHistory() が「生成済みの状態」を履歴の基準にするので、
        // undo の起点も自動生成後の状態になる（自動生成が undo を汚さない）。
        resetHistory()
    }

    // MARK: - 顔選択

    public func toggleFace(_ id: UUID) {
        guard let idx = detectedFaces.firstIndex(where: { $0.id == id }) else { return }
        detectedFaces[idx].isSelected.toggle()
        renderPreview()
        previewController?.invalidate()
        commitEdit()
    }

    /// 指定したターゲットが指している人物（同定できているものだけ・重複なし）。
    /// 1 人も同定できていなければ空を返し、判定は従来どおり位置追跡だけになる。
    func selectedPersonProfiles(of targets: [FaceTarget]) -> [PersonProfile] {
        var seen = Set<UUID>()
        return targets.compactMap(\.personID)
            .filter { seen.insert($0).inserted }
            .compactMap { personRegistry.person(id: $0) }
    }

    /// 顔一覧を「人物」単位でまとめた並び。同じ人物 ID の顔は 1 つのまとまりになり、
    /// 人物 ID が付いていない顔（署名が取れていない）はそれぞれ単独のまとまりになる。
    /// 並び順は `detectedFaces` の出現順を保つ（一覧が毎フレーム入れ替わらないため）。
    public var personGroups: [PersonGroup] {
        PersonGrouping.groupIndices(personIDs: detectedFaces.map(\.personID))
            .compactMap { indices in
                let members = indices.map { detectedFaces[$0] }
                guard let representative = members.first else { return nil }
                return PersonGroup(representative: representative, members: members)
            }
    }

    /// 人物単位で選択を切り替える。**まとまり内の全員を同じ状態に揃える**
    /// （途中でフレームアウト→再入して増えたターゲットの片方だけ選択が外れると、
    /// 同じ人が区間によって隠れたり隠れなかったりする）。
    /// 新しい状態は「まとまりの誰か 1 人でも選択されていれば解除、誰も選択されていなければ選択」。
    public func togglePerson(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let anySelected = detectedFaces.contains { idSet.contains($0.id) && $0.isSelected }
        for (i, face) in detectedFaces.enumerated() where idSet.contains(face.id) {
            detectedFaces[i].isSelected = !anySelected
        }
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
    ///
    /// **アクセスレベル**: レターボックスの逆写像結果（`rect`）を実素材なしで検証したいので
    /// `internal`（`TimelineEditingModelTests` が `scanSegments(searchRect:)` を直接叩く）。
    struct RegionScanSegment {
        let asset: AVAsset
        /// nil は素材全体（`findFaceInVideo` が duration をロードして決める）。
        let range: ClosedRange<Double>?
        let sourceID: UUID
        /// **素材フレーム基準**へ逆写像済みのクロップ矩形
        /// （`TimelineRenderLayout.inverseRemap`）。`findFaceInVideo` はこれをそのまま
        /// 素材ピクセルへ掛ける。ユーザーが描いた合成フレーム基準の矩形を無変換で
        /// 当てると、レターボックスされたクリップで確定的にずれる。
        let rect: CGRect
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
    ///
    /// `rect` は**プレビュー（＝合成フレーム）基準**の正規化矩形。素材へ当てる前に
    /// クリップごとに `renderLayout.inverseRemap` で素材フレーム基準へ戻す
    /// （`scanSegments(searchRect:)`）。得られるランドマークは素材座標なので、
    /// `detectedFaces` の他の要素（ライブ検出・初期スキャン）と座標系が揃う。
    private func resolveRegion(_ rect: CGRect, referenceImage: UIImage?) async {
        guard mode == .video, videoAsset != nil else {
            appendManualRect(rect)
            return
        }
        isScanning = true
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let segments = scanSegments(searchRect: rect)
        let result: RegionScanHit? = await Task.detached(
            priority: .userInitiated
        ) { [scanner, segments] in
            // タイムライン順に各クリップの使用区間を走査し、最初の検出を採用する。
            for segment in segments {
                guard !Task.isCancelled else { return nil }
                if let (landmarks, frame) = await Self.findFaceInVideo(
                    asset: segment.asset, rect: segment.rect,
                    scanner: scanner, scanRange: segment.range) {
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

    /// 矩形サーチ（`resolveRegion`）が走査すべき素材・使用区間・**素材基準の矩形**の列。
    /// クリップ列があればその使用区間のみ。クリップ未構築（Composition 構築前）の間は
    /// 従来どおり素材全体。
    ///
    /// - Parameter rect: プレビュー（合成フレーム）基準の正規化矩形。
    ///
    /// クリップごとに `renderLayout.inverseRemap` でレターボックスの逆写像を掛ける。
    /// 恒等レイアウト（無変換タイムライン・先頭クリップ）では矩形がそのまま返るため
    /// 挙動不変。逆写像が nil（矩形が完全に黒帯の中）のクリップは走査対象から外す
    /// （そのクリップの素材にはユーザーが指した領域が存在しない）。
    ///
    /// **アクセスレベル**: 逆写像の配線を実素材なしで検証するためテストから呼ぶので
    /// `internal`（`RegionScanSegment` も同じ理由で `internal`）。
    func scanSegments(searchRect rect: CGRect) -> [RegionScanSegment] {
        guard !clips.isEmpty else {
            guard let asset = videoAsset else { return [] }
            return [RegionScanSegment(asset: asset, range: nil,
                                      sourceID: currentSourceID, rect: rect)]
        }
        return clips.compactMap { clip in
            guard let asset = sources[clip.sourceID], clip.sourceEnd > clip.sourceStart else { return nil }
            guard let sourceRect = renderLayout.inverseRemap(rect, clipID: clip.id) else { return nil }
            return RegionScanSegment(asset: asset,
                                     range: clip.sourceStart...clip.sourceEnd,
                                     sourceID: clip.sourceID,
                                     rect: sourceRect)
        }
    }

    /// 素材の指定区間（nil なら全体）を1fpsでサンプリングし、矩形クロップ内で顔を探す。
    /// 最初の検出結果を返す。
    ///
    /// `rect` は**素材フレーム基準**（`scanSegments(searchRect:)` が逆写像済み）。
    /// 返すランドマークも `remapped(into: rect)` で素材フレーム基準へ戻したものになる。
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
            replaceDetectedFaces(
                found.map { lm in
                    FaceTarget(id: UUID(), landmarks: lm,
                               thumbnail: generateThumbnail(for: lm, from: frame),
                               isSelected: false,
                               sourceID: faceSourceID)
                },
                ofSource: faceSourceID
            )
            sourceImage = frame
            sourceTexture = makeTexture(from: frame)
            updateBackgroundMask(from: frame)
            renderPreview()
            previewController?.invalidate()
        }
    }

    /// 再検出結果を **その素材の顔だけ** に反映する（他素材の顔と選択はそのまま残す）。
    ///
    /// `detectedFaces` を丸ごと差し替えると、`found` は現在表示中の 1 素材の顔しか
    /// 含まないため、複数クリップでは**他素材の顔とその選択が消える**＝その区間の
    /// モザイクが外れる。追加素材の `seedVideoDetection` / `seedPhotoDetection` が
    /// `detectedFaces += …`（既存を壊さない追記）なのと同じ流儀に揃える。
    ///
    /// 選択の引き継ぎ（`carryingOverSelection`）も**素材スコープ**で行う: 比較対象を
    /// 全素材の選択顔にすると、他素材の選択顔と重心が近いだけで選択が付いたり、
    /// 逆に他素材が選択済みなのを理由にフェイルクローズ（その素材の全選択）が
    /// 働かなくなったりする。
    ///
    /// 並び順は元の位置を保つ（顔サムネの並びが再検出のたびに入れ替わらない）。
    func replaceDetectedFaces(_ newFaces: [FaceTarget], ofSource sourceID: UUID?) {
        let carried = carryingOverSelection(
            newFaces,
            previousSelected: detectedFaces.filter { $0.isSelected && $0.sourceID == sourceID }
        )
        // 先頭から続く「他素材の顔」の数 = 差し替え後の挿入位置。
        let insertAt = detectedFaces.prefix { $0.sourceID != sourceID }.count
        var result = detectedFaces.filter { $0.sourceID != sourceID }
        result.insert(contentsOf: carried, at: min(insertAt, result.count))
        detectedFaces = result
    }

    /// redetect 用の選択引き継ぎ。新しい顔候補に旧選択状態を重心マッチ（<0.5）で
    /// 引き継ぎ、誰も選択されない結果になる場合は全選択にフォールバックする。
    /// 「再検出」を押す意図は常に「顔にモザイクを掛けたい」なので、選択が空になって
    /// 以降モザイクが一切掛からなくなる方向には決して倒さない（フェイルクローズ）。
    ///
    /// 素材スコープの絞り込みは呼び出し側（`replaceDetectedFaces`）の責務。
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

    /// 静止プレビュー（`sourceTexture` 1 枚）を描いて `previewImage` を更新する。
    ///
    /// **モザイク適用区間ゲート（S10）はここには入れない。** この関数は合成タイムライン
    /// 時刻を持たない写真タブ経路と共用であり、また `sourceTexture` は素材の生フレームで
    /// 合成結果ではないため、ここで作る絵は本質的に「合成前の暫定表示」である。
    /// 動画モードの正しい絵は必ず `MosaicPreviewController` が合成済みフレームから作る
    /// （ゲートもそちらに 1 箇所だけ置く）。ロード・下書き復元の直後は
    /// `MosaicPreviewController.renderInitialFrame(at:)` が現在位置のフレームを
    /// 1 枚描き直して、この暫定表示を必ず上書きする（`installInitialTimeline` の doc 参照）。
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
    ///
    /// 参照する顔は `displayFaces(at:)`（重なり区間は 2 クリップぶんの union・
    /// レターボックス写像込み）。
    ///
    /// **座標系を混ぜないこと（重要）**: `displayFaces(at:)` の返り値は**合成フレーム基準**、
    /// `FaceTarget.landmarks` は検出時のままの**素材フレーム基準**なので、両者の重心を
    /// 直接比べてはならない（レターボックスの実測ずれは最大 0.175。閾値 0.5 に対して
    /// 単独顔では落ちないが、顔が 2 人以上で互いに 0.35 以内に居ると誤マッチしうる）。
    /// 絞り込みは `displayFaces(at:matching:)` に渡し、**写像の前・素材座標のまま**
    /// 行わせる（順序の理由はそちらの doc 参照）。
    func selectedLandmarks(at time: Double) -> [FaceLandmarkSet] {
        guard faceMosaicOn else { return [] }
        let selected = detectedFaces.filter(\.isSelected)
        if selected.isEmpty { return [] }
        // 全選択なら絞り込み自体が恒等（照合を回すだけ無駄）。
        if selected.count == detectedFaces.count { return displayFaces(at: time) }
        return displayFaces(at: time, matching: selected)
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
    /// 人物署名（原寸フレームの取り出し + SFace 推論）専用の直列キュー。
    ///
    /// **検出キューと分ける。** 署名の仕事を検出と同じキューに乗せると、検出の
    /// スループットがそのぶん落ちる（実測: 原寸変換を検出キューでやると s1.mov 後半の
    /// 検出バケットが 13/10/10 → 9/10/7。ホールド窓 0.75s を超える穴が空き、
    /// 再生中にモザイクが消えるフレームが出る）。**検出の退行は誤モザイクより重い**ので、
    /// 署名は検出の後ろで非同期に追いつく形にする。
    ///
    /// 遅れて書いても壊れないのは、`FaceSignatureCache` が（素材ID, 素材時刻）キーと
    /// **重心の位置照合**で顔と署名を結ぶため——検出と同じ呼び出しの中で書く必要がない。
    /// qos は検出より低い（署名は無くても位置追跡へ落ちて動き続ける補助情報）。
    let liveSignatureQueue =
        DispatchQueue(label: "com.maskme.livesignature", qos: .utility)
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

    /// 下書き復元の予約内容（S5）。`queueTimelineRestore` 参照。
    struct TimelineRestoreRequest {
        let timeline: TimelineState
        let sourceURLs: [UUID: URL]
        let primarySourceID: UUID
    }

    /// 下書き復元用の予約（S5）。`load(videoURL:)` が既定の「素材全体1クリップ」の
    /// 代わりに適用するタイムラインと素材表。
    ///
    /// `load` は非同期 Task の中で timeline を初期化するため、load の後から timeline を
    /// 差し替える方式だと「復元 → load Task が単一クリップで上書き」の順序逆転が起きる。
    /// そこで load の**前**に予約し、load 自身が適用する（適用後は破棄）。
    private var pendingTimelineRestore: TimelineRestoreRequest?

    /// 下書きの復元内容を予約する。`load(videoURL:)` の**前**に呼ぶこと。
    ///
    /// - Parameters:
    ///   - timeline: 保存されていたタイムライン（空なら予約しない =
    ///     v1 下書き相当。load の既定「素材全体1クリップ」で復元される）。
    ///   - sourceURLs: 素材ID → 下書きフォルダ内のコピー済み素材ファイル。
    ///   - primarySourceID: `load(videoURL:)` へ渡す URL に対応する素材ID。
    ///     初期スキャンのシード・顔サムネの帰属先をこのIDに揃える。
    func queueTimelineRestore(timeline: TimelineState,
                              sourceURLs: [UUID: URL],
                              primarySourceID: UUID) {
        guard !timeline.clips.isEmpty else { return }
        pendingTimelineRestore = TimelineRestoreRequest(
            timeline: timeline, sourceURLs: sourceURLs, primarySourceID: primarySourceID)
    }

    /// 下書き保存用: タイムラインが参照する素材の (素材ID, ファイルURL) 列。
    /// クリップ出現順・重複なし。先頭が primary（`EditingDraft.sourceFileName` になり、
    /// 再開時に最初へロードされる素材）。クリップ未構築の間は最後にロードした素材のみ
    /// （v1 相当のフォールバック）。
    var draftSources: [(id: UUID, url: URL)] {
        guard !clips.isEmpty else {
            guard let url = sourceVideoURL else { return [] }
            return [(currentSourceID, url)]
        }
        var seen = Set<UUID>()
        var result: [(id: UUID, url: URL)] = []
        for clip in clips where !seen.contains(clip.sourceID) {
            seen.insert(clip.sourceID)
            // load / 復元経路の asset は常に AVAsset(url:)（= AVURLAsset）。
            // URL を持たない asset（テスト直注入等）は下書きに保存できないので落とす。
            guard let url = (sources[clip.sourceID] as? AVURLAsset)?.url else { continue }
            result.append((clip.sourceID, url))
        }
        return result
    }

    /// 下書き再保存時の GC 保護リスト: 現在のタイムラインに加えて、undo / redo
    /// スタック（と履歴基準 `lastCommitted`）の全スナップショットが参照する素材ID集合。
    ///
    /// 下書き再開中のセッションは素材実体として下書きフォルダ内のコピーを参照して
    /// いるため、現在の `draftSources` だけを根拠に GC すると「クリップ削除 → 再保存」で
    /// undo により復活し得るクリップの素材実体が消える。`DraftStore.saveVideoDraft` の
    /// `sessionSourceIDs` にそのまま渡すこと（アーキテクチャ決定 7
    /// 「素材 GC は下書き保存時のみ。セッション中は undo 用に保持」の担保）。
    var sessionReferencedSourceIDs: Set<UUID> {
        var ids = Set(timeline.clips.map(\.sourceID))
        for snap in undoStack { ids.formUnion(snap.timeline.clips.map(\.sourceID)) }
        for snap in redoStack { ids.formUnion(snap.timeline.clips.map(\.sourceID)) }
        if let last = lastCommitted { ids.formUnion(last.timeline.clips.map(\.sourceID)) }
        return ids
    }

    /// 下書き保存用: いま選択されている顔の目印（素材ID＋**素材フレーム基準**の
    /// 正規化重心）。`DraftStore.saveVideoDraft` / `savePhotoDraft` の
    /// `faceSelections` にそのまま渡す。
    ///
    /// 顔 ID は保存しない（`DraftFaceSelection` の doc 参照。検出のたびに
    /// `UUID()` を振り直すため復元時の顔と一致しない）。
    var selectedFaceAnchors: [DraftFaceSelection] {
        detectedFaces.filter(\.isSelected).map {
            DraftFaceSelection(sourceID: $0.sourceID,
                               centroid: normalizedCentroid(of: $0.landmarks),
                               personID: $0.personID)
        }
    }

    /// `selectedFaceAnchors` の `personID` が指す人物（下書きへ保存する分）。
    ///
    /// **選択されている顔の人物だけ**を返す。台帳全体ではない理由は
    /// `EditingDraft.personProfiles` の doc 参照（生体特徴を必要以上にディスクへ残さない）。
    var selectedPersonProfilesForDraft: [PersonProfile] {
        selectedPersonProfiles(of: detectedFaces.filter(\.isSelected))
    }

    /// 下書きから復元したパラメータを適用してプレビューを更新する。
    ///
    /// - Parameter faceSelections: 保存されていた顔選択の目印。
    ///   nil は「情報なし」（新フィールド導入前の下書き）で、顔の選択状態には
    ///   一切触らない＝初期スキャンの自動選択規則がそのまま残る。
    public func applyRestoredParameters(
        faceMosaicOn: Bool,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect],
        faceSelections: [DraftFaceSelection]? = nil,
        personProfiles: [PersonProfile]? = nil
    ) {
        // 人物は**目印より先に**台帳へ戻す。目印は人物 ID で顔を指しており、
        // 台帳に居ない人物 ID はどの顔とも結び付かない（＝位置照合へ落ちる）。
        // ここで戻しておけば、この後の初期スキャン・ライブ検出が署名から
        // 同じ人物 ID を復元し、保留していた目印もそのまま結び直せる。
        if let personProfiles {
            personRegistry.merge(personProfiles)
        }
        self.faceMosaicOn = faceMosaicOn
        self.backgroundMosaicOn = backgroundMosaicOn
        self.faceBlockSize = faceBlockSize
        self.backgroundBlockSize = backgroundBlockSize
        self.manualRegions = manualRects.map { ManualRegion(id: UUID(), normalizedRect: $0) }
        // 顔選択は resetHistory より**前**に復元する（復元後の状態が履歴の起点になる。
        // ここで直さないと、末尾の resetHistory で undo からも取り戻せなくなる）。
        if let faceSelections {
            restoredSelectionSourceIDs = knownSourceIDsAtRestore()
            restoreFaceSelection(from: faceSelections)
        }
        recomputeBackgroundMask()
        renderPreview()
        previewController?.invalidate()
        resetHistory()
    }

    // MARK: - 下書きからの顔選択の復元

    /// 保存されていた顔選択の目印を、いま検出されている顔へ再照合して適用する。
    ///
    /// 照合は素材スコープで区切ったうえで `DraftSelectionResolver` に委ねる。
    /// **人物（署名から復元した人物 ID）で先に照合し、決まらないものだけ位置へ落とす**。
    /// 位置照合の作法は `selecting(_:sourceID:targets:)`（プレビュー描画の顔絞り込み）と
    /// 同じ——素材フレーム基準の重心距離 < 0.5——で変えていない。
    ///
    /// **照合に失敗したときは安全側（過剰適用）へ倒す**。素材ごとに、その素材へ
    /// 向けられた目印が**全部**顔にマッチしたときだけ「マッチした顔だけを選択」し、
    /// 1 つでもマッチしなかった目印があれば**その素材の顔を全選択**する
    /// （保存時に選択されていた顔の行方が説明できない ＝ 顔が露出しうる状態なので、
    /// 掛けすぎる方向へ倒す。このプロジェクトの原則「モザイクの過剰適用は安全側・
    /// 不足は事故」）。
    ///
    /// 目印が 1 つも無い素材の扱いは、**その素材が復元時点で下書きに含まれていたか**で
    /// 分かれる（`restoredSelectionSourceIDs`）:
    /// - 含まれていた素材: 非選択にする（保存時に選択が無かったというユーザーの明示的な意思）。
    /// - 復元**後**に追加された素材: 一切触らない。保存時に存在しなかった素材に
    ///   「保存時に非選択だった」という解釈は成立しない。触ると、目印の適用が保留中
    ///   （冒頭に顔が写らない動画）に素材を追加したとき、`seedVideoDetection` /
    ///   `seedPhotoDetection` の自動選択が didSet 経由で即座に打ち消され、
    ///   **追加クリップの区間だけモザイクが乗らない**（顔が露出する）。
    ///
    /// 検出がまだ 1 つも無い（初期スキャンが空だった）場合は目印を保持しておき、
    /// ライブ検出が顔を見つけた時点で適用する（`pendingFaceSelectionAnchors`）。
    private func restoreFaceSelection(from anchors: [DraftFaceSelection]) {
        guard !detectedFaces.isEmpty else {
            // 空の目印（＝保存時も 0 個選択）を保留しない: 保留すると、後から
            // ライブ検出が拾った顔の自動選択（顔 1 つなら選択）まで打ち消してしまう。
            pendingFaceSelectionAnchors = anchors.isEmpty ? nil : anchors
            return
        }
        pendingFaceSelectionAnchors = nil
        var indicesBySource: [UUID?: [Int]] = [:]
        for (index, face) in detectedFaces.enumerated() {
            indicesBySource[face.sourceID, default: []].append(index)
        }
        for (sourceID, indices) in indicesBySource {
            // 素材スコープ: sourceID が nil 側（写真モード・素材ID導入前）は素材不問。
            let scoped = anchors.filter { anchor in
                guard let anchorSource = anchor.sourceID, let sourceID else { return true }
                return anchorSource == sourceID
            }
            guard !scoped.isEmpty else {
                // 復元後に追加された素材（目印の対象外）には触らない。
                if let sourceID, let known = restoredSelectionSourceIDs, !known.contains(sourceID) {
                    continue
                }
                for index in indices { detectedFaces[index].isSelected = false }
                continue
            }
            // 判定は純ロジック（`DraftSelectionResolver`）へ委ねる。
            // 添字は `indices` の並び（＝この素材の顔）に対する相対添字で返る。
            let resolution = DraftSelectionResolver.resolve(
                anchors: scoped.map {
                    DraftSelectionResolver.Anchor(personID: $0.personID, centroid: $0.centroid)
                },
                faces: indices.map {
                    DraftSelectionResolver.Face(
                        personID: detectedFaces[$0].personID,
                        centroid: normalizedCentroid(of: detectedFaces[$0].landmarks))
                },
                centroidThreshold: faceMatchThreshold)
            for (offset, index) in indices.enumerated() {
                detectedFaces[index].isSelected = resolution.selected.contains(offset)
            }
        }
    }

    /// 初期スキャンが空だったため適用を保留した顔選択の目印。
    /// ライブ検出が顔を見つけて `detectedFaces` が埋まった時点で適用する。
    private var pendingFaceSelectionAnchors: [DraftFaceSelection]?

    /// 下書き復元の時点でタイムラインに含まれていた素材ID（`restoreFaceSelection` の
    /// 「目印が 1 つも無い素材」の判定に使う）。nil は「下書き復元をしていない」。
    private var restoredSelectionSourceIDs: Set<UUID>?

    /// 復元時点で下書きが参照している素材IDを集める。
    ///
    /// `applyRestoredParameters` は `load(videoURL:)` の非同期 Task
    /// （`installInitialTimeline` が `sources` / `timeline` を埋める）より先に走りうるので、
    /// **まだ適用されていない予約**（`pendingTimelineRestore`）も含めて union を取る。
    private func knownSourceIDsAtRestore() -> Set<UUID> {
        var ids: Set<UUID> = [currentSourceID]
        ids.formUnion(sources.keys)
        ids.formUnion(timeline.clips.map(\.sourceID))
        if let restore = pendingTimelineRestore {
            ids.formUnion(restore.sourceURLs.keys)
            ids.formUnion(restore.timeline.clips.map(\.sourceID))
        }
        return ids
    }

    /// 保留中の目印を破棄する（メディアの読み込み直し時）。
    private func clearPendingFaceSelectionAnchors() {
        pendingFaceSelectionAnchors = nil
        restoredSelectionSourceIDs = nil
    }

    /// `detectedFaces` が（ライブ検出の安全網などで）後から埋まったときに、
    /// 保留していた下書きの顔選択を適用する。`detectedFaces` の didSet から呼ぶ。
    private func applyPendingFaceSelectionAnchorsIfNeeded() {
        guard let anchors = pendingFaceSelectionAnchors, !detectedFaces.isEmpty else { return }
        // restoreFaceSelection 内の再代入で didSet が再入するため、先に保留を解除する
        // （解除済みなら上の guard で必ず抜ける）。
        pendingFaceSelectionAnchors = nil
        restoreFaceSelection(from: anchors)
        renderPreview()
        previewController?.invalidate()
        // 復元した選択は「ユーザーの編集」ではないので undo 対象にしない。
        // まだ何も編集されていなければ履歴基準を取り直し、既に編集済みなら
        // 基準スナップショットの選択集合だけを現在値へ合わせる
        // （undo で復元済みの選択が外れる＝顔が露出する方向を作らない）。
        if undoStack.isEmpty && redoStack.isEmpty {
            resetHistory()
        } else {
            lastCommitted?.selectedFaceIDs = Set(detectedFaces.filter(\.isSelected).map(\.id))
        }
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
            manualRects: manualRegions.map(\.normalizedRect),
            trimRange: trimRange,
            timeline: timeline
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
        trimRange = snap.trimRange
        // タイムラインの復元。差分があるときだけ `replaceTimeline` が世代トークン付きの
        // 非同期 rebuild を起動する（undo 連打では古い世代の合成結果が
        // `rebuildComposition(generation:)` の照合で破棄される。新規機構は作らない）。
        //
        // 空タイムラインのスナップショットには適用しない: 空は「クリップ構築前」
        // （写真モード常時・動画は load 完了前の窓）の状態であり、復元すると
        // mapping が空になって時刻写像・尺の全経路が壊れる。動画 load 完了後の
        // スナップショットは常に非空なので、この guard で失われる正規の履歴は無い。
        if !snap.timeline.clips.isEmpty {
            replaceTimeline(snap.timeline)
        }
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
        editVersion &+= 1
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(lastCommitted ?? snapshot())
        lastCommitted = previous
        apply(previous)
        editVersion &+= 1
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        if let last = lastCommitted { undoStack.append(last) }
        lastCommitted = next
        apply(next)
        editVersion &+= 1
    }

    // MARK: - 保存・エクスポート

    public func savePhoto() async {
        guard let image = previewImage else { return }
        do {
            try await PhotosSaver.save(image: image)
            recents.add(kind: .photo, thumbnail: image)
            didSave = true
        } catch {
            // 権限拒否（`PhotosSaver.SaveError.notAuthorized`）を握り潰さず、
            // 次にすべきこと（設定で許可する）まで出す。
            errorMessage = failureMessage(for: error)
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
        // 書き出しは原寸のまま tmp へ書く。書き終わってから容量不足で失敗するより、
        // 開始前に見積もりと空き容量を比べて弾く（判断は core の純関数）。
        if let shortage = await storageShortageMessage(for: composition) {
            errorMessage = shortage
            return
        }
        exportProgress = 0
        isExportCancelling = false
        isExportSaving = false
        exportSession &+= 1
        let session = exportSession
        let exporter = VideoMosaicExporter(renderer: renderer, landmarker: landmarker)
        activeExporter = exporter
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
                // 人物同定の材料。プレビューと同じ判定関数（`FaceIdentityPolicy.hidden`）を
                // 通すために渡す。署名は値型スナップショットにして渡す（書き出し中も
                // 再生側が署名を書き込み続けるため、参照のまま渡すと競合する）。
                selectedPersons: selectedPersonProfiles(of: targetsForExport),
                faceSignatures: signatureCache.lookup(),
                manualRegions: manualRegions,
                detectionCaches: detectionCaches,
                mapping: mapping,
                // 写真素材の素材時刻は exporter 側でも 0 に clamp する
                // （t=0 seed に全フレームがヒットし、写真区間で実検出が走らない）。
                photoSourceIDs: timeline.photoSourceIDs,
                // モザイク適用区間（S10）。素材時刻アンカーのまま渡し、exporter が
                // フレームの合成時刻を写像してからゲート判定する（プレビューと同じ
                // `MosaicApplyGate` の純関数を通すので境界フレームの結果が一致する）。
                applyRanges: timeline.applyRanges,
                // 合成（トランジション・レターボックス・フレームレート上限）と
                // 音声ミックスはプレビューと同じものを渡す。composition と必ず組で
                // 差し替わる（`apply(built:generation:)`）ので世代がずれない。
                videoComposition: videoComposition,
                audioMix: audioMix,
                renderLayout: renderLayout,
                faceEnabled: faceMosaicOn,
                backgroundEnabled: backgroundMosaicOn,
                backgroundBlock: backgroundBlockSize,
                speed: exportSpeed,
                trimRange: trimRange
            ) { fraction in
                // 進捗は別スレッドから飛んでくるため、完了後に遅延到着した通知が
                // `exportProgress` を書き戻して進捗オーバーレイを復活させ得る。
                // セッショントークンで照合して古い通知を捨てる。
                Task { @MainActor [weak self] in
                    guard let self, self.exportSession == session else { return }
                    self.exportProgress = fraction
                }
            }
            // ここから先はキャンセル不可のフェーズ（`isExportSaving` の doc 参照）。
            // 中断要求済みならライブラリへ書かずに畳む（ユーザーの意図どおり「保存しない」）。
            if isExportCancelling {
                try? FileManager.default.removeItem(at: url)   // tmp に書き出し済みの実体を残さない
                throw CancellationError()
            }
            isExportSaving = true
            try await PhotosSaver.save(videoURL: url)
            if let thumb = previewImage {
                recents.add(kind: .video, thumbnail: thumb)
            }
            didSave = true
        } catch is CancellationError {
            // ユーザー自身の操作による中断なのでエラーとして通知しない。
        } catch {
            errorMessage = failureMessage(for: error)
        }
        // 遅延到着した進捗を弾くため、後始末の前にセッションを進める。
        exportSession &+= 1
        activeExporter = nil
        isExportCancelling = false
        isExportSaving = false
        exportProgress = nil
    }

    /// 空き容量が足りないときのユーザー向け文言（足りていれば nil）。
    ///
    /// 出力先は `FileManager.default.temporaryDirectory` なので、空き容量は
    /// **tmp のあるボリューム**を見る。空き容量が取得できない場合は判定せず通す
    /// （取得失敗を「容量不足」と断定して書き出しを止めないため）。
    private func storageShortageMessage(for composition: AVAsset) async -> String? {
        let tmp = FileManager.default.temporaryDirectory
        guard let capacity = try? tmp.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return nil }

        let seconds = CMTimeGetSeconds((try? await composition.load(.duration)) ?? .zero)
        let videoTrack = (try? await composition.loadTracks(withMediaType: .video))?.first
        let dataRate = Double((try? await videoTrack?.load(.estimatedDataRate)) ?? 0)
        let required = ExportStorageCheck.estimatedBytes(
            durationSeconds: seconds, videoBitsPerSecond: dataRate)
        guard !ExportStorageCheck.hasEnoughSpace(requiredBytes: required,
                                                 availableBytes: capacity) else { return nil }
        return ExportFailureReason.diskFull.message
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

    /// 顔の同一性を重心距離で判定する閾値（**素材フレーム基準**の正規化座標）。
    /// `selecting(_:sourceID:targets:)` / `carryingOverSelection(_:previousSelected:)`
    /// が使ってきた 0.5（広め）と同じ値。下書き復元の再照合もこれに揃える。
    let faceMatchThreshold: CGFloat = 0.5

    func normalizedCentroid(of landmarks: FaceLandmarkSet) -> CGPoint {
        guard !landmarks.points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        var sx: Float = 0; var sy: Float = 0
        for p in landmarks.points { sx += p.x; sy += p.y }
        let n = Float(landmarks.points.count)
        return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
    }

    /// 素材の先頭フレーム。`appendVideoClip(url:)`（別ファイルの extension）からも
    /// 使うため internal。
    static func firstFrame(of asset: AVAsset) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// probe 用の generator（顔シード探索で**使い回す**。作り直すとコマ数ぶん
    /// デコーダの立ち上げ直しになる）。
    static func makeFrameGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return gen
    }

    static func frame(from gen: AVAssetImageGenerator, at time: Double) -> UIImage? {
        let t = CMTime(seconds: time, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 合成時刻に対応するフレームを「写像した素材 asset ＋ 素材内時刻」から取り出す。
    /// Composition 経由の抽出より素材直読みのほうが速く確実、という従来方針を
    /// 写像込みで維持する（`composition` プロパティの doc コメント参照）。
    /// クリップ未構築（Composition 構築前の窓・`sources` 未登録）の間は従来どおり
    /// `videoAsset` の恒等参照にフォールバックする。
    ///
    /// **既知の割り切り（S8。composition + videoComposition 経由に切り替えない理由）**
    ///
    /// ここが返すのは**素材フレーム**であり、`videoComposition` によるレターボックス・
    /// トランジションは掛かっていない。一方 `AVPlayerItem` 経由の再生プレビューは
    /// 合成フレームなので、解像度が混在したタイムラインでは
    /// **シーク／一時停止のたびに絵の枠（帯の有無）が切り替わって見える**。
    /// これは表示上の構図の違いだけで、モザイクの位置ずれ・漏れは起きない:
    /// 静止プレビューを描く `renderPreview()` は `detectedFaces` の
    /// **素材フレーム基準**のランドマークをそのまま使うので、素材フレームと座標系が
    /// 一致している（合成フレーム基準の `selectedLandmarks(at:)` を使うのは再生経路だけ）。
    ///
    /// composition + videoComposition の image generator に切り替えると、この一貫性が
    /// 逆に壊れる:
    /// 1. `renderPreview()` が素材座標の顔を合成フレームへ描くことになり、
    ///    レターボックスされたクリップで**モザイクが確実にずれる**（表示だけの問題が
    ///    実害に格上げされる）。
    /// 2. `redetect(at:)` はこのフレームを検出に掛けて `storePreScanResult` で
    ///    **素材キー**に書き込む。合成フレームで検出すると座標系の違う結果が正規の検出として
    ///    キャッシュへ入り、エクスポート（キャッシュヒットで検出をスキップ）まで汚染される。
    /// 3. 再生用 `AVPlayerItem` が生きているまま videoComposition 付きの
    ///    `AVAssetImageGenerator` を回すのは、過去に実機全滅を招いた
    ///    「サムネ生成と再生の HW デコーダ衝突」と同じ形になる。
    ///
    /// 正しい直し方は「表示用フレーム（合成基準）と検出用フレーム（素材基準）を分ける」
    /// ことで、`renderPreview` の座標系変更を伴う。S8 の範囲を超えるため **S9 以降**に送る。
    func frameAtCompositionTime(_ compositionTime: Double) -> UIImage? {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: compositionTime)
        guard let asset = sources[sourceID] ?? videoAsset else { return nil }
        return Self.frame(from: Self.makeFrameGenerator(for: asset), at: sourceTime)
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
