import MosaicCore
import SwiftUI
import UIKit

/// レイヤー段（`TimelineApplySpan.kind`）ごとの色・ラベルを引く場所。
///
/// **色・ラベルを呼び出し側や `TimelineLayerTrackView` の中に直書きしないこと。**
/// `TimelineLayerKind` に case が増えたとき（BGM・テキスト）、この `switch` が
/// `default` 無しで網羅しているため対応漏れがビルドで検出できる
/// （`TimelineSelection.prune` と同じ考え方。`TimelineLayerKind` の doc 参照）。
enum TimelineLayerAppearance {
    static func label(for kind: TimelineLayerKind) -> String {
        switch kind {
        case .mosaic: return "モザイク"
        case .audio: return "音楽"
        }
    }

    static func systemImage(for kind: TimelineLayerKind) -> String {
        switch kind {
        case .mosaic: return "squareshape.split.3x3"
        case .audio: return "music.note"
        }
    }

    static func fill(for kind: TimelineLayerKind, isSelected: Bool) -> Color {
        switch kind {
        case .mosaic: return TimelinePalette.mosaicFill(isSelected: isSelected)
        case .audio: return TimelinePalette.audioFill(isSelected: isSelected)
        }
    }
}

/// レイヤー段の本体（クリップ帯の下）。**種（`TimelineLayerKind`）に依存しない汎用トラック。**
///
/// 元は「モザイク適用区間トラック」専用だったが、この先 BGM・テキストのアイテムが
/// 同じ帯・選択・端ドラッグの仕組みに乗るため、`spans: [TimelineApplySpan]` を受けて
/// 描く形へ切り出した。色・ラベルは `TimelineLayerAppearance` が種から引く。
///
/// **座標系**: UI 操作はすべて**合成時刻**で行い、保存は
/// `MosaicApplyGate` / `TimelineState.addingApplyRange` が素材時刻アンカーへ写す。
/// 表示は逆写像 `TimelineBandLayout.applySpans(ranges:mapping:)` の結果を描くだけで、
/// この View は素材時刻を一切扱わない。
///
/// **1 区間は最大 1 セグメントにしか写らない**（不変条件 I2）。適用区間は S11 で
/// `clipID` アンカーになり、`clipID` は一意だからである（旧仕様では同じ素材を使う
/// クリップの数だけ同じ `rangeID` のセグメントが現れた）。確定は掴んだセグメント単位で
/// 行い、差し替えは素材時刻で走る（クリップ使用範囲外の素材区間はコア層が温存する。
/// `TimelineState.replacingApplyRange(id:clipID:compositionInterval:)` 参照）。
///
/// **写真クリップのセグメントには端ハンドルを出さない**
/// （`TimelineApplySpan.isEdgeAdjustable == false`）。写真の素材時刻は常に 0 へ丸められ、
/// 区間が必ずクリップ全体になるため端ドラッグが構造的に no-op になる。ハンドルを出すと
/// 「掴んで動かせるのに指を離すと必ず元へ戻る」という無言の失敗になる。
struct TimelineLayerTrackView: View {
    /// 端ドラッグの下書き（ジェスチャ中だけ非 nil）。
    /// `@GestureState` なのでキャンセルで自動的に初期値へ戻る。
    struct ApplyDraft: Equatable {
        let rangeID: UUID
        /// 素材時刻アンカー（`.mosaic`）のセグメントが属するクリップ。
        /// **BGM（`.audio`）では nil**（`TimelineApplySpan.anchorClipID` と同じ約束）。
        let clipID: UUID?
        let start: Double
        let end: Double
    }

    /// 本体ドラッグ（移動）の方向確定。一度決めたら同じジェスチャの間は変えない
    /// （`TimelineMetrics.applyMoveAxisLockThreshold` の doc 参照）。
    private enum MoveAxis: Equatable {
        case horizontal
        case vertical
    }

    /// 本体ドラッグの下書き。`@GestureState` なのでキャンセルで自動的に nil へ戻る
    /// （縦送りへ中継したまま指を離しても中継が止まらない、という取り残しを防ぐ）。
    private struct MoveGestureState: Equatable {
        let axis: MoveAxis
        /// `axis == .horizontal` のときだけ非 nil（表示反映用）。
        let applyDraft: ApplyDraft?
        /// `axis == .vertical` のときの、ドラッグ開始からの累積 translation.height（px）。
        /// `TimelineLayerScrollMath` へそのまま渡す形（祖先の `layerScrollGesture` と同じ量）。
        let verticalTranslation: Double
    }

    let geometry: TimelineGeometry
    let spans: [TimelineApplySpan]
    let totalDuration: Double
    /// 吸着候補（`TimelineSnap.candidates`）の材料。
    ///
    /// **既定値を持たせないこと。** 省略できると「渡し忘れても動くが吸着だけ効かない」
    /// という無言の劣化になる（S12 初版は既定値のまま未配線で、クリップ帯の端・
    /// プレイヘッドへの吸着とトリム中のリップル追随が丸ごと効いていなかった）。
    let layouts: [TimelineClipLayout]
    let playheadTime: Double
    /// クリップ帯のトリム下書きへの追随（リップル）。**表示専用**。
    @ObservedObject var trimPreviewRelay: TimelineTrimPreviewRelay
    @Binding var selectedRangeID: UUID?
    let onCommit: (TimelineInteraction) -> Void
    /// 本体ドラッグが縦方向に確定したときの中継先（`VideoTimelineLayerViewport` の
    /// `updateLayerScroll(translationHeight:)` / `endLayerScrollDrag()`）。
    ///
    /// このトラックは `.highPriorityGesture` で自分の上のタッチを先取りするため
    /// （端ハンドルと同じ配線）、祖先の段送りジェスチャ（`layerScrollGesture`）はモザイク段の
    /// 上のタッチを一切受け取れない。縦方向に確定したフレームだけこれを呼んで、
    /// 段送りの算術は 1 箇所（`TimelineLayerScrollMath`）に保ったまま見え方を合わせる。
    let onVerticalDrag: (CGFloat) -> Void
    let onVerticalDragEnded: () -> Void

    @GestureState private var draft: ApplyDraft?
    @GestureState private var moveState: MoveGestureState?
    /// `moveState` が縦方向へ確定している間 `true`。nil へ戻った瞬間に
    /// `onVerticalDragEnded()` を 1 回だけ呼ぶための後始末フラグ。
    @State private var isForwardingVerticalDrag = false
    /// 吸着ハプティクスの前回値保持（`TimelineSnapHaptics` の doc 参照）。
    @State private var haptics = TimelineSnapHaptics()
    /// 最後に成立したドラッグの記述（UI テストの切り分け用。`timeline.diag` として読める）。
    /// 見た目には出さない。`none` なら**ジェスチャが一度も成立していない**。
    @State private var lastDragDescription = "none"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(TimelinePalette.applyTrackBackground)
                .frame(width: max(geometry.width(forDuration: totalDuration), 1),
                       height: TimelineMetrics.applyTrackHeight)
            if displaySpans.isEmpty { emptyHint }
            ForEach(displaySpans) { span in
                spanView(span)
            }
            // **ドラッグの `translation` を外から読めるようにしておく**（見た目には出さない）。
            //
            // 帯の位置だけを見ていると「ジェスチャが発火していない」と「発火はするが
            // 確定が効かない」が区別できない。実際この 2 つを取り違えて、届いてもいない
            // 祖先の優先度・囲みの `UIScrollView` の当て板を延々と疑った
            // （真因は `moveHitArea` がつまみの当たり判定に重なっていたこと）。
            // これがあれば実機 UI テストの失敗メッセージ 1 行で決まる。
            Text(lastDragDescription)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("timeline.diag")
        }
        .frame(height: TimelineMetrics.applyTrackHeight, alignment: .topLeading)
        // `moveState` が縦方向へ確定している間だけ段送りへ中継し、方向が抜けた
        // （＝ジェスチャの終了・中断、または未確定へ戻った）瞬間に 1 回だけ後始末する。
        // `.updating` の中では書かない（`TimelineClipBandView` の同種コメント参照:
        // body 再評価 → ジェスチャ再生成 → `@GestureState` リセットの経路に乗るため）。
        .onChange(of: moveState) { newState in
            if let newState, newState.axis == .vertical {
                isForwardingVerticalDrag = true
                onVerticalDrag(CGFloat(newState.verticalTranslation))
            } else if isForwardingVerticalDrag {
                isForwardingVerticalDrag = false
                onVerticalDragEnded()
            }
        }
    }

    /// 区間が 1 つも無いときに、この段が何の段かを示す。
    ///
    /// 薄い帯だけだと**空の段は存在しないのと同じ**に見え、「モザイクを掛ける
    /// 区間をここに置ける」ことが読めない。ビューポート幅に依存させず左端へ置く
    /// （この段は横スクロールする中身の一部なので、追えば必ず見つかる）。
    private var emptyHint: some View {
        Label("モザイク", systemImage: "squareshape.split.3x3")
            .font(TimelinePalette.hintFont)
            .foregroundStyle(TimelinePalette.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: TimelineMetrics.applyTrackHeight)
            .allowsHitTesting(false)
    }

    /// 表示用スパン。クリップ帯のトリム下書き中は帯と同じ量だけ平行移動させる
    /// （忘れると帯だけ動いて区間が置いていかれる）。
    private var displaySpans: [TimelineApplySpan] {
        guard let trimPreview = trimPreviewRelay.preview else { return spans }
        return TimelineBandLayout.previewApplySpans(
            spans: spans, layouts: layouts, trimmingClipID: trimPreview.clipID,
            edge: trimPreview.edge, effectiveDeltaSeconds: trimPreview.effectiveDeltaSeconds)
    }

    @ViewBuilder
    private func spanView(_ span: TimelineApplySpan) -> some View {
        let bounds = displayBounds(span)
        let width = geometry.width(forDuration: bounds.end - bounds.start)
        let isSelected = selectedRangeID == span.rangeID

        RoundedRectangle(cornerRadius: 3)
            .fill(TimelineLayerAppearance.fill(for: span.kind, isSelected: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? TimelinePalette.selection : .white.opacity(0.18), lineWidth: 1)
            )
            .frame(width: max(width, 3), height: TimelineMetrics.applyTrackHeight)
            // **識別子・ラベルは帯そのものへ付ける**（overlay を重ねる前）。
            // 一番外側へ付けると帯と両端のつまみが 1 つの要素へ畳まれ、
            // つまみの識別子（`timeline.applySpan.handle.*`）が外から見えなくなる。
            // UI テストがつまみを掴めず「選択できていない」と誤読する。
            .accessibilityIdentifier("timeline.applySpan")
            .accessibilityLabel("\(TimelineLayerAppearance.label(for: span.kind))区間")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .overlay(alignment: .leading) { chipLabel(span, width: width, isSelected: isSelected) }
            .overlay(alignment: .leading) {
                if isSelected, span.isEdgeAdjustable { edgeHandle(span, edge: .start) }
            }
            .overlay(alignment: .trailing) {
                if isSelected, span.isEdgeAdjustable { edgeHandle(span, edge: .end) }
            }
            .overlay { moveHitArea(span, width: width, isSelected: isSelected) }
            // **当たり判定は `.offset` より前に置くこと。** `.offset` は描画専用なので、
            // 後ろに置いた `.contentShape` はオフセット前の空間に矩形を置き、当たり判定
            // だけが元の位置に取り残される。クリップ帯で同じ順序が「2 本目以降だけ
            // 見えているのに触れない」を生んでいた（`TimelineClipSelectionUITests` の doc）。
            // 区間は今は 1 本きり（開始 0 秒＝オフセット 0）で偶然一致しているが、
            // **区間を複数置けるようにした瞬間に同じ形で壊れる。**
            .contentShape(Rectangle())
            .onTapGesture { selectedRangeID = span.rangeID }
            .offset(x: geometry.x(forTime: bounds.start))
    }

    /// 本体ドラッグ（移動）を受ける領域。**両端のつまみの上には置かない。**
    ///
    /// ## なぜ帯の全面に付けてはいけないのか
    ///
    /// `.highPriorityGesture` は名前のとおり**そのジェスチャを優先する**修飾で、
    /// 親に付ければ子（つまみ）のジェスチャより先に成立する。当初これを
    /// 「深い方が勝つ」と取り違えて帯の全面に付けており、**選択してつまみを掴んでも
    /// 長さを変えられない**（実機で確認）状態になっていた。
    ///
    /// かといって通常の `.gesture` へ落とすことはできない。祖先の段送り
    /// （`VideoTimelineLayerViewport.layerScrollGesture`）が `.highPriorityGesture`
    /// なので、今度は移動が一切成立しなくなる。**優先度では解けないので領域で分ける。**
    ///
    /// ## 逃げ幅はつまみの当たり判定と**同じ値**にすること
    ///
    /// つまみの当たり判定は 44pt 角（`minimumTapTarget`）を**端から内側へだけ**広げてある
    /// （隣の区間へはみ出さないため。`edgeHandle` 参照）。よって逃げるべきは 44pt であって
    /// その半分ではない。`44 / 2` にしていた間、端から 22〜44pt の帯が両者で重なり、
    /// **この overlay の方が上に乗る**ぶん移動が勝っていた。つまみの当たり判定の中心
    /// （端から 22pt）はちょうどその中なので、**つまみを掴んだつもりで必ず移動になる**
    /// ＝「白いつまみは出るのに長さを変えられない」という実機の症状そのものだった
    /// （診断で `diag=move dx=90` を観測して確定）。
    ///
    /// 残りが掴める幅に満たない細い区間では**移動を諦めてつまみを優先する**
    /// （細い区間で先に要るのは長さの調整であって移動ではない）。
    @ViewBuilder
    private func moveHitArea(_ span: TimelineApplySpan, width: CGFloat, isSelected: Bool) -> some View {
        let inset = isSelected && span.isEdgeAdjustable ? TimelineMetrics.minimumTapTarget : 0
        let available = width - inset * 2
        if available >= Self.minimumMoveGrabWidth {
            Color.clear
                .frame(width: available, height: TimelineMetrics.applyTrackHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(moveGesture(span))
        }
    }

    /// 移動を受け付ける最小の掴み代（pt）。これを下回る帯では移動を出さない。
    private static let minimumMoveGrabWidth: CGFloat = 24

    /// チップの中に置く名前。**幅で削る。**
    ///
    /// 狭い区間で文字がはみ出すと、隣の区間の上に文字だけが乗って区切りが読めなくなる。
    /// アイコンすら入らない幅では何も出さない（`3pt` まで潰せる区間がある）。
    /// 選択中は左端ハンドル（`handleWidth`）の下に潜るので、そのぶん右へ寄せる。
    @ViewBuilder
    private func chipLabel(_ span: TimelineApplySpan, width: CGFloat, isSelected: Bool) -> some View {
        let leading = (isSelected ? TimelineMetrics.handleWidth : 0) + 4
        let label = TimelineLayerAppearance.label(for: span.kind)
        let systemImage = TimelineLayerAppearance.systemImage(for: span.kind)
        if width >= leading + 52 {
            Label(label, systemImage: systemImage)
                .font(TimelinePalette.badgeFont)
                .foregroundStyle(.white)
                .padding(.leading, leading)
                .allowsHitTesting(false)
        } else if width >= leading + 16 {
            Image(systemName: systemImage)
                .font(TimelinePalette.badgeFont)
                .foregroundStyle(.white)
                .padding(.leading, leading)
                .allowsHitTesting(false)
        }
    }

    /// 端ハンドル。見た目は `handleWidth`×28 のまま、**当たり判定だけ**を HIG の 44×44 へ広げる
    /// （トラック高 28pt + 上下 8pt ずつ）。
    ///
    /// 親に `.clipped()` / `.clipShape` が無いことが前提（無いことは確認済み。
    /// ヒットテストが frame の外へ本当に届くかは**実機確認事項**で、効かなければ
    /// 28pt 化のぶんだけでも現状比 +56% になる）。
    private func edgeHandle(_ span: TimelineApplySpan, edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(TimelinePalette.selection)
            .frame(width: TimelineMetrics.handleWidth, height: TimelineMetrics.applyTrackHeight)
            .contentShape(Rectangle())
            // **当たり判定は自分の区間の内側へだけ広げる**（クリップ帯のつまみと同じ理由）。
            // 中央揃えだと隣の区間の上へ 12pt はみ出し、境界付近をタップしても
            // 隣の区間を選べなくなる。
            .overlay(alignment: edge == .start ? .leading : .trailing) {
                Color.clear
                    .frame(width: TimelineMetrics.minimumTapTarget,
                           height: TimelineMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            // UI テストが**座標を推し量らずに**掴めるようにする。つまみは幅 20pt で
            // 帯の端に乗るため、座標から当てにいくと帯の途中を触っていても気づけない。
            .accessibilityIdentifier(edge == .start
                                     ? "timeline.applySpan.handle.start"
                                     : "timeline.applySpan.handle.end")
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($draft) { value, draft, _ in
                        if draft == nil { haptics.begin() }
                        let next = snappedDraft(span, kind: .edge(edge),
                                                translation: Double(value.translation.width))
                        haptics.report(snappedTo: next.snappedTo)
                        draft = next.draft
                    }
                    .onEnded { value in
                        lastDragDescription = "edge dx=\(Int(value.translation.width))"
                        haptics.end()
                        let committed = snappedDraft(span, kind: .edge(edge),
                                                     translation: Double(value.translation.width)).draft
                        onCommit(.applyEdge(rangeID: committed.rangeID, clipID: committed.clipID,
                                            kind: span.kind,
                                            start: committed.start, end: committed.end))
                    }
            )
    }

    /// 区間本体のドラッグ（平行移動）。`minimumDistance: 1` は `edgeHandle` と同じ値
    /// （祖先の `layerScrollGesture`（`minimumDistance: 4`）より先に認識を取るため）。
    ///
    /// **`.updating` の中では方向を確定させるだけで、縦送りへの中継は行わない**
    /// （`TimelineClipBandView` の同種コメントと同じ理由。中継は `onChange(of: moveState)`
    /// から行う）。`.onEnded` は `.updating` の下書きに頼らず、最終 `translation` から
    /// 改めて方向を決める（極小ドラッグでは `.updating` が一度も呼ばれないことがあるため）。
    private func moveGesture(_ span: TimelineApplySpan) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($moveState) { value, state, _ in
                guard let axis = Self.resolvedAxis(current: state?.axis, translation: value.translation)
                else { return }
                switch axis {
                case .horizontal:
                    if state?.axis != .horizontal { haptics.begin() }
                    let next = snappedDraft(span, kind: .move, translation: Double(value.translation.width))
                    haptics.report(snappedTo: next.snappedTo)
                    state = MoveGestureState(axis: .horizontal, applyDraft: next.draft, verticalTranslation: 0)
                case .vertical:
                    state = MoveGestureState(axis: .vertical, applyDraft: nil,
                                             verticalTranslation: Double(value.translation.height))
                }
            }
            .onEnded { value in
                lastDragDescription =
                    "move dx=\(Int(value.translation.width)) dy=\(Int(value.translation.height))"
                switch Self.resolvedAxis(current: nil, translation: value.translation) {
                case .horizontal:
                    haptics.end()
                    let committed = snappedDraft(span, kind: .move,
                                                 translation: Double(value.translation.width)).draft
                    let delta = committed.start - span.start
                    onCommit(.applyMove(rangeID: committed.rangeID, clipID: committed.clipID,
                                        kind: span.kind, deltaSeconds: delta,
                                        start: committed.start, end: committed.end))
                case .vertical:
                    break  // `onChange(of: moveState)` が nil への遷移で後始末する。
                case nil:
                    // 閾値未満＝実質タップ。この `DragGesture` が `.onTapGesture` より
                    // 先にタッチを掴んだ場合の保険として、同じ選択操作を行う
                    // （`minimumDistance: 1` は指のわずかな震えでも認識し得るため）。
                    selectedRangeID = span.rangeID
                }
            }
    }

    /// 本体ドラッグを「横（移動）」と「縦（段の送り）」のどちらとして扱うかを、
    /// 累積 translation から**一度だけ**確定する（`current` が非 nil ならそれを返し、
    /// 以後の方向転換を許さない）。しきい値は `TimelineMetrics.applyMoveAxisLockThreshold`
    /// の doc を参照。
    private static func resolvedAxis(current: MoveAxis?, translation: CGSize) -> MoveAxis? {
        if let current { return current }
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard max(dx, dy) >= TimelineMetrics.applyMoveAxisLockThreshold else { return nil }
        return dx >= dy ? .horizontal : .vertical
    }

    /// ドラッグ量から確定候補の合成時刻区間を作る。算術そのものは
    /// `TimelineItemDrag.snappedDraft`（`Sources/MosaicCore/Timeline/TimelineItemDrag.swift`）
    /// へ委譲する。ここは px→秒の下書き（`ApplyDraft`）への詰め替えだけを行う薄い層。
    private func snappedDraft(_ span: TimelineApplySpan, kind: TimelineItemDragKind,
                              translation: Double) -> (draft: ApplyDraft, snappedTo: Double?) {
        let context = TimelineItemDragContext(
            geometry: geometry, layouts: layouts, applySpans: spans,
            playheadTime: playheadTime, totalDuration: totalDuration)
        let result = TimelineItemDrag.snappedDraft(
            span: span, kind: kind, translationPixels: translation, context: context)
        return (ApplyDraft(rangeID: span.rangeID, clipID: span.anchorClipID,
                           start: result.start, end: result.end), result.snappedTo)
    }

    private func displayBounds(_ span: TimelineApplySpan) -> (start: Double, end: Double) {
        if let draft, draft.rangeID == span.rangeID, draft.clipID == span.anchorClipID {
            return (draft.start, draft.end)
        }
        if let applyDraft = moveState?.applyDraft,
           applyDraft.rangeID == span.rangeID, applyDraft.clipID == span.anchorClipID {
            return (applyDraft.start, applyDraft.end)
        }
        return (span.start, span.end)
    }
}
