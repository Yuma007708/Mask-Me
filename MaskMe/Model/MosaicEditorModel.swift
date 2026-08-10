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
        /// 手動矩形の ON/OFF。顔とは別に戻す（顔を切った undo で矩形まで戻らない）。
        var objectMosaicOn: Bool
        var backgroundMosaicOn: Bool
        var faceBlockSize: Float
        var backgroundBlockSize: Float
        var selectedFaceIDs: Set<UUID>
        /// 物体モザイク（矩形マスク）。旧 `manualRects: [CGRect]` の後継で、
        /// キーフレーム列ごと戻す（undo で位置の履歴が失われない）。
        var objectMasks: [ObjectMask]
        /// 書き出し範囲。S9 以降ユーザー操作からの書き込み経路は無い
        /// （`MosaicEditorModel.trimRange` の doc 参照）。常に `0...1`。
        var trimRange: ClosedRange<Double>
        var timeline: TimelineState
        /// 写真モードの編集状態（色調補正）。undo/redo 対象（写真モード底上げ 第1段）。
        /// 動画モードでは常に `.identity`（写真タブの UI が無いので触られない）。
        var photoEdit: PhotoEditState
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
    /// 物体モザイク。矩形は**素材フレーム基準**で持つ
    /// （`MosaicEditorModel+ObjectMask.swift` の doc 参照）。
    /// 編集は同 extension の `appendObjectMask` / `setObjectMaskKeyframe` /
    /// `removeObjectMaskKeyframe` / `removeObjectMask` を通す。
    ///
    /// **didSet で自動追跡を張り直す。** 編集 API は `appendObjectMask` /
    /// `setObjectMaskKeyframe` / `removeObjectMaskKeyframe` / `removeObjectMask` /
    /// undo・redo / 下書き復元 / クリップ編集への追従と 7 経路あり、
    /// 個別に書くと新しい編集を足したときに必ず漏れる（`scheduleObjectTracking` は
    /// 追跡が不要なら即 return するので、無条件に呼んでよい）。
    @Published public internal(set) var objectMasks: [ObjectMask] = [] {
        didSet { scheduleObjectTracking() }
    }

    /// 物体モザイクの自動追跡（O2）の結果。マスク id 引き。
    ///
    /// **下書きには保存しない**（`ObjectTrack` の doc）。キーフレームから再計算できる
    /// 派生データであり、復元後に `scheduleObjectTracking()` が同じ軌跡を作り直す。
    /// 描画は `ObjectMaskResolver` が「キーフレームが一致する軌跡だけ」を採るため、
    /// 再計算が終わるまではキーフレーム補間のまま（＝軌跡が無くても壊れない）。
    @Published public internal(set) var objectTracks: [UUID: ObjectTrack] = [:]

    /// 追跡の進捗（0...1）。追跡していないときは nil。UI のバッジ表示用。
    @Published public internal(set) var objectTrackingProgress: Double?

    /// 走行中の追跡タスク（クリップ id 引き）。`masks` は**そのタスクが追い始めた時点の**
    /// マスク列で、これが今の状態と一致する間は張り替えない（同じ追跡の二重起動を防ぐ）。
    var objectTrackingTasks: [UUID: (masks: [ObjectMask], task: Task<Void, Never>)] = [:]

    /// クリップごとの追跡進捗（0...1）。`objectTrackingProgress` の材料。
    var objectTrackingProgressByClip: [UUID: Double] = [:]

    /// 範囲指定サーチが見つけた顔（シード）を前後へ追い続ける走査の待ち行列。
    /// FIFO・上限 8（`enqueueRegionSeed` の doc 参照）。挙動は
    /// `MosaicEditorModel+RegionSeeding.swift` にまとまっている
    /// （ここに置くのは Swift の extension が格納プロパティを持てないため）。
    var regionSeedQueue: [RegionSeed] = []
    /// 走行中のシード走査タスク（1 本構成。並行に何本も走らせない）。
    var regionSeedTask: Task<Void, Never>?
    /// `regionSeedTask` を起動するたびに 1 増やす実行識別子。`Task` は等価比較できないため、
    /// 「末尾で `regionSeedTask = nil` してよいのは自分がまだ現役の実行であるときだけ」を
    /// 判定するのに使う。`cancelRegionSeeding()` 直後に新しいシードが積まれてタスクが
    /// 張り替わったあと、cancel された古いタスクが遅れて `while` を抜けても、この
    /// トークンが食い違うため新しいタスクの参照を消さない
    /// （`MosaicEditorModel+RegionSeeding.swift` の `drainRegionSeedQueue` の doc 参照）。
    var regionSeedRunToken = 0
    /// シード走査専用の世代トークン。`timelineGeneration` を流用しないのは、
    /// シードが運ぶのが素材ID＋素材時刻でタイムライン編集しても意味が不変であり、
    /// 流用するとトリムのたびに正当な検出が捨てられてしまうため
    /// （`MosaicEditorModel+RegionSeeding.swift` の doc 参照）。
    var regionSeedGeneration = 0
    /// シード走査の進捗（0...1）。走査していないときは nil。UI のバッジ表示用
    /// （`objectTrackingProgress` と同じ役割）。「キューに積まれたシードのうち
    /// 何本目を処理しているか」で構わない（フレーム単位の細かい進捗は不要）。
    /// `cancelRegionSeeding()` でも nil に戻す。
    @Published var regionSeedProgress: Double?

    /// 暫定矩形マスク（マスク id 引き）ごとの被覆判定台帳。
    /// 第 3 段（`finalizeRegionPlaceholder`）が「シード走査が全部終わったか」
    /// 「ユーザーが手で矩形を動かした/変えたか」を判定するための唯一の入れ物
    /// （`MosaicEditorModel+RegionPlaceholder.swift` の `RegionPlaceholderLedger` doc 参照）。
    var regionPlaceholderLedgers: [UUID: RegionPlaceholderLedger] = [:]
    /// `regionPlaceholderLedgers` の挿入順（古い順）。`Dictionary` は挿入順を保証しないため、
    /// 上限を超えたときに「古いものから破棄」するための補助台帳。
    var regionPlaceholderLedgerOrder: [UUID] = []

    /// 旧下書き（`EditingDraft.legacyManualRects`）の移行待ち。
    ///
    /// v1 の動画下書きはクリップを持たないので、復元の時点では配り先の clipID が
    /// 決まっていない。`replaceTimeline` がクリップを立てた瞬間に
    /// `migratePendingManualRectsIfNeeded()` が全クリップへ配る。
    /// **`clips.isEmpty` だけを見て `.still` と判定してはいけない**（v1 動画下書きが
    /// 静止画マスクになり、どのクリップにも出なくなる）。
    var pendingLegacyManualRects: [CGRect] = []
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

    /// 出力 1 コマの長さ（秒。クリップ未構築なら nil）。コマ送りが 1 回で動く量。
    ///
    /// **UI はここを読むこと。`videoComposition?.frameDuration` を直接読んではならない**
    /// （`outputRenderSize` とまったく同じ理由。`videoComposition` は `@Published` では
    /// ないので更新が届かず、そもそも無装着構成では nil になる——そこで既定値 30fps へ
    /// 落ちると 60fps の素材でコマ送りが 2 コマぶん飛ぶ）。値の算出は
    /// `VideoCompositionFactory.frameDuration(for:)` の単一実装で、
    /// `TimelineCompositionBuilder.Built.outputFrameDuration` を経由して届く。
    /// 書き込みは `apply(built:generation:)` 一箇所だけ。
    @Published public internal(set) var outputFrameDuration: Double?

    /// 出力枠より大きく、縮小されて収まるクリップがあるか（UI の注意表示用）。
    /// 並べ替えで先頭クリップ＝出力解像度が変わると true / false が入れ替わる。
    @Published public internal(set) var hasDownscaledClips = false

    /// **合成の作り直しに時間がかかっているか**（プレビューの待ち表示用）。
    ///
    /// `isPreviewDecodeBusy` を使ってはいけない。あれは seek 一回・1 フレーム描画でも
    /// 立つので、スクラブ中は 30fps で点滅する（＝待ち表示としては使い物にならない）。
    /// ここは `rebuildComposition` の全体（build → replaceAsset → seek）だけを覆う。
    ///
    /// **すぐには立てない。** 分割・トリムのような普段の編集は一瞬で終わるため、
    /// 即座に立てるとインジケータが編集のたびに一瞬だけ光る。`rebuildIndicatorDelay`
    /// を超えて終わらなかったときだけ立てる（画面比率の変更や素材追加のように、
    /// 実際に待たされる操作だけが見える）。
    @Published public internal(set) var isRebuildingComposition = false

    /// 待ち表示を出すまでの猶予（秒）。これより早く終わる再構築では何も出さない。
    static let rebuildIndicatorDelay: Double = 0.4

    /// 進行中の `rebuildComposition` の本数（`isPreviewDecodeBusy` の深さと同じ流儀）。
    ///
    /// **1 本ずつの `defer` で立ち下げてはいけない。** `replaceTimeline` は古い
    /// 再構築を cancel せず新しいタスクを積むだけなので、古い方は build を最後まで
    /// 走り切ってから世代 guard で return する。連続編集すると
    /// 「新しい方がまだ再構築中なのに、古い方の後始末が待ち表示を消す」が起き、
    /// **最も待たされる場面でだけ表示が消える**（目的の真逆）。数で持てば、
    /// 最後の 1 本が終わったときだけ消える。
    private var rebuildDepth = 0
    /// 猶予待ちのタスク（先頭の 1 本が始めたものを共有する）。
    private var rebuildIndicatorTask: Task<Void, Never>?

    /// 再構築の開始を宣言する（`defer { endRebuild() }` と対で使う）。
    func beginRebuild() {
        rebuildDepth += 1
        guard rebuildDepth == 1 else { return }
        rebuildIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:
                UInt64(Self.rebuildIndicatorDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isRebuildingComposition = true
        }
    }

    /// 再構築の終了を宣言する。最後の 1 本が終わったときだけ待ち表示を消す。
    func endRebuild() {
        rebuildDepth = max(0, rebuildDepth - 1)
        guard rebuildDepth == 0 else { return }
        rebuildIndicatorTask?.cancel()
        rebuildIndicatorTask = nil
        isRebuildingComposition = false
    }

    /// テスト用: 立ち下げ漏れ（`begin` と `end` の非対称）を検出するための深さ。
    var rebuildDepthForTesting: Int { rebuildDepth }

    /// 現在のタイムラインに適用される書き出し制限（`ExportRestrictionPolicy.decide` の結果）。
    ///
    /// **「書き出しボタンを押せるか」（UI）と「実際に何が起きるか」（`exportVideo()`）は
    /// 必ずこの値を読むこと。** どちらも別々に判定関数を呼び直さない（呼び出しタイミングの
    /// ずれで両者が食い違う事故を防ぐため）。値は `apply(built:generation:)` 経由で
    /// タイムライン再構築のたびに更新される。
    @Published public internal(set) var exportRestriction: ExportRestriction = .none

    /// 課金権限の読み取り口（課金 P3b）。既定はアプリ唯一の注入点 `Entitlements.shared`。
    ///
    /// **`Entitlements.shared` をこのクラスの中から直接読まないこと。** 出力解像度の
    /// 上限（無料プランは短辺 1080px）は権限で変わるため、`Entitlements.shared` を
    /// 直接読むと**課金と無関係なテスト（解像度・並べ替え等）が権限の既定値に
    /// 引きずられて落ちる**（実際 `OutputResolutionTests` の 3 件がそうなった）。
    /// テストは Pro / 無料を明示して差し替えること。
    var entitlements: EntitlementProvider = Entitlements.shared

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

    /// 顔モザイクを掛けるか。
    ///
    /// **動画モードの初期値は false**（`init` で設定）。動画を開いただけで勝手に
    /// モザイクが乗ると、素材を確認したいだけの人が必ず一度外すことになる。
    /// 「モザイク」→「顔」を押した時点で初めて掛かる（`setEffectOn`）。
    /// 写真モードは 1 枚に対して即座に結果を見せる画面なので true のまま。
    @Published public var faceMosaicOn = true
    /// 手動矩形（物体モザイク）を掛けるか。**顔モザイクからは独立している。**
    ///
    /// 以前は `faceMosaicOn` に従属させていた（矩形は顔検出の補助、という位置づけ）。
    /// 顔を切ると矩形まで消えるため、「顔は検出に任せて、検出できない物だけ矩形で隠す」
    /// という使い方ができなかった。矩形は矩形として管理する。
    ///
    /// **既定は true。** 矩形はユーザーが描いたときにしか存在しないので、描いた直後に
    /// 何も起きない状態（既定 OFF）を作らない。切る導線は矩形の段のトグル
    /// （`toggleObjectMosaic`）にある。
    @Published public var objectMosaicOn = true
    @Published public var backgroundMosaicOn = false
    @Published public var faceBlockSize: Float = 28
    @Published public var backgroundBlockSize: Float = 28
    /// 写真モードの編集状態（色調補正。写真モード底上げ 第1段）。
    ///
    /// **書き換えは `applyPhotoEdit`（`MosaicEditorModel+Photo.swift`）からだけ行うこと。**
    /// 直接代入すると `renderPreview()` / `commitEdit()` が呼ばれず、スライダーを
    /// 動かしても絵が変わらない・undo に積まれない事故になる。
    /// 動画モードでは写真タブの UI が無いため常に `.identity` のまま（触られない）。
    @Published public var photoEdit: PhotoEditState = .identity
    /// プレビュー上で選択中の写真テキスト/ステッカーの ID（写真モード底上げ 第2段）。
    ///
    /// 動画モードの選択は `timelineSelection`（`TimelineLayerSelection`）が持つが、
    /// 写真は合成タイムラインを持たないためレイヤー選択の概念自体が無い。専用の
    /// 1 個の `UUID?` で足りる（写真は同時に 1 本しか選択できない設計。
    /// `TextOverlayEditView` の写真分岐参照）。
    @Published public var photoSelectedTextID: UUID?
    /// 選択中タブ（nil＝未選択：調整バーは非表示）。
    @Published public var activeTab: EffectTab? {
        didSet {
            // 顔タブを離れたら矩形ツールは必ず下ろす（モードが残っていると、
            // 別の作業をしている最中のプレビューのドラッグが矩形作成に化ける）。
            if activeTab != .face { isRectangleToolActive = false }
        }
    }

    /// 下部ツールバーがいま出している段（動画モードのみ）。
    ///
    /// **書き換えは `enterDock` / `dockBack` / `dockDone` からだけ行う**
    /// （`MosaicEditorModel+Dock.swift`）。直接代入すると、段と効果の ON/OFF・
    /// 矩形ツールの状態が食い違う。シーク・再生・クリップ選択では**変えない**
    /// （`EditorDockRoute` の doc 参照。段が勝手に閉じないことがこの UI の契約）。
    @Published public var dockRoute: EditorDockRoute = .root

    /// クロップ編集中の下書き。**nil＝クロップ編集していない。**
    ///
    /// `interactionMode`（`MosaicEditorModel+Crop.swift`）がこの nil 判定から
    /// `.crop` / `.normal` を導く唯一の情報源。書き換えは同ファイルの
    /// `beginCropEditing` / `updateCropDraft` / `cancelCropEditing` / `commitCropEditing`
    /// からだけ行うこと。
    @Published public var cropDraft: CropRect?
    /// クロップ編集中の比率固定。**編集中のみ意味を持つ**（`cropDraft == nil` の間は
    /// 無視される）。`beginCropEditing()` が毎回 `.free` へ戻す。
    @Published public var cropAspectLock: CropAspectLock = .free
    /// クロップ編集を始める前の `timeline.crop`。取消・確定の戻し先
    /// （`MosaicEditorModel+Crop.swift` の doc 参照）。
    var cropBeforeEditing: CropRect?

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

    /// 物体マスクの自動追跡が、ハードウェアデコーダを再生（`AVPlayer`）へ明け渡すべきか。
    ///
    /// 再生中にデコーダを奪い合うと、実機では数秒後から `copyCGImage` が nil を
    /// 返し続ける（プリスキャンで実測済みの事故）。ただし**書き出し中は譲らない**:
    /// `exportVideo` は追跡の完走を待ってから始めるので、ここで再生を理由に待つと
    /// 「待っている側が待たれている」状態になり、書き出しが永久に返ってこない。
    var shouldYieldTrackingDecoder: Bool { isPlaying && activeExporter == nil }

    /// 再生中なら止める。書き出しの前段で使う（`exportVideo` の doc 参照）。
    func pausePlaybackIfNeeded() {
        guard isPlaying else { return }
        previewController?.pause()
        isPlaying = false
    }
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

    /// 写真のテキスト・透かしラスタライズキャッシュ（写真モード底上げ 第2/3段）。
    ///
    /// **プレビュー用と分けない。** 動画側（`MosaicPreviewController.textOverlayCache`）は
    /// プレビューとエクスポートが別スレッド・別 `MosaicRenderer` で動くために分離が要るが、
    /// 写真は `renderer` を 1 個しか使わないので、この 1 個で足りる。
    ///
    /// `renderer` が nil（Metal デバイス無し）の環境では常に nil のまま
    /// （`TextOverlayCache.init` 自体は失敗しないが、紐づける `device` が無い）。
    private lazy var photoTextOverlayCache: TextOverlayCache? = {
        guard let renderer else { return nil }
        return TextOverlayCache(device: renderer.device)
    }()

    private var sourceImage: UIImage?
    /// テスト用フック（`internal`）: `detectInRegion` が検出入力として使うつもりの
    /// 素材内時刻（`resolveSourceLocation(atComposition:)` の結果）を最後に記録する。
    /// 実素材・MediaPipe なしでは `frameAtCompositionTime` のピクセル出力までは
    /// 検証できないため、「参照フレームが先頭フレーム固定になっていないか」を
    /// 確認する代理指標として `DetectionCacheSyncTests` から読む。
    private(set) var lastDetectInRegionReferenceSourceTime: Double?
    /// テスト用フック（`internal`）: `detectInRegion` が実際にクロップへ使った
    /// `materialRect`（素材フレーム基準・写真の向きを掛けた後の逆写像込み）を最後に記録する。
    /// 写真モードで検出が 0 件（実素材・MediaPipe なし）でも、`resolveRegion` 経由の
    /// `appendObjectMask` は**元の合成矩形**を渡すため（`materialRect` は検出専用でクロップ
    /// 後に捨てられる）、`objectMasks` の中身からは `materialRect` の計算結果を観測できない。
    /// 「回した写真でクロップ範囲が正しく逆写像されているか」を確認する代理指標として
    /// `PhotoOrientationWiringTests` から読む（`lastDetectInRegionReferenceSourceTime` と同じ流儀）。
    private(set) var lastDetectInRegionMaterialRectForTesting: CGRect?
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
            // v1 下書きの手動矩形は、クリップが立った**この瞬間**に全クリップへ配る
            // （復元の時点では配り先の clipID がまだ存在しない）。
            // **`replaceTimeline` ではなくここに置くこと**: 初回のタイムライン設置
            // （`installInitialTimeline`）は `timeline` へ直接代入しており
            // `replaceTimeline` を通らないため、そちらに掛けると復元経路で一度も
            // 発火しない（実測: 旧下書きのモザイクが 1 個も出なくなった）。
            migratePendingManualRectsIfNeeded()
            // クリップが立った／消えた／素材が入れ替わった直後に、物体マスクの
            // 自動追跡を張り直す。復元経路ではここが軌跡を作る唯一の起点になる
            // （軌跡は下書きに保存しないため。`ObjectTrack` の doc 参照）。
            scheduleObjectTracking()
            // 消えたクリップ・レイヤーを選択したまま残さない。**タイムラインを
            // 変える経路がここ 1 本しかない**ので、刈り込みもここに置けば漏れない
            // （View 側の `onChange` に置くと、画面が載っていない間の編集で漏れる）。
            timelineSelection.prune(against: timeline)
        }
    }
    /// タイムラインで選択中のクリップ／加工レイヤー。
    ///
    /// **View の `@State` ではなくモデルが持つ。** 下部ツールバーはタイムラインとは
    /// 別の段（画面最下部）にあり、両方が同じ選択を読む必要がある。
    /// 相互排他と刈り込みは `TimelineSelection`（MosaicCore の値型）が持つので、
    /// ここは置き場所を提供するだけ。
    @Published var timelineSelection = TimelineSelection()
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
    /// いま組んである `composition` に BGM（E2）が 1 曲でも載っているか。
    ///
    /// **書き出しへ必ず渡すこと**（`VideoMosaicExporter.export(hasBackgroundAudio:)`）。
    /// BGM がある構成を圧縮パススルーで書き出すと、音量も反映されず結果が
    /// 素材のフォーマット任せになる（`AudioExportPipeline` の doc 参照）。
    var hasBackgroundAudio = false
    /// Composition 再構築（`MosaicEditorModel+Timeline.swift` の `apply(built:generation:)`）
    /// が差し替える生のレイアウト。**この格納プロパティを直接読んではならない**
    /// （動画モードでは従来どおりだが、写真モードでは向きが載っていない）。
    /// 読み口は必ず計算プロパティ `renderLayout` を使うこと。
    var builtLayout: TimelineRenderLayout = .identity

    /// 素材フレーム基準の顔座標を合成フレーム基準へ写すレイアウト（S8）。
    /// 解像度混在（レターボックス）で効く。無変換構成では恒等。
    ///
    /// **写真モード底上げ 第4段で計算プロパティ化した。** 写真モードのときだけ
    /// `photoEdit.orientation` を `stillOrientation` へ注入する。格納 var のままだと
    /// `applyPhotoEdit` / `apply(snapshot:)`（undo）/ `load(image:)` の 3 箇所で
    /// 同期を取り忘れる余地があり、忘れると「向きだけ古いままモザイクが素通しになる」
    /// （写真の向きは合成タイムラインの再構築を経由しないため、格納にすると
    /// 更新イベントが無い）。計算にすれば発生し得ない。
    ///
    /// **`stillPlacement` には触らない。** 将来クロップが `builtLayout.stillPlacement` を
    /// 埋めたとき、ここで上書きすると写真のクロップが黙って消える。
    var renderLayout: TimelineRenderLayout {
        guard mode == .photo else { return builtLayout }
        var layout = builtLayout
        layout.stillOrientation = photoEdit.orientation   // 向きだけを注入する
        return layout
    }
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
    // アクセスレベル変更: 元は `private` だったが、途中から現れた人物の自動追加
    // （`MosaicEditorModel+PersonAdmission.swift`）が undo/redo スタックと履歴基準の
    // 全スナップショットへ新 ID を注入する必要があり、`internal`（無印）に緩めた。
    // 注入しないと、追加直後に undo を1回押しただけで新入りの選択が外れる
    // （＝顔が露出する）。
    @Published var undoStack: [EditSnapshot] = []
    @Published var redoStack: [EditSnapshot] = []
    var lastCommitted: EditSnapshot?

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
        // 動画は「開いてから決める」。写真は開いた時点で結果を見せる（上の doc 参照）。
        self.faceMosaicOn = mode == .photo
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
            $objectMosaicOn.map { _ in () }.eraseToAnyPublisher(),
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

        // 課金権限の変化（購入直後の Pro 解放など）を写真プレビューへ反映する
        // （課金 P2/P3b。動画側は `MosaicPreviewController+Rendering.swift` が
        // `Entitlements.shared.isPro` を毎フレーム直接読むため専用の購読が要らないが、
        // 写真は `renderPreview()` が明示的に再描画されない限り絵が更新されないため、
        // ここで変化を拾って再描画する）。
        entitlements.isProPublisher
            .removeDuplicates()
            .sink { [weak self] _ in self?.renderPreview() }
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
        objectMasks = []
        // 矩形が 1 個も無い状態へ戻すので、切ってあった ON/OFF も既定へ戻す
        // （前の素材で切ったまま持ち越すと、新しく描いた矩形が無言で出ない）。
        objectMosaicOn = true
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

        // 前の素材のシード走査が新しい素材の検出キャッシュへ書き込み続けないよう、
        // 素材を入れ替える経路の冒頭で打ち切る（世代ガードでも捨てられるが、
        // 打ち切らないと無駄なデコードが走り続ける）。
        cancelRegionSeeding()
        objectMasks = []
        // 矩形を捨てるので ON/OFF も既定へ（写真側と同じ理由）。
        objectMosaicOn = true
        // 素材が変わるので顔探しはやり直し（次に顔の段へ入ったときに走る）。
        didSeedFaces = false
        // 新しい素材を読み込むので顔は一旦空にする。**初期スキャンが非同期になった**
        // （下の Task）ため、ここで空にしないと「前の素材の顔が残ったまま復元が走る」
        // 窓ができる。スキャン結果はこの空の列へ**追記**される（`loadSeedFaces` の doc）。
        detectedFaces = []
        // 前の素材で積み上がった候補台帳を持ち越さない（別動画の候補が新しい素材の
        // sourceID に紛れ込むことはないが、TTL・命中履歴を素材ごとに独立させるため）。
        emergingPersonArbiter = EmergingPersonArbiter()

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
            // 先頭フレームは常に要る（プレビューに何も出ないと読み込み失敗に見える）。
            _ = loadFirstFrame(from: asset)
            // **顔探しは「掛けると決めてから」。** 動画モードの新規読み込みでは走らせない
            // （`seedFacesIfNeeded` が顔の段に入った時点で走らせる）。
            // 下書き復元は保存時の顔選択を結び直す必要があるので、ここで走らせる。
            if mode == .photo || pendingTimelineRestore != nil || faceMosaicOn {
                await loadSeedFaces(from: asset)
            } else {
                // 顔を出さないぶん、素材の絵だけは先に見せる
                // （`loadSeedFaces` の末尾がやっているのと同じ役割）。
                renderPreview()
            }
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
                // BGM は実効（合成尺で切ったもの）だけを渡す。音源未登録の曲は落とす
                // （`rebuildComposition` と同じ理由。同ファイルの doc 参照）。
                let audioItems = timeline
                    .effectiveAudioItems(totalDuration: TimelineMapping(clips: clips).totalDuration)
                    .filter { sources[$0.sourceID] != nil }
                let built = try await TimelineCompositionBuilder()
                    .build(clips: clips, transitions: timeline.transitions,
                           audioItems: audioItems, sources: sources,
                           aspectRatio: timeline.aspectRatio,
                           clipAudioMuteRanges: timeline.clipAudioMuteRanges,
                           crop: timeline.crop,
                           isPro: entitlements.isPro)
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
    /// 素材を開いた直後に必ず要るもの（先頭フレーム・テクスチャ・背景マスク）。
    ///
    /// **顔探しはここに含めない。** あちらは動画によっては数秒かかるうえ、
    /// 動画モードでは「モザイクを掛けると決めるまで」不要
    /// （`seedFacesIfNeeded` が段に入った時点で走らせる）。
    private func loadFirstFrame(from asset: AVAsset) -> UIImage? {
        guard let frame = Self.firstFrame(of: asset) else { return nil }
        sourceImage = frame
        sourceTexture = makeTexture(from: frame)
        updateBackgroundMask(from: frame)
        return frame
    }

    /// まだなら顔探しを走らせる。**2 度は走らせない。**
    ///
    /// 動画を開いた時点では走らせず、「モザイク」→「顔」に入った時点で初めて走る。
    /// 素材を確認したいだけの人に、掛ける前提の待ち時間を負わせないため。
    /// 写真モードと下書き復元は開いた時点で必要なので `load` から直接呼ぶ。
    func seedFacesIfNeeded() async {
        guard !didSeedFaces, let asset = videoAsset else { return }
        didSeedFaces = true
        await loadSeedFaces(from: asset)
    }

    private func loadSeedFaces(from asset: AVAsset) async {
        let existing = sourceImage ?? loadFirstFrame(from: asset)
        guard let frame = existing else { return }
        didSeedFaces = true

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
            // **適用区間は作らない（レイヤーは空で始める）。**
            //
            // 以前はここで全域の区間を 1 本自動生成しており、動画を開いただけで
            // タイムラインにモザイクのレイヤーが 1 本乗っている状態だった。
            // 効果を何も足していないのにレイヤーがあるのは編集アプリの流儀に反する
            // （ユーザー報告「新規編集でモザイクをレイヤーに出さないで」）。
            //
            // 区間 0 本 = 全区間 OFF なので、このままでは何も掛からない。**掛ける
            // 操作の入口が `ensureApplyRangesExist()` で区間を作る**（顔モザイクを ON、
            // 矩形を置く、等。`MosaicEditorModel+Dock` / `+ObjectMask` の呼び出し）。
            // 「効果を足した瞬間にレイヤーが現れる」が新しい契約で、
            // 顔探しを「掛けると決めてから」に寄せた読み込み手順とも揃う。
            //
            // restore 分岐では**何もしない**: 旧データの変換は `TimelineState.init(from:)` で
            // 完了済みであり、ここで再生成すると「意図的に全削除した下書き」が復活する。
            let clip = TimelineClip(sourceID: currentSourceID, sourceStart: 0, sourceEnd: seconds)
            // 初期クリップは常に動画素材（写真モードはこの経路を通らない）。
            timeline = TimelineState(clips: [clip], applyRanges: [])
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
        // `displayFaces` と同じ規律: clipID・素材ID・素材時刻を**1 回だけ**解決し、
        // 座標写像（下）と顔の帰属先（`mergeDetection` / `FaceTarget.sourceID`）の
        // 両方に使い回す。別々に解決すると境界フレームで clipID と実際に切り出した
        // 矩形の素材が食い違いうる。写真は素材の概念が無いので nil のまま。
        let compTime: Double? = mode == .video ? compositionTime(forPosition: playbackPosition) : nil
        let resolvedLocation: ResolvedSourceLocation? = compTime.map { resolveSourceLocation(atComposition: $0) }

        // 動画モードの検出入力は**現在の再生位置のフレーム**にする。`sourceImage` は
        // 写真読み込み・`loadFirstFrame`（動画の**先頭フレーム**）・`redetect` でしか
        // 更新されず、`seekTo`（スクラブ）は `sourceTexture` と背景マスクしか更新しない。
        // そのため動画をスクラブしてから矩形サーチすると、古い（先頭）フレームを
        // クロップ・検出してしまい、見つかった顔の座標が現在時刻のバケットへ
        // `mergeDetection` 経由で誤って書き込まれる（位置の違う顔のキャッシュ混入）。
        // 写真モードは `sourceImage` が常に現在の絵なのでそのまま使う。
        // `frameAtCompositionTime` は同期で数十〜数百ms かかりうるが、MainActor 隔離の
        // 通常メソッドなので `Task.detached` へ無理に逃がさず素直に await 前提で呼ぶ
        // （detectInRegion は既に async。detached へ出すと MainActor 専有の他の状態
        // 読み書きと競合しうるため、素直な呼び出しを優先した）。
        let frame: UIImage?
        if let compTime {
            // テスト用フック（`internal`）: ここで実際に `frameAtCompositionTime` へ
            // 渡した素材内時刻を記録する。実素材なしでは戻り値のピクセルまでは
            // 検証できないため、「先頭フレーム固定に戻っていないか」を確認する
            // 代理指標として使う。フレーム選択と同じ分岐に置くことで、この分岐
            // ごと削って `sourceImage` 直読みへ戻す退行を検出できるようにしてある。
            lastDetectInRegionReferenceSourceTime = resolvedLocation?.time
            frame = frameAtCompositionTime(compTime) ?? sourceImage
        } else {
            lastDetectInRegionReferenceSourceTime = nil
            frame = sourceImage
        }

        guard let img = frame, let cgImage = img.cgImage else {
            await resolveRegion(normalizedRect, referenceImage: frame)
            return
        }

        // `normalizedRect` は**合成フレーム**基準の正規化矩形だが、`sourceImage`（＝
        // `cgImage`）は**素材フレーム**基準。レターボックス・解像度違いのあるクリップでは
        // 無変換のまま素材へ当てるとクロップ位置が確定的にずれる
        // （`resolveRegion` 側は `scanSegments(searchRect:)` で同じ逆写像を掛けており、
        // ここだけ無変換だと 2 つの座標規約が混在していた＝今回のバグの本体）。
        // `inverseRemap` が nil（クリップ未構築・矩形が黒帯の中）のときは、恒等写像下
        // では素通しと同値なので `normalizedRect` をそのまま使う。
        let materialRect: CGRect
        if let clipID = resolvedLocation?.clipID,
           let inversed = renderLayout.inverseRemap(normalizedRect, clipID: clipID) {
            materialRect = inversed
        } else if mode == .photo {
            // 写真は素材の概念が無いので `resolvedLocation` は常に nil（この関数冒頭の
            // 分岐参照）——だが写真にも向き（`renderLayout.stillOrientation`）はあるので、
            // ここを無写像のまま `normalizedRect` を使うと、回した写真でクロップ位置が
            // ずれる（`scanSegments(searchRect:)` / `resolveRegion` 側が同じ逆写像を
            // 掛けているかを必ず突き合わせること。ここだけ無変換だと 2 つの座標規約が
            // 混在する＝バグの本体）。写像不能（潰れた配置）なら `normalizedRect` を
            // そのまま使う（恒等下では同値）。
            materialRect = renderLayout.inverseRemapStill(normalizedRect) ?? normalizedRect
        } else {
            materialRect = normalizedRect
        }
        lastDetectInRegionMaterialRectForTesting = materialRect

        let pixW = CGFloat(cgImage.width)
        let pixH = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: materialRect.origin.x * pixW,
            y: materialRect.origin.y * pixH,
            width: materialRect.width * pixW,
            height: materialRect.height * pixH
        )

        guard let cropped = cgImage.cropping(to: pixelRect) else {
            await resolveRegion(normalizedRect, referenceImage: img)
            return
        }

        let croppedImage = UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let found = scanner.allLandmarks(in: croppedImage)

        if !found.isEmpty {
            let faceSourceID = resolvedLocation?.sourceID
            let referenceTime = resolvedLocation?.time ?? 0
            let remappedLandmarks = found.map { $0.remapped(into: materialRect) }
            // 同定（人物の取り違え防止）: `detectedFaces` へ載せる前に呼ぶ
            // （第2段でここを塞いだ穴。第1段はこの呼び出しが無く、範囲サーチで
            // 見つけた顔が常に personID なしになっていた）。
            let personIDs = faceSourceID.map {
                seedPersonIDs(for: remappedLandmarks, in: img, sourceID: $0, time: referenceTime)
            } ?? [UUID?](repeating: nil, count: remappedLandmarks.count)
            let newFaces = zip(remappedLandmarks, personIDs).map { remapped, personID -> FaceTarget in
                // クロップ内座標(0-1)から素材フレーム全体座標へ戻すので、クロップに
                // 使ったのと**同じ** `materialRect` を渡す（`normalizedRect` のままだと
                // 合成フレーム基準に戻ってしまい、他の detectedFaces と座標系が割れる）。
                let thumb = generateThumbnail(for: remapped, from: img)
                // ユーザーが矩形を描いた意図は「この顔にモザイクを掛けたい」なので
                // 即選択する（false だとサムネをもう一度タップするまで何も起きない）。
                return FaceTarget(id: UUID(), landmarks: remapped, thumbnail: thumb,
                                  isSelected: true, sourceID: faceSourceID, personID: personID)
            }
            detectedFaces += newFaces
            // 見つけた顔を検出キャッシュへも記録する。`detectedFaces` は絞り込みの
            // 照合にしか使われず、実際の描画（`displayFaces` → `lookupFaces`）は
            // 検出キャッシュしか見ないため、ここを省くと矩形内で顔が見つかっても
            // 画面にもエクスポートにもモザイクが乗らない（今回の不具合の本体）。
            mergeDetection(newFaces.map { $0.landmarks }, sourceID: faceSourceID,
                           sourceTime: referenceTime)
            // 第 1 段（「まず矩形で確実に隠す」）: 顔が見つかった場合もここで矩形マスクを
            // 必ず置く。顔追跡（`FaceTarget`／検出キャッシュ）は瞬き・追跡ロス・第2段
            // 未実装の理由でモザイクが途切れうるが、矩形はユーザーが描いた範囲を
            // 無条件に隠し続けるため、露出をゼロにする最終防波堤になる。
            // 見つからない分岐は `resolveRegion` 側が自分で（かつ 1 回だけ）置くので、
            // ここでは「見つかった」ときだけ置く（二重に置かない）。
            let maskID = appendObjectMask(compositionRect: normalizedRect)
            // 第2段: 見つけた顔をシードに、素材の前後方向へ検出キャッシュを埋める走査を
            // 起動する（`MosaicEditorModel+RegionSeeding.swift`）。クリップが解決できない
            // （`resolvedLocation?.clipID` が nil＝クリップ未構築・写像不能）ときは
            // シードの `sourceRange` を確定できないため走査しない。
            if let faceSourceID, let clipID = resolvedLocation?.clipID,
               let clip = clips.first(where: { $0.id == clipID }),
               let asset = sources[faceSourceID], clip.sourceEnd > clip.sourceStart {
                for face in newFaces {
                    enqueueRegionSeed(RegionSeed(
                        sourceID: faceSourceID, asset: asset,
                        sourceRange: clip.sourceStart...clip.sourceEnd, clipID: clipID,
                        seedTime: referenceTime, seedLandmarks: face.landmarks,
                        targetID: face.id, personID: face.personID, maskID: maskID))
                }
            }
        } else {
            // 現在フレームで検出できなければ動画全体をサーチ（矩形マスクは
            // `resolveRegion` が自分の中で置く）。
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
        /// この走査区間が属するクリップの識別子。`range` と対で nil/非 nil が揃う
        /// （クリップが解決できているときだけ両方 non-nil）。第2段のシード
        /// （`RegionSeed.clipID`、非オプショナル）を作れるのはこの値があるときだけ。
        let clipID: UUID?
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
        /// 実際にフレームをコピーできた**素材内時刻**（1fps サーチの要求時刻ではない。
        /// `findFaceInVideo` の doc 参照）。検出キャッシュへ記録するバケットはこの
        /// 実測時刻で決めないと、要求時刻と食い違って `lookupFaces` が引けないバケットに
        /// 書いてしまう。
        let time: Double
        let asset: AVAsset
        /// ヒットした素材の走査区間（`RegionScanSegment.range` そのまま）。nil はクリップ
        /// 未構築（素材全体走査）で、第2段のシード走査は `sourceRange` を確定できないため
        /// 走査しない（`resolveRegion` の doc 参照）。
        let range: ClosedRange<Double>?
        /// ヒットした素材のクリップ識別子（`RegionScanSegment.clipID` そのまま）。
        /// `range` と同様、nil はクリップ未構築で第2段のシードを作らない。
        let clipID: UUID?
    }

    /// `findFaceInVideo` 1 回のサンプリングが顔を見つけたときの結果
    /// （`RegionScanHit` になる前の、素材ID未添付の生の戻り値）。
    /// タプルではなく型にしたのは SwiftLint の `large_tuple`（3 要素超）対策と、
    /// 各要素の意味（特に `time` が要求時刻ではなく実測時刻であること）を
    /// 呼び出し側で読み違えないようにするため。
    private struct FrameScanHit {
        let landmarks: FaceLandmarkSet
        let frame: UIImage
        /// 実際にフレームをコピーできた**実測時刻**（要求時刻ではない）。
        let time: Double
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
            appendObjectMask(compositionRect: rect)
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
                if let hit = await Self.findFaceInVideo(
                    asset: segment.asset, rect: segment.rect,
                    scanner: scanner, scanRange: segment.range) {
                    return RegionScanHit(landmarks: hit.landmarks, frame: hit.frame,
                                         sourceID: segment.sourceID, time: hit.time,
                                         asset: segment.asset, range: segment.range,
                                         clipID: segment.clipID)
                }
            }
            return nil
        }.value
        isScanning = false

        // 第2段のシードは `appendObjectMask` の戻り値（マスク id）を必要とするが、
        // その呼び出しは（見つかった・見つからなかったに関わらず矩形を隠すという
        // 設計上の理由で）この関数の末尾に 1 箇所しか無い。そのためここでは
        // シードに必要な値だけを `RegionSeed`（`maskID: nil`）へローカルに溜め、
        // 末尾で得た `maskID` を載せた新しい `RegionSeed` を作ってから
        // `enqueueRegionSeed` する（`appendObjectMask` を呼ぶ位置そのものは動かさない）。
        var pendingSeed: RegionSeed?

        if let hit = result {
            let thumbSource = referenceImage ?? hit.frame
            let thumb = generateThumbnail(for: hit.landmarks, from: thumbSource)
            // 同定（人物の取り違え防止）: `detectedFaces` へ載せる前に呼ぶ
            // （第2段でここを塞いだ穴。第1段はこの呼び出しが無く、範囲サーチで
            // 見つけた顔が常に personID なしになっていた）。
            let personID = seedPersonIDs(for: [hit.landmarks], in: hit.frame,
                                         sourceID: hit.sourceID, time: hit.time).first ?? nil
            let targetID = UUID()
            // 矩形を描いた意図に合わせて即選択（上の resolveRegion 直検出と同じ理由）。
            detectedFaces.append(FaceTarget(id: targetID, landmarks: hit.landmarks, thumbnail: thumb,
                                            isSelected: true, sourceID: hit.sourceID, personID: personID))
            // ヒットした**実測時刻**（`hit.time`）で検出キャッシュへ記録する。要求時刻
            // （1fps サーチの `t`）ではない: `findFaceInVideo` は
            // `requestedTimeTolerance` を許しているため実際にコピーできたフレームは
            // 要求時刻からずれることがあり、要求時刻で書くと `lookupFaces` が引く
            // バケットと食い違って永遠にキャッシュヒットしない。
            // また `hit.time` は `findFaceInVideo` の `scanRange`（素材時刻の区間）を
            // そのまま使ったサンプリングの結果なので**既に素材時刻**であり、
            // `resolveSourceTime` 等の合成→素材写像を重ねて掛けてはいけない
            // （掛けると二重写像でバケットがずれる）。
            mergeDetection([hit.landmarks], sourceID: hit.sourceID, sourceTime: hit.time)
            // 第2段: 見つけた顔をシードに、素材の前後方向へ検出キャッシュを埋める走査を
            // 起動する（`MosaicEditorModel+RegionSeeding.swift`）。`hit.range` / `hit.clipID`
            // が nil（クリップ未構築・素材全体走査）のときは `sourceRange` / `clipID` を
            // 確定できないため走査しない（`RegionSeed.clipID` は非オプショナル）。
            if let range = hit.range, let clipID = hit.clipID {
                pendingSeed = RegionSeed(sourceID: hit.sourceID, asset: hit.asset, sourceRange: range,
                                         clipID: clipID,
                                         seedTime: hit.time, seedLandmarks: hit.landmarks,
                                         targetID: targetID, personID: personID)
            }
        }
        // 見つかった・見つからなかったに関わらず、囲った範囲は必ずすぐに隠す
        // （「まず矩形で確実に隠す」という設計決定の前半。矩形マスクは第2段で
        // 顔追跡へ差し替える予定なので `isRegionPlaceholder` を立てて後から
        // 判別できるようにしてある）。この関数の中で `appendObjectMask` を
        // 呼ぶのはここ 1 箇所だけ（上の非動画ガードにある呼び出しは
        // この行へ到達する前に return するので二重には呼ばれない）。
        let maskID = appendObjectMask(compositionRect: rect)
        if let pendingSeed {
            enqueueRegionSeed(RegionSeed(
                sourceID: pendingSeed.sourceID, asset: pendingSeed.asset,
                sourceRange: pendingSeed.sourceRange, clipID: pendingSeed.clipID,
                seedTime: pendingSeed.seedTime,
                seedLandmarks: pendingSeed.seedLandmarks, targetID: pendingSeed.targetID,
                personID: pendingSeed.personID, maskID: maskID))
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
            return [RegionScanSegment(asset: asset, range: nil, sourceID: currentSourceID,
                                      clipID: nil, rect: rect)]
        }
        return clips.compactMap { clip in
            guard let asset = sources[clip.sourceID], clip.sourceEnd > clip.sourceStart else { return nil }
            guard let sourceRect = renderLayout.inverseRemap(rect, clipID: clip.id) else { return nil }
            return RegionScanSegment(asset: asset,
                                     range: clip.sourceStart...clip.sourceEnd,
                                     sourceID: clip.sourceID,
                                     clipID: clip.id,
                                     rect: sourceRect)
        }
    }

    /// 素材の指定区間（nil なら全体）を1fpsでサンプリングし、矩形クロップ内で顔を探す。
    /// 最初の検出結果を返す。
    ///
    /// `rect` は**素材フレーム基準**（`scanSegments(searchRect:)` が逆写像済み）。
    /// 返すランドマークも `remapped(into: rect)` で素材フレーム基準へ戻したものになる。
    /// 併せて返す時刻は**実測時刻**（`copyCGImage(at:actualTime:)` が返す実際に
    /// コピーできたフレームの時刻。要求時刻 `t` ではない。`requestedTimeTolerance`
    /// を許しているため両者はずれうる。呼び出し側が検出キャッシュへ書くときは
    /// 必ずこちらを使うこと）。
    nonisolated private static func findFaceInVideo(
        asset: AVAsset,
        rect: CGRect,
        scanner: FaceLandmarking,
        scanRange: ClosedRange<Double>? = nil
    ) async -> FrameScanHit? {
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
            var actualTime = CMTime.zero
            if let cg = try? generator.copyCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600), actualTime: &actualTime) {
                let pixelRect = CGRect(
                    x: rect.origin.x * CGFloat(cg.width),
                    y: rect.origin.y * CGFloat(cg.height),
                    width: rect.width  * CGFloat(cg.width),
                    height: rect.height * CGFloat(cg.height)
                )
                if let crop = cg.cropping(to: pixelRect) {
                    let faces = scanner.allLandmarks(in: UIImage(cgImage: crop))
                    if let first = faces.first {
                        return FrameScanHit(landmarks: first.remapped(into: rect),
                                           frame: UIImage(cgImage: cg), time: actualTime.seconds)
                    }
                }
            }
            t += 1.0
        }
        return nil
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

    // MARK: - 手動再検出（撤去済み）
    //
    // かつてここに `redetect(at:)` / `replaceDetectedFaces(_:ofSource:)` /
    // `carryingOverSelection(_:previousSelected:)` があった（「再検出」ボタンの実体）。
    //
    // **復活させないこと。** この経路は「その素材の顔一覧を作り直す」もので、
    // 作り直しのたびに `FaceTarget.id` が変わり、選択は重心 0.5 のマッチで
    // 引き継ぐしかなかった。人物同定（`personID`）を入れた今は、
    // 位置で選択を引き継ぐ判定そのものが人物の取り違えを生む側になる。
    //
    // 「途中から出てきた人が顔一覧に無い」という本来の用途は
    // `MosaicEditorModel+PersonAdmission` の自動追加が満たす。あちらは
    // **既存の顔を一切作り直さない**（末尾に追記するだけ）ので、
    // 既に選んである人の選択も ID も動かない。

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
        guard let renderer, let tex = sourceTexture, let cache = photoTextOverlayCache else { return }
        applyControls(to: renderer)

        // 顔モザイク（立体メッシュ）＋手動矩形。
        // **両者は独立して ON/OFF する。** 顔を切っても矩形は残る（逆も同じ）。
        //
        // `landmarks` は**素材フレーム基準のまま**渡す（`PhotoRenderPipeline.render` が
        // 内部で `layout.remapStill` を 1 回だけ掛ける。`MosaicInput` の doc 参照）。
        let landmarks = faceMosaicOn ? detectedFaces.filter(\.isSelected).map(\.landmarks) : []
        // `extra`（物体マスク）は `objectMaskPaths` の内部で `renderLayout.remapStill` 済み
        // （`ObjectMaskResolver.placements` 経由）なので、焼き込み先のピクセルサイズは
        // **写真の向きを掛けた後**の出力サイズでなければならない
        // （`PhotoRenderPipeline` の回転段が先頭に来るため、モザイクはすでに
        // 回転後のフレームへ描かれる）。
        let renderedSize = renderLayout.stillOrientation.displaySize(
            CGSize(width: tex.width, height: tex.height))
        let extra = objectMosaicOn
            ? objectMaskPaths(for: renderedSize, atComposition: compositionTimeForOverlay)
            : []

        // 色調補正・モザイク・テキスト・透かしの合成は `PhotoRenderPipeline` の
        // 1 呼び出しに閉じる（写真専用の合成器を新設しない。動画モードでは `photoEdit` が
        // 常に `.identity` なので色調補正・テキストのパスはゼロコストで素通りし、
        // 従来と同じ絵になる）。
        //
        // **`needsWatermark` の判定源はここだけ。** `entitlements.isPro` を直接見る
        // （`Entitlements.shared` を `MosaicEditorModel` の中から直接読まない、という
        // `entitlements` プロパティの doc に従う）。動画プレビュー
        // （`MosaicPreviewController+Rendering.swift`）と判定の根拠（Pro かどうか）は
        // 同じだが、読み口はこのクラスの規約どおり注入されたプロパティを使う。
        let current = PhotoRenderPipeline.render(
            source: tex,
            photoEdit: photoEdit,
            renderer: renderer,
            layout: renderLayout,
            mosaic: PhotoRenderPipeline.MosaicInput(
                landmarkSets: landmarks,
                additionalPaths: extra,
                backgroundMask: backgroundMosaicOn ? backgroundMask : nil,
                backgroundBlockSize: backgroundBlockSize
            ),
            overlay: PhotoRenderPipeline.OverlayInput(cache: cache, needsWatermark: !entitlements.isPro)
        )

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
    /// 動画の途中から現れた人物を自動で顔一覧へ足すかどうかの判定器（純ロジックは
    /// `MosaicCore.EmergingPersonArbiter`）。`load(videoURL:)` で `detectedFaces` と
    /// 同じタイミングでリセットする（別動画の候補台帳を持ち越さないため）。
    var emergingPersonArbiter = EmergingPersonArbiter()

    // MARK: - 下書き（状態保持・再開）

    /// 写真下書き保存用の元画像（向き補正済み）。
    public var photoSourceImage: UIImage? { sourceImage }

    /// 下書きへ保存する物体マスク。
    public var draftObjectMasks: [ObjectMask] { objectMasks }

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

    /// 顔探し（初期スキャン）を走らせたか。
    ///
    /// **動画を開いただけでは走らせない**ので、「モザイク」→「顔」に入った時点で
    /// 一度だけ走らせるための目印（`seedFacesIfNeeded`）。素材を差し替える
    /// `load(videoURL:)` で false に戻す。
    var didSeedFaces = false

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
        // **BGM の音源も下書きへ持っていく（E2）。**
        //
        // ここを漏らすと、下書きを再開したときに帯だけ残って音源が `sources` に無く、
        // **BGM が黙って鳴らなくなる**（`rebuildComposition` が音源未登録の曲を落とす）。
        // クリップと違い `timeline.clips` からは辿れないので、別のループが要る。
        for item in timeline.audioItems where !seen.contains(item.sourceID) {
            seen.insert(item.sourceID)
            guard let url = (sources[item.sourceID] as? AVURLAsset)?.url else { continue }
            result.append((item.sourceID, url))
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
    /// **BGM の音源も同じ保護に含める（E2）。** 含めないと「BGM を消して再保存 →
    /// undo で戻す」で音源の実体だけが GC で消え、帯はあるのに鳴らない状態になる。
    var sessionReferencedSourceIDs: Set<UUID> {
        func ids(of state: TimelineState) -> Set<UUID> {
            Set(state.clips.map(\.sourceID)).union(state.audioItems.map(\.sourceID))
        }
        var result = ids(of: timeline)
        for snap in undoStack { result.formUnion(ids(of: snap.timeline)) }
        for snap in redoStack { result.formUnion(ids(of: snap.timeline)) }
        if let last = lastCommitted { result.formUnion(ids(of: last.timeline)) }
        return result
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
        /// 矩形の ON/OFF。この項目より前に保存された下書きには無いので、
        /// 既定は true（＝矩形が保存されていれば従来どおり掛かる）。
        objectMosaicOn: Bool = true,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        objectMasks: [ObjectMask],
        legacyManualRects: [CGRect] = [],
        faceSelections: [DraftFaceSelection]? = nil,
        personProfiles: [PersonProfile]? = nil,
        /// 写真モードの編集状態（色調補正）。この項目より前の下書きには無いので、
        /// 既定は `.identity`（＝復元前と同じ「無編集」の見た目のまま）。
        photoEdit: PhotoEditState = .identity
    ) {
        // 人物は**目印より先に**台帳へ戻す。目印は人物 ID で顔を指しており、
        // 台帳に居ない人物 ID はどの顔とも結び付かない（＝位置照合へ落ちる）。
        // ここで戻しておけば、この後の初期スキャン・ライブ検出が署名から
        // 同じ人物 ID を復元し、保留していた目印もそのまま結び直せる。
        if let personProfiles {
            personRegistry.merge(personProfiles)
        }
        self.faceMosaicOn = faceMosaicOn
        self.objectMosaicOn = objectMosaicOn
        self.backgroundMosaicOn = backgroundMosaicOn
        self.faceBlockSize = faceBlockSize
        self.backgroundBlockSize = backgroundBlockSize
        self.objectMasks = objectMasks
        // 写真の色調補正も他のパラメータと同じ扱い: **直接代入**（`applyPhotoEdit` は
        // 通さない）。復元は編集ではないので `commitEdit()` を呼ばず、末尾の
        // `resetHistory()` が復元後の状態をそのまま履歴の起点にする
        // （`faceMosaicOn` 等、この関数の他のフィールドと同じ流儀）。
        self.photoEdit = photoEdit
        migrateLegacyManualRects(legacyManualRects)
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
            objectMosaicOn: objectMosaicOn,
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            selectedFaceIDs: Set(detectedFaces.filter(\.isSelected).map(\.id)),
            objectMasks: objectMasks,
            trimRange: trimRange,
            timeline: timeline,
            photoEdit: photoEdit
        )
    }

    private func apply(_ snap: EditSnapshot) {
        // undo/redo でタイムラインが差し替わるので、差し替え前のタイムラインを
        // 前提にしたシード走査（素材ID＋素材時刻）を打ち切る。世代ガードで
        // 書き戻しは捨てられるが、打ち切らないと無駄なデコードが走り続ける。
        cancelRegionSeeding()
        faceMosaicOn = snap.faceMosaicOn
        objectMosaicOn = snap.objectMosaicOn
        backgroundMosaicOn = snap.backgroundMosaicOn
        faceBlockSize = snap.faceBlockSize
        backgroundBlockSize = snap.backgroundBlockSize
        for index in detectedFaces.indices {
            detectedFaces[index].isSelected = snap.selectedFaceIDs.contains(detectedFaces[index].id)
        }
        objectMasks = snap.objectMasks
        trimRange = snap.trimRange
        photoEdit = snap.photoEdit
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
        // **`croppedPreviewImage`（＝クロップを掛けた previewImage）を経由する。**
        // 表示（`EditorView+Preview.swift`）と保存はここを共有源にすることで、
        // 「表示だけ切れて保存は全面」の食い違いが構造的に起きない
        // （`MosaicEditorModel+Crop.swift` の doc 参照）。
        guard let previewImageToSave = croppedPreviewImage else { return }
        do {
            try await PhotosSaver.save(image: previewImageToSave)
            recents.add(kind: .photo, thumbnail: previewImageToSave)
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
        // 無料プランの尺制限。**UI（書き出しボタンの活性表示）と同じ `exportRestriction`
        // を読む**（判定関数をここで別途呼び直さない。二重判定は呼び出しタイミングの
        // ずれで食い違う）。解像度超過（`.exceedsResolution`）は止めない
        // （`TimelineCompositionBuilder.build` が既に縮小した `videoComposition` /
        // `outputSize` を組んでいるので、ここでは何もしなくてよい）。
        if let restrictionMessage = durationRestrictionMessage {
            errorMessage = restrictionMessage
            return
        }
        guard let renderer else { return }
        // 書き出しは原寸のまま tmp へ書く。書き終わってから容量不足で失敗するより、
        // 開始前に見積もりと空き容量を比べて弾く（判断は core の純関数）。
        if let shortage = await storageShortageMessage(for: composition) {
            errorMessage = shortage
            return
        }
        // 再生を止めてから追跡を待つ。**この順序を崩さないこと**: 追跡は再生中
        // ハードウェアデコーダを明け渡して待つ設計なので、再生したまま待つと
        // 「書き出しが追跡を待ち、追跡が再生の終了を待つ」で永久に止まる。
        pausePlaybackIfNeeded()
        // 走行中の自動追跡を待つ。待たないと「プレビューは追跡位置・書き出しは
        // キーフレーム補間」という食い違いが出る（軌跡は下書きに保存しないため、
        // 復元直後の書き出しでこれが起きやすい）。
        await awaitObjectTracking()
        // 走行中のシード走査を待つ。エクスポートは `DetectionBridge(interpolates: true)`
        // だけでプレビューの近傍ホールドが無いため、走査の途中で書き出すと
        // キャッシュが穴だらけのまま焼き込まれる。
        await awaitRegionSeeding()
        await runExport(composition: composition, renderer: renderer)
    }

    /// `exportVideo()` の後半（exporter の生成〜書き出し〜保存〜後始末）だけを担う。
    /// 複雑度・行数を抑えるための切り出しで、判断（ガード・制限判定）は呼び出し側に残す。
    private func runExport(composition: AVAsset, renderer: MosaicRenderer) async {
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
                objectMasks: objectMasks,
                objectTracks: objectTracks,
                detectionCaches: detectionCaches,
                mapping: mapping,
                // 写真素材の素材時刻は exporter 側でも 0 に clamp する
                // （t=0 seed に全フレームがヒットし、写真区間で実検出が走らない）。
                photoSourceIDs: timeline.photoSourceIDs,
                // モザイク適用区間（S10）。素材時刻アンカーのまま渡し、exporter が
                // フレームの合成時刻を写像してからゲート判定する（プレビューと同じ
                // `MosaicApplyGate` の純関数を通すので境界フレームの結果が一致する）。
                applyRanges: timeline.applyRanges,
                // 画面に置く文字（E3）。プレビューと同じ `timeline.textItems` を渡す。
                textItems: timeline.textItems,
                // クリップごとの色調補正（P4）。プレビューと同じ `TimelineClip.colorGrade`
                // を渡す（`colorGrade(atComposition:)` と同じ手順で exporter 側が
                // 重なりブレンドする。`VideoMosaicExporter.colorGrades` の doc 参照）。
                colorGrades: Dictionary(uniqueKeysWithValues: timeline.clips.map { ($0.id, $0.colorGrade) }),
                // 無料プランの透かし（課金 P2）。**`isPro` を直接見ない**。UI と同じ
                // `exportRestriction`（`.exceedsResolution` でも真になる導出プロパティ）
                // を読み、判定の根拠を 2 箇所に散らばらせない。
                needsWatermark: exportRestriction.needsWatermark,
                // 合成（トランジション・レターボックス・フレームレート上限）と
                // 音声ミックスはプレビューと同じものを渡す。composition と必ず組で
                // 差し替わる（`apply(built:generation:)`）ので世代がずれない。
                videoComposition: videoComposition,
                audioMix: audioMix,
                hasBackgroundAudio: hasBackgroundAudio,
                renderLayout: renderLayout,
                faceEnabled: faceMosaicOn,
                objectEnabled: objectMosaicOn,
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

    /// 無料プランの尺超過で書き出しを止めるべきときのユーザー向け文言（それ以外は nil）。
    ///
    /// `exportRestriction` を読むだけの純粋な変換（判定そのものは
    /// `ExportRestrictionPolicy.decide` の 1 箇所だけで行う）。`.exceedsResolution` /
    /// `.watermarkOnly` / `.none` は書き出しを止めないので nil。
    private var durationRestrictionMessage: String? {
        guard case .exceedsDuration(let limit) = exportRestriction else { return nil }
        return "無料プランで書き出せる長さは\(Int(limit))秒までです。"
            + "Proにアップグレードすると制限なく書き出せます。"
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
    ///
    /// `MosaicEditorModel+Dock.swift`（背景モザイクを ON にする経路）から呼ぶため internal。
    func recomputeBackgroundMask() {
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
        // **自前で足し合わせないこと。** 同じ式が `SelectedFaceTracker.centroid` にもあり、
        // 片方だけ直すと描画の絞り込みとタップ選択が違う顔を指す。
        FaceCentroidMatching.centroid(of: landmarks)
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
    /// 2. ここで取り出したフレームを検出に掛ける経路は `storePreScanResult` で
    ///    **素材キー**に書き込む。合成フレームで検出すると座標系の違う結果が正規の検出として
    ///    キャッシュへ入り、エクスポート（キャッシュヒットで検出をスキップ）まで汚染される。
    ///    （かつての「再検出」ボタンがこの形だった。撤去済みだが、この関数の戻り値を
    ///    検出に回す実装を足すなら同じ制約が掛かる。）
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
