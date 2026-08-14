import SwiftUI
import MosaicCore

/// 編集画面：プレビュー（上）/ 調整バー（中・タブ選択でスライド表示）/
/// カスタムタブバー（下）の3段構成。
struct EditorView: View {
    let media: PickedMedia
    /// 再開する下書きのパラメータ（新規編集なら nil）。
    private let resume: ResumeContext?

    /// **`private` にしないこと。** プレビュー上段の組み立ては
    /// `EditorView+Preview.swift`（別ファイルの extension）にあり、`private` だと
    /// そこから見えない。
    @StateObject var model: MosaicEditorModel
    @EnvironmentObject private var draftStore: DraftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// 写真編集中フラグ。OS は強制終了時にこれを破棄するため、写真下書きの
    /// 「強制終了で破棄／復帰では保持」の判別に使う。
    @SceneStorage("photoEditingActive") private var photoEditingActive = false

    @State private var showDiscardConfirm = false
    /// エクスポート時の速度／品質選択ダイアログ表示フラグ。
    @State private var showSpeedDialog = false
    /// 購入画面の提示。開いた理由（`paywallReason`）はアラートから受け取って渡す。
    @State private var showPaywall = false
    @State private var paywallReason: String?
    /// 動画下書きの更新先 ID（同一セッションは上書き保存）。
    @State private var videoDraftID: UUID?
    /// テキストの見た目設定シート（E3-3b）の提示対象。プレビュー上の選択から開く。
    /// **`private` にしないこと**（`model` と同じ理由。`EditorView+Preview.swift` が使う）。
    @State var textStyleItemID: UUID?
    /// プレビューのピンチズーム／パンの状態機械。**`private` にしないこと**（`model` /
    /// `textStyleItemID` と同じ理由。`EditorView+Preview.swift` が結線する）。
    /// **`MosaicEditorModel` へは絶対に載せない**（理由は `.swiftlint.yml` の
    /// `zoom_state_stays_out_of_the_model` のコメント参照）。
    @State var zoomSession = PreviewZoomSession()
    /// 「いま 2 本指ピンチが進行中か」。**`RectangleDrawingOverlay` の当たり判定を
    /// 切る信号はこちらを使う**（`zoomSession.isActive` ではない）。`@GestureState` は
    /// ジェスチャが（システムの割り込み等で）異常終了しても自動で `false` へ戻るが、
    /// `zoomSession.isActive` は `began()`/`ended()` を手で呼んで管理する値なので、
    /// `ended()` が呼ばれずに終わると立ちっぱなしになり、以後 1 本指編集が永久に
    /// 効かなくなる。**`private` にしないこと**（`model` と同じ理由。
    /// `EditorView+Preview.swift` が結線する）。
    @GestureState var isPinchZooming = false
    /// 自動保存のデバウンス用タスク（最新 1 件のみ生かす）。
    @State private var autosaveTask: Task<Void, Never>?
    /// 写真の色調補正シート（`TimelineColorGradeSheet`、動画側と共通）の提示条件。
    @State var showPhotoColorGradeSheet = false
    /// 写真のテキスト/ステッカー入力シート（既存 `TimelineTextInputSheet`、動画側と共通。
    /// 写真モード底上げ 第2段）の提示条件。
    @State var showPhotoTextInputSheet = false
    /// `PhotoRotateBar`（写真モード底上げ 第6段）の表示・非表示。
    @State var showPhotoRotateBar = false

    struct ResumeContext {
        let draftID: UUID
        let faceMosaicOn: Bool
        /// 手動矩形の ON/OFF。この項目より前の下書きは true（`EditingDraft` の doc）。
        var objectMosaicOn: Bool = true
        let backgroundMosaicOn: Bool
        let faceBlockSize: Float
        let backgroundBlockSize: Float
        let objectMasks: [ObjectMask]
        /// 旧下書きの矩形（移行専用）。復元時にモデルが全クリップへ配る。
        let legacyManualRects: [CGRect]
        // タイムライン復元（下書き v2）。v1 下書き・写真下書きは nil のままで、
        // 従来どおり「素材全体 1 クリップ」として読み込まれる。
        var timeline: TimelineState?
        var sourceURLs: [UUID: URL] = [:]
        var primarySourceID: UUID?
    }

    init(media: PickedMedia, recents: RecentItemsStore, resume: ResumeContext? = nil,
         settings: DetectionSettings = DetectionSettings()) {
        self.media = media
        self.resume = resume
        let mode: MosaicEditorModel.Mode = {
            if case .video = media { return .video }
            return .photo
        }()
        _model = StateObject(wrappedValue: MosaicEditorModel(mode: mode, recents: recents, settings: settings))
        _videoDraftID = State(initialValue: resume?.draftID)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            if model.mode == .video {
                VideoControlsView(model: model)
            }
            dock
        }
        // **画面の地はアプリと同じ濃紺**（`AppTheme` の型 doc 参照）。ここを黒のままに
        // すると、ホームは濃紺・編集画面だけ黒という段差が出る。プレビューの中
        // （`EditorView+Preview.swift` の `Color.black`）は黒のままでよい——あちらは
        // 映像の周りの余白で、映像の色を正しく見るための地。
        .background(AppTheme.background.ignoresSafeArea())
        // **ズームのリセットは画面比率そのものを見る。**
        //
        // プレビュー側（`EditorView+Preview.swift`）にも
        // `.onChange(of: model.croppedPreviewImage?.size)` があるが、あれは
        // **プレビューが画面に生きていることが前提**である。比率を選ぶシートを
        // 全画面（`presentationDetents([.large])`）にした途端、プレビューが覆われて
        // その `onChange` が発火せず、**比率を変えたのにズームが拡大したまま残った**
        // （UI テスト `test_afterAspectRatioChange_zoomResets` が捕まえた）。
        //
        // ここ（`EditorView` の根）はシートを出している主体なので、シートの高さに
        // 関係なく生きている。**シートの見た目の都合でリセットが消える経路を塞ぐ。**
        .onChange(of: model.timeline.aspectRatio) { _ in zoomSession.reset() }
        .navigationTitle(model.mode == .photo ? "写真編集" : "動画編集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { loadMedia() }
        .overlay { exportOverlay }
        .sheet(isPresented: $showPhotoColorGradeSheet) {
            TimelineColorGradeSheet(
                initialGrade: model.photoEdit.colorGrade,
                onApply: { model.setPhotoColorGrade($0) },
                onApplyToAll: { model.setPhotoColorGrade($0) })
        }
        // テキスト/ステッカー入力（写真モード底上げ 第2段）。動画側と同じシートを共有し、
        // 追加位置は既定の中心（`NormalizedPoint.center`）に置く
        // （動画側はプレイヘッド位置に置くが、写真に時刻の概念は無いため中心が既定になる。
        // 位置はドラッグ確定〈`TextOverlayEditView.commitDrag`〉で後から動かせる）。
        .sheet(isPresented: $showPhotoTextInputSheet) {
            TimelineTextInputSheet(
                onAddText: { text in model.addPhotoText(text) },
                onAddSticker: { emoji in model.addPhotoSticker(emoji) })
        }
        .onAppear {
            if model.mode == .photo { photoEditingActive = true }
        }
        .onChange(of: scenePhase) { phase in
            // **`cancelCropEditing()` は `persistDraft()` より先に呼ぶこと。**
            // クロップ編集中は合成が `crop = .full` で組み直されている
            // （`beginCropEditing()`）ため、ここで先に取消しておかないと、確定済みの
            // クロップが下書きへ「クロップ無し」として焼かれてしまう
            // （`MosaicEditorModel+Crop.swift` の型 doc 参照）。
            if phase != .active { model.cancelCropEditing() }
            if phase == .background { persistDraft() }
            // 非アクティブになったら立てっぱなしにしない（バックグラウンドでは
            // Metal が使えず書き出しも継続できないので、保つ意味が無い）。
            if phase != .active { UIApplication.shared.isIdleTimerDisabled = false }
        }
        // 書き出し中は画面をスリープさせない。キャンセル・失敗・成功のすべてで
        // `exportProgress` は nil に戻るので、この 1 本で全経路を解除できる。
        .onChange(of: model.exportProgress) { progress in
            UIApplication.shared.isIdleTimerDisabled = (progress != nil)
        }
        .onChange(of: model.editVersion) { _ in scheduleAutosave() }
        // 読み込み完了直後（＝まだ何も編集していない時点）に 1 回だけ保存して、
        // 素材コピーという最も重い IO を先に済ませておく。以降の自動保存は
        // サムネ + JSON + ディレクトリ走査だけになる（`registerSource` は
        // 素材IDごとに 1 回しかコピーしない）。
        .onChange(of: model.isLoading) { loading in
            guard !loading, model.mode == .video else { return }
            persistDraft()
        }
        .onDisappear {
            // **`persistDraft()` より先に呼ぶ。** クロップ編集中に画面が閉じられる
            // 経路（`onDisappear`）はここでも取消しておく。`handleBack()` の
            // `persistDraft()` は `dismiss()` の**前**に走るため、そちらは
            // `handleBack()` 側でも同じ呼び出しを行う（下記）。
            model.cancelCropEditing()
            autosaveTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            // 画面を閉じるときに走行中の走査を畳む。`objectTrackingTasks` /
            // `regionSeedTask` は `self` を強く保持したまま実行され続けるため、
            // ここで打ち切らないと画面を離れてもデコードが走り続ける
            // （`cancelObjectTracking()` はこれまでどの経路からも呼ばれておらず、
            // 追跡側もここが畳み忘れの穴だったので合わせて塞ぐ）。
            model.cancelObjectTracking()
            model.cancelRegionSeeding()
        }
        .confirmationDialog(
            "編集を破棄して戻りますか？",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("破棄して戻る", role: .destructive) {
                draftStore.deletePhotoDraft()
                photoEditingActive = false
                dismiss()
            }
            Button("編集を続ける", role: .cancel) {}
        }
        .confirmationDialog(
            "加工速度を選択",
            isPresented: $showSpeedDialog,
            titleVisibility: .visible
        ) {
            ForEach(ExportSpeed.allCases, id: \.self) { speed in
                Button(speed.displayName) {
                    model.exportSpeed = speed
                    Task { await runAction() }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("速いほど処理時間が短くなります。速い動きが多い動画は「高品質」推奨。")
        }
        .alert("保存しました", isPresented: $model.didSave) {
            Button("OK", role: .cancel) {}
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Pro を買えば解ける制限に当たったとき。**行き止まりにしない**——
        // 「Proにアップグレードすれば」と書いてあるのに買う手段が無いのが、
        // 課金アプリでいちばん質の悪い行き止まりになる。
        .alert(
            "無料プランの制限",
            isPresented: Binding(
                get: { model.paywallPrompt != nil },
                set: { if !$0 { model.paywallPrompt = nil } }
            )
        ) {
            Button("Pro を見る") {
                paywallReason = model.paywallPrompt
                model.paywallPrompt = nil
                showPaywall = true
            }
            Button("閉じる", role: .cancel) { model.paywallPrompt = nil }
        } message: {
            Text(model.paywallPrompt ?? "")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(reason: paywallReason)
        }
        // テキストの見た目設定シート（E3-3b）。プレビュー上でテキストを選び、
        // `TextOverlayEditView` の鉛筆ボタンから開く。提示条件・対象の解決は
        // `EditorTextStyleSheetModifier` へ寄せてある（`type_body_length` の都合）。
        .modifier(EditorTextStyleSheetModifier(model: model, itemID: $textStyleItemID))
    }

    // MARK: - Preview（本体は `EditorView+Preview.swift`）
    // MARK: - Dock（本体は `EditorView+Dock.swift`）

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                handleBack()
            } label: {
                Label("戻る", systemImage: "chevron.backward")
            }
            .disabled(model.exportProgress != nil)
        }
        // 写真モード限定の共有導線（写真モード底上げ 第3段）。**`previewImage` だけを
        // 共有する。** モザイク・テキスト・（無料プランなら）透かしが焼き込み済みの
        // 絵をそのまま渡す——`savePhoto()` と同じ WYSIWYG 規約（原本は一切渡らない。
        // カメラ撮影の「モザイク焼き込み済みメディアだけを保存」と同じ理由）。
        // `Image` は URL/String と違い `preview:` が必須（省略するとイニシャライザが解決しない）。
        // プレビューにも同じ `previewImage` を渡す——共有シートのサムネイルにだけ
        // 焼き込み前の絵が出る、という抜け道を作らないため。
        if model.mode == .photo, let previewImage = model.previewImage {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: Image(uiImage: previewImage),
                          preview: SharePreview("共有", image: Image(uiImage: previewImage))) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(model.mode == .photo ? "保存" : "エクスポート") {
                // 動画は速度段を選んでから加工。写真は即保存。
                if model.mode == .video {
                    showSpeedDialog = true
                } else {
                    Task { await runAction() }
                }
            }
            .disabled(model.previewImage == nil || model.exportProgress != nil)
        }
    }

    /// 書き出し中のオーバーレイ。
    ///
    /// 中断要求後もオーバーレイは残す: `requestMediaDataWhenReady` のブロックは
    /// writer 入力が ready になるまで再呼び出しされないため、`cancel()` が効くまでに
    /// 遅延がある（writer がストールした場合は効かないこともある）。
    /// 「中止しています…」を出して待つ設計にする。
    ///
    /// **エンコード完了後の「写真ライブラリへ保存中」フェーズではキャンセル導線を出さない**
    /// （`MosaicEditorModel.isExportSaving` の doc 参照。押しても効かないボタンを出すと
    /// 「中止しています…」が保存完了まで貼り付く）。
    @ViewBuilder
    private var exportOverlay: some View {
        if let progress = model.exportProgress {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 12) {
                    if model.isExportSaving {
                        ProgressView().frame(width: 200)
                        Text("写真ライブラリに保存中…").font(.callout)
                    } else {
                        ProgressView(value: progress).frame(width: 200)
                        Text("エクスポート中… \(Int(progress * 100))%").font(.callout)
                        if model.isExportCancelling {
                            Text("中止しています…")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.inkDim)
                        } else {
                            Button("キャンセル", role: .cancel) { model.cancelExport() }
                                .font(.callout)
                        }
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Actions

    private func loadMedia() {
        switch media {
        case .image(let image): model.load(image: image)
        case .video(let url):
            // 下書き v2 のタイムライン復元は load の**前**に予約する
            // （load は非同期にタイムラインを初期化するため、後から差し替えると
            //   既定の単一クリップに上書きされる。queueTimelineRestore の doc 参照）。
            if let resume, let timeline = resume.timeline, !timeline.clips.isEmpty,
               let primary = resume.primarySourceID {
                model.queueTimelineRestore(timeline: timeline,
                                           sourceURLs: resume.sourceURLs,
                                           primarySourceID: primary)
            }
            model.load(videoURL: url)
        }
        if let resume {
            model.applyRestoredParameters(
                faceMosaicOn: resume.faceMosaicOn,
                objectMosaicOn: resume.objectMosaicOn,
                backgroundMosaicOn: resume.backgroundMosaicOn,
                faceBlockSize: resume.faceBlockSize,
                backgroundBlockSize: resume.backgroundBlockSize,
                objectMasks: resume.objectMasks,
                legacyManualRects: resume.legacyManualRects,
                // 顔選択の目印は `ResumeContext` を経由せず下書き本体から引く
                // （復元専用の内部情報で、下書き ID から一意に取れる）。
                // nil＝新フィールド導入前の下書き → 顔の選択状態には触れない。
                faceSelections: draftStore.faceSelections(forDraftID: resume.draftID),
                // 目印が指す人物。**目印と必ず同じ下書きから引く**（別の下書きの
                // 人物を渡すと、目印の personID がどの人物とも結び付かないまま
                // 位置照合へ落ちる）。
                personProfiles: draftStore.personProfiles(forDraftID: resume.draftID)
            )
        }
    }

    private func runAction() async {
        switch model.mode {
        case .photo:
            await model.savePhoto()
            if model.didSave {
                draftStore.deletePhotoDraft()
                photoEditingActive = false
            }
        case .video:
            await model.exportVideo()
            // 書き出し後も下書きは**残す**（CapCut / iMovie / 写真アプリと同じ挙動）。
            // 書き出した動画を見てから直したくなったとき、タイムライン構成が消えて
            // 最初からやり直しになるのを避ける。削除の導線は「最近の項目」の
            // スワイプ削除に既存で、書き出し結果（最近の項目）と下書き（編集中）は
            // 表示セクションが分かれるので二重表示にもならない。
            if model.didSave { persistDraft() }
        }
    }

    // MARK: - 戻る・状態保持

    private func handleBack() {
        // クロップ編集中に戻るを押した経路（`.video` は下の `persistDraft()` が
        // `dismiss()` の前に下書きへ書くため、`onDisappear` より前にここで取消す）。
        model.cancelCropEditing()
        switch model.mode {
        case .photo:
            showDiscardConfirm = true
        case .video:
            persistDraft()
            dismiss()
        }
    }
}

// MARK: - 下書きの保存・自動保存
//
// extension に置いてあるのは `type_body_length`（上限 300）対策
// （extension のメンバーは型本体の行数に数えられない）。

extension EditorView {
    private func persistDraft() {
        switch model.mode {
        case .photo:
            guard let image = model.photoSourceImage else { return }
            draftStore.savePhotoDraft(
                existing: nil,
                image: image,
                faceMosaicOn: model.faceMosaicOn,
                objectMosaicOn: model.objectMosaicOn,
                backgroundMosaicOn: model.backgroundMosaicOn,
                faceBlockSize: model.faceBlockSize,
                backgroundBlockSize: model.backgroundBlockSize,
                objectMasks: model.draftObjectMasks,
                faceSelections: model.selectedFaceAnchors,
                personProfiles: model.selectedPersonProfilesForDraft,
                photoEdit: model.photoEdit
            )
            photoEditingActive = true
        case .video:
            // タイムラインが参照する全素材を保存対象にする（v2）。
            // クリップ未構築（読み込み中に離脱）の間は最後にロードした素材のみ。
            let sources = model.draftSources
            guard !sources.isEmpty else { return }
            let draft = draftStore.saveVideoDraft(
                existing: videoDraftID,
                sources: sources,
                sessionSourceIDs: model.sessionReferencedSourceIDs,
                timeline: model.timeline,
                faceMosaicOn: model.faceMosaicOn,
                objectMosaicOn: model.objectMosaicOn,
                backgroundMosaicOn: model.backgroundMosaicOn,
                faceBlockSize: model.faceBlockSize,
                backgroundBlockSize: model.backgroundBlockSize,
                objectMasks: model.draftObjectMasks,
                faceSelections: model.selectedFaceAnchors,
                personProfiles: model.selectedPersonProfilesForDraft,
                thumbnail: model.previewImage
            )
            videoDraftID = draft?.id
        }
    }

    /// 確定編集から 2 秒後に下書きを保存する（デバウンス）。
    ///
    /// `commitEdit()` は確定操作でしか呼ばれない（スライダーのドラッグ中は呼ばれない）ため
    /// 実際の発火は「タップ数」オーダーだが、undo 連打のような連続操作で無駄な IO が
    /// 出るのでまとめる。書き出し中は見送る（素材コピー + サムネ書き出しの同期 IO を
    /// 書き出しに挟まないため。書き出し完了時に `runAction` が必ず保存する）。
    ///
    /// 再入の心配は無い: `DraftStore` も `MosaicEditorModel` も `@MainActor` で
    /// `saveVideoDraft` は同期関数なので、保存中に編集が割り込む構造が存在しない。
    func scheduleAutosave() {
        guard model.mode == .video else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, model.exportProgress == nil else { return }
            persistDraft()
        }
    }
}
