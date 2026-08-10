import MosaicCore
import SwiftUI

/// 動画モードの**唯一の**下部ツールバー。1 段のまま、中身が丸ごと入れ替わる。
///
/// 旧 UI は段が 2 つに割れていた:
/// - タイムライン直下の編集ツールバー（分割・速度・音量・並べ替え）
/// - 画面最下部の効果ドック（モザイクの階層。戻る `‹` はこちらにしか無い）
///
/// 道具は上の段、階層は下の段、という分かれ方だったので、**いま何の中にいるのか**
/// が読めず、戻るのに `‹` を何回押すか数えることになっていた。1 段に統合し、
/// 現在地を `model.dockRoute`（`EditorDockRoute`）1 本で表す。
///
/// 段の並びはどの階層でも同じ:
/// ```
/// [‹] │ …中身… │ [完了]
/// ```
/// `‹` と「完了」は最上段（`root`）では出ない。中身だけが階層で変わる。
///
/// **高さは階層で変えない**（`Self.height`）。変えると階層を移るたびに
/// プレビューの高さが動く（旧 UI が 46% → 30% まで潰れた原因そのもの）。
///
/// **段は勝手に閉じない。** シーク・再生・スクロール・クリップの選択では
/// `dockRoute` を触らない（`EditorDockRoute` の doc に契約がある）。粗さを
/// 調整しながら再生位置を確かめる、という当たり前の操作を成立させるため。
struct EditorDockView: View {
    @ObservedObject var model: MosaicEditorModel
    /// `root` に並べる編集の道具。タイムライン側の文脈（選択・プレイヘッド・ズーム）に
    /// 依存するので、組み立ては `VideoTimelineView+Toolbar` が持ち、ここは並べるだけ。
    let rootItems: [TimelineToolItem]
    /// 色調補正の詳細（4 スライダー）シートの提示条件。
    ///
    /// **この View だけが持つローカル状態。** `speedSheetClipID` のように
    /// `VideoTimelineView` の `@State` へは上げていない — `.colorGrade` 段の中身
    /// （プリセットのチップ列）が既にこの View に閉じているため、詳細シートも
    /// ここへ閉じたほうが導線が 1 箇所で完結する（`TimelineEditSheetsModifier` を
    /// 経由させると提示条件の分岐がもう 1 段増えるだけで得るものがない）。
    /// **既知のトレードオフ**: `TimelineEditSheetsModifier.isSheetPresented` の
    /// サムネイル抑止対象に入らない（このシートを開いている間もサムネイル生成が
    /// 止まらない）。安全性には無関係な UI 上の細かな非効率のみ。
    @State private var showColorGradeDetail = false

    /// 段の高さ。**階層で変えないこと。**
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 6) {
            if model.dockRoute.showsBackButton {
                backButton
                divider
            }
            content
            if model.dockRoute.showsDoneButton {
                divider
                doneButton
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.18), value: model.dockRoute)
        .sheet(isPresented: $showColorGradeDetail) { colorGradeDetailSheet }
    }

    // **この HStack に `accessibilityIdentifier` を付けないこと。**
    // SwiftUI はコンテナに付けた識別子を子孫へ伝播させ、子が自分で持っている
    // 識別子を上書きする。実際に `editor.dock.back` / `editor.dock.done` /
    // `editor.rectangleTool` が全部 `editor.dock` に化け、UI テスト 6 件が
    // 「ボタンが無い」で落ちた（要素一覧に identifier: 'editor.dock' が 3 つ並ぶ）。
    // 段そのものを指したくなったら、子を畳まない `accessibilityElement(children: .contain)`
    // と併せて付けること（`VideoTimelineView.trackStack` が同じ理由でそうしている）。

    // MARK: - 階層ごとの中身

    @ViewBuilder
    private var content: some View {
        switch model.dockRoute {
        case .root:
            // 横スクロールは**保険として残す**。モックの 5 項目に収まらない
            // 「前へ／後へ」（画面外のクリップと入れ替える唯一の手段）と
            // ズーム（ピンチが使えないときの代替）を落とさないため。
            TimelineToolbarView(items: rootItems)
        case .mosaic:
            mosaicMenu
        case .face:
            effectToggle(.face)
            // 矩形の入口はここに出さない（`.rectangle` の段が持つ）。
            FaceSelectorView(model: model, compact: true, showsRectangleTool: false)
            blockSizeSlider
        case .background:
            effectToggle(.background)
            blockSizeSlider
        case .rectangle:
            // 矩形そのものの ON/OFF。顔・背景と同じ位置（段の先頭）に置く。
            objectMosaicToggle
            rectangleToolToggle
            // 置いた矩形のチップ（✕ で削除）。**これが無いと置いた矩形を取り消せない。**
            // 顔チップはこの段の関心ではないので落とす。
            FaceSelectorView(model: model, compact: true,
                             showsRectangleTool: false, showsFaces: false)
            blockSizeSlider
        case .colorGrade:
            colorGradeChips
        case .transform:
            transformButtons
        case .crop:
            CropControlBar(model: model)
        }
    }

    /// 色調補正（P4）。**上段はプリセットのチップ列だけ**（52pt の固定段に収まる範囲）。
    /// 4 本のスライダーは `showColorGradeDetail` シート側（`TimelineColorGradeSheet`）に
    /// ある（`EditorDockView.height` を階層で変えない契約のため。段そのものの doc 参照）。
    /// 対象は選択中のクリップ（`model.timelineSelection.clipID`）。選択が無ければ
    /// 全チップを非活性にする（押しても何も起きないボタンは出さない）。
    private var colorGradeChips: some View {
        let clipID = model.timelineSelection.clipID
        let currentGrade = clipID.flatMap { id in
            model.timeline.clips.first(where: { $0.id == id })?.colorGrade
        } ?? .identity
        let matching = ColorGradePreset.matching(currentGrade)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ColorGradePreset.allCases, id: \.self) { preset in
                    dockButton(title: preset.displayName, systemImage: preset.symbolName,
                              isActive: matching == preset) {
                        guard let clipID else { return }
                        model.setColorGrade(clipID: clipID, preset.grade)
                    }
                }
                Divider().frame(height: 26)
                dockButton(title: "詳細", systemImage: "slider.horizontal.3", isActive: false) {
                    showColorGradeDetail = true
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(clipID == nil)
    }

    /// 詳細シート（明るさ・コントラスト・彩度・暖かみの 4 スライダー）。
    @ViewBuilder
    private var colorGradeDetailSheet: some View {
        if let clipID = model.timelineSelection.clipID,
           let clip = model.timeline.clips.first(where: { $0.id == clipID }) {
            TimelineColorGradeSheet(
                initialGrade: clip.colorGrade,
                onApply: { grade in model.setColorGrade(clipID: clipID, grade) },
                onApplyToAll: { grade in model.applyColorGradeToAllClips(grade) })
        }
    }

    /// クリップの向き（回転・反転）。以前の「回転」「反転」2 ボタンをここへ畳んである
    /// （`EditorDockRoute.transform` の doc・`VideoTimelineView+Toolbar` の doc 参照）。
    /// 押すたびに即実行（スライダーではないので確定の概念が無い）。
    private var transformButtons: some View {
        let clipID = model.timelineSelection.clipID
        return HStack(spacing: 6) {
            dockButton(title: "回転", systemImage: "rotate.right", isActive: false) {
                guard let clipID else { return }
                model.rotateClipRight(id: clipID)
            }
            dockButton(title: "反転",
                      systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                      isActive: false) {
                guard let clipID else { return }
                model.flipClipHorizontally(id: clipID)
            }
            Spacer(minLength: 0)
        }
        .disabled(clipID == nil)
    }

    /// モザイクの種類選び。ON になっている効果は点灯させて、
    /// 段を降りなくても「いま何が効いているか」が読めるようにする。
    private var mosaicMenu: some View {
        HStack(spacing: 6) {
            dockButton(title: "顔", systemImage: EffectTabSymbol.name(for: .face),
                       isActive: model.isDockEffectOn(.face)) {
                model.enterDock(.face)
            }
            dockButton(title: "背景", systemImage: EffectTabSymbol.name(for: .background),
                       isActive: model.isDockEffectOn(.background)) {
                model.enterDock(.background)
            }
            // 点灯は「矩形が置いてあり、かつ効いている」とき
            // （置いてあっても切ってあれば効いていない）。
            dockButton(title: "矩形", systemImage: "rectangle.dashed",
                       isActive: model.objectMosaicOn && !model.draftObjectMasks.isEmpty) {
                model.enterDock(.rectangle)
            }
            Spacer(minLength: 0)
        }
    }

    /// 効果の ON/OFF。**段を降りる操作では効果が切れない**契約なので、
    /// 切る導線はここにしか無い（`toggleDockEffect` の doc 参照）。
    private func effectToggle(_ tab: MosaicEditorModel.EffectTab) -> some View {
        let isOn = model.isDockEffectOn(tab)
        return dockButton(title: tab.title, systemImage: EffectTabSymbol.name(for: tab),
                          isActive: isOn,
                          accessibilityLabel: "\(tab.title)モザイクを\(isOn ? "オフ" : "オン")") {
            model.toggleDockEffect(tab)
        }
    }

    /// 矩形モザイクそのものの ON/OFF。**顔とは独立**（`objectMosaicOn`）。
    /// 顔を切ると矩形まで消えていたのを分けたので、切る導線もここに要る。
    private var objectMosaicToggle: some View {
        let isOn = model.objectMosaicOn
        return dockButton(title: "矩形", systemImage: "rectangle.dashed",
                          isActive: isOn,
                          accessibilityLabel: "矩形モザイクを\(isOn ? "オフ" : "オン")") {
            model.toggleObjectMosaic()
        }
        .accessibilityIdentifier("editor.objectMosaicToggle")
    }

    /// 矩形を置くモードの ON/OFF。ON の間だけプレビューのドラッグが矩形作成になる
    /// （`RectangleDrawingOverlay`）。常時 ON にしていた頃は、少しなぞっただけで
    /// 矩形ができて「間違えて指定して使いづらい」状態だった。
    private var rectangleToolToggle: some View {
        dockButton(title: "追加", systemImage: "plus.rectangle",
                   isActive: model.isRectangleToolActive,
                   accessibilityLabel: model.isRectangleToolActive ? "矩形の追加をやめる" : "矩形を追加") {
            model.isRectangleToolActive.toggle()
        }
        .accessibilityIdentifier("editor.rectangleTool")
    }

    private var blockSizeSlider: some View {
        HStack(spacing: 6) {
            Text("粗さ")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize()
            Slider(value: Binding(get: { model.activeBlockSize },
                                  set: { model.activeBlockSize = $0 }),
                   in: 4...80)
                .tint(.accentColor)
                .frame(minWidth: 70)
        }
    }

    // MARK: - 共通の部品

    private var divider: some View {
        Divider().frame(height: 26)
    }

    private var backButton: some View {
        Button { model.dockBack() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 40)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("戻る")
        .accessibilityIdentifier("editor.dock.back")
    }

    /// 完了はどの深さからでも 1 回で最上段へ戻す（`‹` の連打を要求しない）。
    private var doneButton: some View {
        Button { model.dockDone() } label: {
            Text("完了")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.dock.done")
    }

    private func dockButton(title: String, systemImage: String, isActive: Bool,
                            accessibilityLabel: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 56, height: 42)
            // **`secondaryLabel` を使わないこと。** 旧ドックは明るい `systemBackground` の
            // 上にあったのでそれで読めたが、統合先はタイムラインの暗い帯の中なので、
            // ライトモードで濃いグレー文字が中間グレーの地に沈む。
            // 非活性は白の不透明度で落とす（`TimelineToolbarView` と同じ考え方）。
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.55))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
