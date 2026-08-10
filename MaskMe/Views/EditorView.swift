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
    /// 動画下書きの更新先 ID（同一セッションは上書き保存）。
    @State private var videoDraftID: UUID?
    /// テキストの見た目設定シート（E3-3b）の提示対象。プレビュー上の選択から開く。
    /// **`private` にしないこと**（`model` と同じ理由。`EditorView+Preview.swift` が使う）。
    @State var textStyleItemID: UUID?
    /// 自動保存のデバウンス用タスク（最新 1 件のみ生かす）。
    @State private var autosaveTask: Task<Void, Never>?

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
        .navigationTitle(model.mode == .photo ? "写真編集" : "動画編集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { loadMedia() }
        .overlay { exportOverlay }
        .onAppear {
            if model.mode == .photo { photoEditingActive = true }
        }
        .onChange(of: scenePhase) { phase in
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
        // テキストの見た目設定シート（E3-3b）。プレビュー上でテキストを選び、
        // `TextOverlayEditView` の鉛筆ボタンから開く。提示条件・対象の解決は
        // `EditorTextStyleSheetModifier` へ寄せてある（`type_body_length` の都合）。
        .modifier(EditorTextStyleSheetModifier(model: model, itemID: $textStyleItemID))
    }

    // MARK: - Preview（本体は `EditorView+Preview.swift`）

    // MARK: - Dock（下段：顔サムネ / 調整バー / タブバー）

    /// 下段。**動画モードはここに何も置かない。**
    ///
    /// 動画モードのツールバーは `VideoControlsView` の中（タイムライン直下の
    /// `EditorDockView`）に 1 本だけあり、それが画面の最下段になる。ここに別の段を
    /// 置くと、道具と階層がまた 2 つの段に割れる（旧 UI の欠陥そのもの）。
    ///
    /// 写真モードは従来のまま（顔サムネ列・調整バー・タブバーを積む）。写真モードの
    /// UI 契約が `adjustmentBar` の構成に依存しているため、そちらは 1 行も変えない。
    @ViewBuilder
    private var dock: some View {
        if model.mode == .photo {
            photoDock
        }
    }

    private var photoDock: some View {
        VStack(spacing: 0) {
            // 顔タブ選択時のみ、対象の顔サムネイル列を表示。
            if model.activeTab == .face {
                FaceSelectorView(model: model)
                    .transition(.opacity)
            }

            // 調整バー：タブ選択中だけ下からスライドして表示。
            if model.activeTab != nil {
                adjustmentBar
                    .transition(.move(edge: .bottom))
            }

            EffectTabBar(model: model)
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .clipped()
        .animation(.easeOut(duration: 0.25), value: model.activeTab)
    }

    private var adjustmentBar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.35)

            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.35)

            Text("粗さ")
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .secondaryLabel))

            Slider(
                value: Binding(get: { model.activeBlockSize }, set: { model.activeBlockSize = $0 }),
                in: 4...80
            )

            Button { model.confirmAdjustment() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

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
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
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
                personProfiles: model.selectedPersonProfilesForDraft
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
