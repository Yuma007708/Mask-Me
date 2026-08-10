import MosaicCore
import SwiftUI
import UIKit

/// プレビュー上のテキスト配置編集（E3-3b）。
///
/// ## 既存のプレビュー上ジェスチャとの共存
///
/// プレビューには既に `RectangleDrawingOverlay` が 2 種のジェスチャを持っている:
/// - `isRectangleToolActive` が ON のときだけ張る全面ドラッグ面（新規矩形の作成）。
///   **その間このビューは当たり判定を切る**（`body` の `allowsHitTesting` 参照）
/// - 既存の物体マスク（`ObjectMask`）の枠・つまみ（**常時有効**、矩形ツールの
///   ON/OFF に関係なく操作できる。ドラッグ面より**上**に重ねてある）
///
/// テキストの当たり判定は**矩形ツールが OFF のときだけ**張る。ON の間は
/// `allowsHitTesting(false)` で丸ごと切り、矩形の新規作成を優先する
/// （ツールを ON にしたのは「今から矩形を描く」という明示的な意図表明だから）。
/// 切らないと、テキストの上から描き始めた指をテキストが取り、**画面のその領域だけ
/// 矩形を描けない**という、画面上に手がかりの無い挙動になる。
///
/// 当たり判定の面積はテキストが実際に見える範囲だけに絞る（プレビュー全面へ
/// 透明面を張らない）ので、ツールが OFF のときも他の操作を広く奪うことはない。
///
/// **ドラッグでの移動は選択中のテキストにだけ許す。** 常時ドラッグ可能にすると、
/// モザイクの矩形を描こうとして置いた指がテキストに取られてしまう
/// （E3-3b 設計時の既知の罠）。未選択のテキストへのドラッグ・タップは「選択」だけを行い、
/// 位置は動かさない。
///
/// ## 文字そのものは描かない
///
/// 実際の文字はすでに `model.previewImage` へ焼き込まれている
/// （`MosaicPreviewController+Rendering.swift` → `TextOverlayCompositor`）。
/// このビューが描くのは**選択枠と当たり判定だけ**。ここで文字を重ねて描くと、
/// 縁取り・アニメーションの見え方が実際の書き出しと二重実装になってずれる。
///
/// ## 座標変換
///
/// px ⇔ 正規化座標の換算は必ず `PreviewImageGeometry`（`RectangleDrawingOverlay` /
/// `FacePickOverlay` と共通）を通す。ここへ式を書き戻さないこと。
struct TextOverlayEditView: View {
    @ObservedObject var model: MosaicEditorModel
    /// 見た目設定シートを開く対象。シート本体は `EditorView` が持つ
    /// （複数の画面領域から開けるようにするため、提示条件だけをここから渡す）。
    @Binding var styleSheetItemID: UUID?
    /// 画像・他オーバーレイと共有する換算。**ここでは作らない**——生成箇所は
    /// `EditorView+Preview.swift` の 1 箇所だけにする（`.swiftlint.yml` の
    /// `preview_geometry_single_construction` が番をしている）。
    let geometry: PreviewImageGeometry

    /// ドラッグ中の下書き。`@GestureState` なのでキャンセルで自動的に nil へ戻り、
    /// 中断（他のジェスチャに割り込まれた等）で下書きが取り残されない
    /// （`TimelineLayerTrackView` と同じ流儀）。
    private struct DragState: Equatable {
        let id: UUID
        var translation: CGSize
    }

    @GestureState private var dragState: DragState?

    /// タップと区別する最小移動量（pt）。これ未満は「選択のタップ」として扱う。
    private static let dragCommitThreshold: CGFloat = 3
    /// 当たり判定の最小辺（HIG のタップ領域）。
    private static let minimumHitSide: CGFloat = 44

    var body: some View {
        ZStack {
            ForEach(visibleItems) { item in
                hitRegion(for: item)
            }
        }
        .frame(width: geometry.containerSize.width, height: geometry.containerSize.height)
        // **矩形ツールが ON の間はテキストの当たり判定を切る。**
        //
        // 矩形ツールを ON にしたのは「今から矩形を描く」という明示的な意図表明なので、
        // その間はテキストより矩形の新規作成を優先する。切らないと、テキストの上から
        // 描き始めた指をテキストが取り、**画面のその領域だけ矩形を描けない**という
        // 説明のつかない挙動になる（テキストは自分で退かせるが、そこに気づく手がかりが
        // 画面上に何も無い）。
        //
        // 物体マスクの枠は矩形ツール ON 中も触れるが、あちらは「既に置いたものを
        // 直す」操作で、テキストの選択・移動と役割が違う。優先順位を揃える理由にはならない。
        //
        // **`isRectangleToolActive` は動画・写真どちらのモードでも矩形の新規作成を
        // 優先させる。** 矩形ツールは両モード共通の機能（`RectangleDrawingOverlay`）
        // なので、ここだけ動画限定にすると写真で矩形を描こうとした指をテキストが
        // 奪ってしまう（`TextOverlayEditView` 冒頭の doc と同じ理由）。
        //
        // **排他の根拠は `PreviewInteractionPolicy` であって、`CropOverlay` の
        // 全面キャッチレイヤーではない。** `allowsTextEditing` はこの
        // `!isRectangleToolActive` を移設したもので、クロップ編集中
        // （`interactionMode == .crop`）は常に false になる。
        .allowsHitTesting(model.previewInteraction.allowsTextEditing)
    }

    /// いま画面に出ているテキストだけを対象にする。
    ///
    /// 動画はコア層の `visibleTextItems`（合成時刻依存）1 本を通す。写真は時刻の概念が
    /// 無いため、`PhotoEditState.renderableTextItems`（保存されている全件を時刻0の
    /// パラメータへ正規化したもの。`PhotoTextEditing.swift` の doc 参照）をそのまま使う
    /// ——これは `PhotoRenderPipeline.render` が実際に焼き込む配列と同じものなので、
    /// 選択枠の対象と実際に描かれているテキストが食い違わない。
    private var visibleItems: [TextItem] {
        switch model.mode {
        case .video:
            guard model.videoDuration > 0 else { return [] }
            let time = model.compositionTime(forPosition: model.playbackPosition)
            return model.timeline.visibleTextItems(atComposition: time, totalDuration: model.videoDuration)
        case .photo:
            return model.photoEdit.renderableTextItems
        }
    }

    private var selectedID: UUID? {
        switch model.mode {
        case .video: return model.timelineSelection.layerID(of: .text)
        case .photo: return model.photoSelectedTextID
        }
    }

    @ViewBuilder
    private func hitRegion(for item: TextItem) -> some View {
        let isSelected = selectedID == item.id
        let base = geometry.screenPoint(from: CGPoint(x: item.center.x, y: item.center.y))
        // **`@ViewBuilder` の中で `if`/`else` を「文」として書かないこと。**
        // ViewBuilder はそれを View の分岐として解釈しようとし、
        // 「type '()' cannot conform to 'View'」で落ちる。値の分岐は式で書く。
        let drag = (dragState?.id == item.id ? dragState?.translation : nil) ?? .zero
        let shown = CGPoint(x: base.x + drag.width, y: base.y + drag.height)
        let hit = hitSize(for: item, in: geometry)

        // **当たり判定（`.contentShape` とジェスチャ）は `.frame` より前に置く。**
        // `RectangleDrawingOverlay.frameBody` → `maskOverlay` と同じ順序
        // （`.stroke().contentShape().gesture()` を作ってから `.frame().position()` で包む）。
        // 逆順（`.contentShape` を `.frame`/`.position` の後ろ）にすると、`.offset` と同じ理由で
        // 当たり判定だけが元の位置に取り残される罠がある（ここは `.position` なので実際には
        // 動くが、崩さない意味で他のオーバーレイと配線の形を揃えてある）。
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.yellow.opacity(0.95) : Color.clear,
                         style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .background(Color.yellow.opacity(isSelected ? 0.05 : 0.0001))
            .contentShape(Rectangle())
            .gesture(hitGesture(for: item, isSelected: isSelected))
            .frame(width: hit.width, height: hit.height)
            .overlay(alignment: .topTrailing) {
                if isSelected { styleButton(for: item) }
            }
            .position(x: shown.x, y: shown.y)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.text.item")
            .accessibilityLabel(item.role == .sticker ? "ステッカー: \(item.text)" : "テキスト: \(item.text)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// タップ（選択）とドラッグ（移動。選択中だけ）を 1 本のジェスチャに畳む。
    ///
    /// **`.onTapGesture` と `.gesture(DragGesture)` を別々に付けない。** 2 つの認識器を
    /// 同じ面へ重ねると、どちらが勝つかが実機で安定しない（`TimelineLayerTrackView.moveGesture`
    /// の `onEnded` で「移動とみなせる量に達しなければ選択」という同じ手筋を使っている。
    /// それに揃える）。
    private func hitGesture(for item: TextItem, isSelected: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($dragState) { value, state, _ in
                // **未選択のテキストは下書きを一切作らない。** 矩形ツールでの新規作成中に
                // テキストの上を掠めても、下書きが乗らなければ見た目に影響しない。
                guard isSelected else { return }
                state = DragState(id: item.id, translation: value.translation)
            }
            .onEnded { value in
                let moved = max(abs(value.translation.width), abs(value.translation.height))
                if isSelected, moved > Self.dragCommitThreshold {
                    commitDrag(item: item, translation: value.translation)
                } else {
                    select(item.id)
                }
            }
    }

    private func select(_ id: UUID) {
        switch model.mode {
        case .video: model.timelineSelection.selectLayer(TimelineLayerSelection(kind: .text, id: id))
        case .photo: model.photoSelectedTextID = id
        }
    }

    /// 指を離した最終位置だけをモデルへ確定する（ドラッグ中は `@GestureState` の
    /// 下書きだけを動かし、`applyTimelineEdit` は呼ばない。連続適用すると 1 ドラッグで
    /// undo 履歴が何十件も積まれる）。
    private func commitDrag(item: TextItem, translation: CGSize) {
        let base = geometry.screenPoint(from: CGPoint(x: item.center.x, y: item.center.y))
        let moved = CGPoint(x: base.x + translation.width, y: base.y + translation.height)
        // **`rawNormalizedPoint` を使う。** `normalizedPoint(from:)` は画像の外で nil を返す
        // （タップの当たり判定向け）ため、画面端までドラッグしたテキストを見失う。
        // 0...1 の外に出た分は `TimelineState.settingTextCenter` 側でクランプされる。
        guard let normalized = geometry.rawNormalizedPoint(from: moved) else { return }
        let center = NormalizedPoint(x: normalized.x, y: normalized.y)
        switch model.mode {
        case .video: model.setTextCenter(id: item.id, center: center)
        case .photo: model.setPhotoTextCenter(id: item.id, center: center)
        }
    }

    private func styleButton(for item: TextItem) -> some View {
        Button { styleSheetItemID = item.id } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white, Color.accentColor)
                .padding(6)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 16, y: -16)
        .accessibilityIdentifier("editor.text.style")
        .accessibilityLabel("テキストの見た目を編集")
    }

    /// 当たり判定のサイズ。実際に焼き込まれる文字（`TextRasterizer` が使うのと同じ
    /// フォント解決）を基準に測るが、**短い文字・小さいフォントサイズでも最低 44pt** は
    /// 確保する（HIG のタップ領域。指で選べなくなるテキストを作らない）。
    private func hitSize(for item: TextItem, in geo: PreviewImageGeometry) -> CGSize {
        let heightPx = max(geo.imageRect.height, 1)
        let pointSize = max(item.style.fontSize * heightPx, 8)
        let font = TextRasterizer.font(for: item.style.fontFamily, size: pointSize)
        let measured = (item.text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: max(measured.width + 20, Self.minimumHitSide),
                     height: max(measured.height + 14, Self.minimumHitSide))
    }
}
