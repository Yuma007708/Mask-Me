import MosaicCore
import SwiftUI

/// クリップ帯トラック（サムネ列 + 選択 + トリム + 並べ替え + 継ぎ目ボタン）。
struct TimelineClipBandView: View {
    /// 端トリムの下書き（ジェスチャ中だけ非 nil）。
    struct TrimDraft: Equatable {
        let clipID: UUID
        let edge: TimelineTrimEdge
        let deltaSeconds: Double
    }

    /// 長押し並べ替えの下書き。
    struct ReorderDraft: Equatable {
        let clipID: UUID
        let translationSeconds: Double
    }

    @ObservedObject var model: MosaicEditorModel
    @ObservedObject var thumbnails: TimelineThumbnailStore
    @ObservedObject var waveforms: TimelineWaveformStore
    let geometry: TimelineGeometry
    let layouts: [TimelineClipLayout]
    /// 吸着候補（`TimelineSnap.candidates`）の材料。
    ///
    /// **既定値を持たせないこと。** 省略できると「渡し忘れても動くが吸着だけ効かない」
    /// という無言の劣化になる（S12 初版は既定値のまま未配線で、適用区間の端と
    /// プレイヘッドへの吸着が丸ごと効いていなかった）。
    let applySpans: [TimelineApplySpan]
    let playheadTime: Double
    let totalDuration: Double
    /// スクロール量・指の位置の受け渡し口（再描画を伴わない可変値の置き場）。
    let autoScroll: TimelineAutoScrollState
    /// トリム下書きから導いた**表示専用**パラメータの中継先（適用区間トラックが購読する）。
    /// このビューは書くだけで購読しない（`TimelineTrimPreviewRelay` の doc 参照）。
    let trimPreviewRelay: TimelineTrimPreviewRelay
    @Binding var selectedClipID: UUID?
    /// ジェスチャ確定（`onEnded`）の通知。モデルの編集はすべて親が行う。
    let onCommit: (TimelineInteraction) -> Void

    @GestureState private var trimDraft: TrimDraft?
    /// 長押し並べ替えの下書き。
    ///
    /// **`@GestureState` ではなく `@State`。** 入力が SwiftUI のジェスチャではなく
    /// UIKit の recognizer（`TimelineReorderRecognizer`）なので自動リセットに乗せられない。
    /// 代わりに recognizer が終端 3 状態（終了・中断・失敗）を必ず 1 回通知するので、
    /// `finishReorder` で確実に片付く。
    @State private var reorderDraft: ReorderDraft?
    /// 吸着ハプティクスの前回値保持。**参照型を `@State` に入れる**
    /// （`TimelineSnapHaptics` の doc 参照）。
    @State private var haptics = TimelineSnapHaptics()
    /// 並べ替えジェスチャ開始時のスクロール量（px）。
    ///
    /// `DragGesture.translation` は**指の移動量**なので、ドラッグ中に自動スクロールが
    /// 走るとコンテンツと指の相対関係が崩れる。確定・プレビューには
    /// 「指の移動量 + （現在のスクロール量 − 開始時のスクロール量）」を使う。
    @State private var reorderStartScrollOffset: Double?

    /// 長押しで並べ替えに入るまでの時間（秒）。
    private static let reorderPressDuration: TimeInterval = 0.3
    /// 長押し成立と見なす指のブレ幅（px）。**これより先に動いたら横スクロール（= シーク）**。
    private static let reorderAllowableMovement: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelinePalette.clipBandBackground
                .frame(height: TimelineMetrics.clipHeight)
                // 帯の空白タップで選択解除（目盛り帯には付けない。あちらは
                // `DragGesture(minimumDistance: 0)` がタップも拾うスクラブ帯なので誤爆する）。
                .contentShape(Rectangle())
                .onTapGesture { selectedClipID = nil }
            ForEach(layouts) { layout in
                clipView(layout)
            }
            insertionIndicator
            // 長押し並べ替えの入力。**帯全体に 1 個だけ**置く（`hitTest` 素通しなので
            // 下のタップ・横スクロールを吸わない。`TimelineReorderRecognizer` の doc）。
            TimelineReorderRecognizer(
                minimumPressDuration: Self.reorderPressDuration,
                allowableMovement: Self.reorderAllowableMovement,
                onBegin: beginReorder,
                onChange: updateReorder,
                onFinish: finishReorder)
        }
        .frame(height: TimelineMetrics.clipHeight, alignment: .topLeading)
        // ジェスチャのキャンセル（横スクロールへの奪取など）でも必ず後始末する。
        // `onEnded` は中断で呼ばれないので、そこだけに頼ると自動スクロールが走り続ける。
        .onChange(of: reorderDraft) { draft in
            guard draft == nil else { return }
            reorderStartScrollOffset = nil
            autoScroll.endDrag()
        }
        // トリム下書き（表示専用の派生値）を適用区間トラックへ中継する。
        //
        // **`.updating` の中では書かない**（body 再評価 → ジェスチャ再生成 →
        // `@GestureState` リセットの経路に乗る）。`@GestureState` の変化を `onChange` で
        // 受けるので、横スクロールへの奪取などで**キャンセルされたときも nil へ戻る**
        // （`reorderDraft` の後始末と同じ形）。
        //
        // 代償として、区間トラックのリップルは帯より**1 レンダーパス遅れる**
        // （帯は body 内で `trimDraft` を直読み、中継は `onChange` 経由のため）。
        // 値は同一（実測でシフト量の差は 1e-9 以内）で、遅れはドラッグ中の 1 フレームだけ。
        // これを消すには `.updating` の中で中継を書くしかなく、上記の経路に乗って
        // ジェスチャが落ちる方が明確に悪いので、**遅れる側を選んでいる**。
        .onChange(of: trimDraft) { draft in
            trimPreviewRelay.update(makeTrimPreview(draft))
        }
    }

    // MARK: - クリップ

    @ViewBuilder
    private func clipView(_ layout: TimelineClipLayout) -> some View {
        let band = displayBand(layout)
        let width = geometry.width(forDuration: band.end - band.start)
        let isSelected = selectedClipID == layout.clipID
        let isReordering = reorderTranslation(layout) != nil

        ZStack(alignment: .topLeading) {
            thumbnailStrip(layout, band: band, width: width)
            // バッジと尺をサムネイルの上に読ませるための下敷き。**下端だけ**に敷く
            // （全面に敷くとコマの内容が沈む）。素のサムネの上に白文字を置くと、
            // 明るいコマで文字が消える。
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
                .frame(width: max(width, 2), height: TimelineMetrics.clipHeight)
                .allowsHitTesting(false)
            waveformOverlay(layout, band: band, width: width)
            badges(layout, width: width, duration: band.end - band.start)
        }
        .frame(width: max(width, 2), height: TimelineMetrics.clipHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius))
        // 選択の表現は**白 2pt 枠 + 両端の縦グリップ**（一般的な動画編集アプリの流儀）。
        // 黄色の枠は「速度バッジ・継ぎ目ボタン・挿入インジケータ」と同じ色で、
        // 選択されているのか属性が付いているのかが読めなかった。
        .overlay(
            RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius)
                .strokeBorder(isSelected ? TimelinePalette.selection : TimelinePalette.clipOutline,
                              lineWidth: isSelected ? 2 : 1)
        )
        .overlay(alignment: .leading) { if isSelected { trimHandle(.start, layout) } }
        .overlay(alignment: .trailing) { if isSelected { trimHandle(.end, layout) } }
        // 並べ替え中の 1 本だけを持ち上げる。透かすだけだと、掴んだ帯が
        // 下の帯と重なった瞬間にどちらを動かしているのか分からなくなる。
        .shadow(color: .black.opacity(isReordering ? 0.6 : 0.35),
                radius: isReordering ? 8 : 2, y: isReordering ? 4 : 1)
        .opacity(isReordering ? 0.85 : 1)
        .scaleEffect(isReordering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: isReordering)
        // **当たり判定と印は `.offset` より前に置くこと。** 後ろだと当たり判定が元の位置に
        // 取り残され、2 本目以降が「見えているのに触れない」（`TimelineClipSelectionUITests`）。
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = layout.clipID }
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityIdentifier("timeline.clip")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
        .offset(x: geometry.x(forTime: band.start)
                + geometry.x(forTime: reorderTranslation(layout) ?? 0))
        .zIndex(isReordering ? 2 : 0)
    }

    /// サムネイル列。**キャッシュ済みの画像だけを描く**（body から生成要求は出さない。
    /// 要求は親の `onAppear` / `onChange` からまとめて投入される）。
    ///
    /// 枠の配置は `TimelineThumbnailLayout.slots`（親の生成要求と共通の純関数）で決める。
    @ViewBuilder
    private func thumbnailStrip(_ layout: TimelineClipLayout,
                                band: (start: Double, end: Double),
                                width: Double) -> some View {
        if let clip = model.timeline.clips.first(where: { $0.id == layout.clipID }) {
            let slots = TimelineThumbnailLayout.slots(
                clip: previewClip(clip, layout: layout), spanStart: band.start,
                band: CompositionInterval(start: band.start, end: band.end),
                geometry: geometry,
                preferredSlotWidth: Double(TimelineMetrics.thumbnailSlotWidth),
                sourceDuration: model.sourceDuration(forClipID: layout.clipID))
            HStack(spacing: 0) {
                ForEach(0..<slots.count, id: \.self) { slot in
                    thumbnailSlot(layout, slots: slots, slot: slot)
                }
            }
            .frame(width: max(width, 2), height: TimelineMetrics.clipHeight, alignment: .leading)
            .clipped()
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: max(width, 2), height: TimelineMetrics.clipHeight)
        }
    }

    /// サムネイルのコマ出しに使う**下書き適用済み**クリップ。`slots` へは
    /// `spanStart: band.start` と対で渡して `bandOffset` を 0 に固定する
    /// （トランジションの重なりぶんは `sourceStart` へ畳む）。
    ///
    /// **これが無いと `.start` の外向きトリムで帯のコマと実際の映像が別物になる。**
    /// `.start` のプレビューは `band.start` を動かさず右端だけ伸ばすので `bandOffset` が
    /// 常に 0 のままで、帯には現行 `sourceStart` から**先**のコマが並ぶのに、確定後に
    /// 実際に入るのはそれより**前**の素材だった（`.end` 側だけ `sourceDuration` で
    /// 先読みする非対称な対策が入っていた）。
    func previewClip(_ clip: TimelineClip, layout: TimelineClipLayout) -> TimelineClip {
        var result = clip
        var bounds = (sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
        if let preview = trimPreview, preview.clipID == layout.clipID {
            bounds = (preview.sourceStart, preview.sourceEnd)
        }
        result.sourceStart = bounds.sourceStart + (layout.bandStart - layout.spanStart) * clip.rate
        result.sourceEnd = bounds.sourceEnd
        return result
    }

    @ViewBuilder
    private func thumbnailSlot(_ layout: TimelineClipLayout,
                               slots: TimelineThumbnailSlots,
                               slot: Int) -> some View {
        // 写真素材は全フレーム同一なので素材時刻 0 に丸めて 1 枚を使い回す。
        let time = model.timeline.clampedSourceTime(slots.sourceTimes[slot], sourceID: layout.sourceID)
        let slotWidth = CGFloat(slots.slotWidth)
        if let image = thumbnails.image(sourceID: layout.sourceID, sourceTime: time) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: slotWidth, height: TimelineMetrics.clipHeight)
                .clipped()
        } else {
            placeholderSlot(width: slotWidth)
        }
    }

    /// 未生成の枠。**黒一色にしない**（1 回の要求数には上限があり、上限で切り捨てられた枠が
    /// 「読み込み中」と区別できなくなる。薄いグレー + アイコンで「コマがまだ無い」と分かる形にする）。
    private func placeholderSlot(width: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.10))
            if width >= 24 {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .frame(width: width, height: TimelineMetrics.clipHeight)
    }

    // MARK: - トリム

    /// 端の縦グリップ（＝トリムハンドル）。**見た目は `handleWidth`、当たり判定は 44pt**。
    ///
    /// 判定だけを広げるのは、見た目まで 44pt にすると短いクリップが両端のハンドルで
    /// 埋まってサムネイルが見えなくなるため（適用区間の `edgeHandle` と同じ手当て）。
    /// 親に `.clipped()` が無いので、はみ出したぶんもヒットテストに載る。
    private func trimHandle(_ edge: TimelineTrimEdge, _ layout: TimelineClipLayout) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(TimelinePalette.selection)
            .frame(width: TimelineMetrics.handleWidth, height: TimelineMetrics.clipHeight)
            .overlay(
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 2, height: 20)
                    }
                }
            )
            .shadow(color: .black.opacity(0.45), radius: 2)
            .contentShape(Rectangle())
            // **当たり判定は自分のクリップの内側へだけ広げる。**
            //
            // 中央揃え（既定）にすると 44pt の判定がつまみ（20pt）の左右へ 12pt ずつ
            // はみ出し、**隣のクリップの上に乗る**。親に `.clipped()` が無いので
            // そのままヒットテストに載り、境界付近をタップしても隣のクリップの
            // `.onTapGesture` へ届かない ＝「分割したあと隣のクリップを選べない」に
            // なる（実機で確認）。つまみは自分の帯の端にあるので、内側へ寄せれば
            // 掴みやすさは変わらないまま越境だけが消える。
            .overlay(alignment: edge == .start ? .leading : .trailing) {
                Color.clear
                    .frame(width: TimelineMetrics.minimumTapTarget,
                           height: TimelineMetrics.clipHeight)
                    .contentShape(Rectangle())
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($trimDraft) { value, draft, _ in
                        if draft == nil { haptics.begin() }
                        let snapped = snappedTrimDelta(layout, edge: edge,
                                                       translation: value.translation.width)
                        haptics.report(snappedTo: snapped.snappedTo)
                        draft = TrimDraft(clipID: layout.clipID, edge: edge,
                                          deltaSeconds: snapped.delta)
                    }
                    .onEnded { value in
                        haptics.end()
                        // 中継は確定より**先**に畳む。モデル編集は同じフレームで反映されるので、
                        // 残したままだと移動済みのスパンにさらにリップル量が乗って 1 フレーム跳ねる
                        // （`@GestureState` のリセット待ちにしない）。onChange 側とは同値ガードで衝突しない。
                        trimPreviewRelay.update(nil)
                        let snapped = snappedTrimDelta(layout, edge: edge,
                                                       translation: value.translation.width)
                        onCommit(.trim(clipID: layout.clipID, edge: edge, deltaSeconds: snapped.delta))
                    }
            )
    }

    /// 描画用の帯区間。トリム下書き中は掴んだ帯を伸縮させ、**以降のクリップを同量シフト**する
    /// （リップル表示。`TimelineBandLayout.previewLayouts`）。**モデルは変更しない。**
    /// 入れないと内向きトリム中は空白の隙間が、外向き中は次クリップとの重なりが見える。
    private func displayBand(_ layout: TimelineClipLayout) -> (start: Double, end: Double) {
        guard let preview = trimPreview,
              let display = TimelineBandLayout.previewLayouts(
                layouts: layouts, trimmingClipID: preview.clipID, edge: preview.edge,
                effectiveDeltaSeconds: preview.effectiveDeltaSeconds)
                .first(where: { $0.clipID == layout.clipID }) else {
            return (layout.bandStart, layout.bandEnd)
        }
        return (display.bandStart, display.bandEnd)
    }

    /// トリム下書きに**クランプ**を掛けた表示用パラメータ
    /// （行き過ぎたドラッグが帯を素材の外へ伸ばして見せない）。
    ///
    /// **`.start` 側でも動くのは右端**。クリップは合成タイムライン上で突き合わせて並ぶので、
    /// start トリムでは左端（= 先行クリップの終端）は動かず、尺が縮んだぶん右端が縮んで
    /// 後続クリップが左へ寄る。左端を動かすプレビューにすると、指を離した瞬間に帯が
    /// ドラッグ量ぶん横へ飛ぶ（実測: preview (5.0, 8.0) に対し確定後は (4.0, 7.0)）。
    private var trimPreview: TimelineTrimPreview? { makeTrimPreview(trimDraft) }

    /// 下書き → 表示専用パラメータ。**中継（`onChange`）と自分の描画で同じ式を使う**
    /// （帯と適用区間が別の規則でリップルしないように）。
    private func makeTrimPreview(_ trimDraft: TrimDraft?) -> TimelineTrimPreview? {
        guard let draft = trimDraft,
              let clip = model.timeline.clips.first(where: { $0.id == draft.clipID }) else { return nil }
        let bounds = TimelineBandLayout.trimmedBounds(
            clip: clip, edge: draft.edge, deltaCompositionSeconds: draft.deltaSeconds,
            sourceDuration: model.sourceDuration(forClipID: draft.clipID))
        let effective = draft.edge == .start
            ? (bounds.sourceStart - clip.sourceStart) / clip.rate
            : (bounds.sourceEnd - clip.sourceEnd) / clip.rate
        return TimelineTrimPreview(clipID: draft.clipID, edge: draft.edge,
                                   effectiveDeltaSeconds: effective,
                                   sourceStart: bounds.sourceStart, sourceEnd: bounds.sourceEnd)
    }

    // MARK: - 並べ替え

    private func reorderTranslation(_ layout: TimelineClipLayout) -> Double? {
        guard let draft = reorderDraft, draft.clipID == layout.clipID else { return nil }
        return draft.translationSeconds
    }

    // MARK: - 長押し並べ替え（UIKit recognizer 由来）

    /// 長押し成立。掴んだクリップを決めて下書きを立てる。
    ///
    /// 対象を x から引くのは、recognizer を**帯全体に 1 個**にしたため
    /// （クリップごとに当て板を置くと、短いクリップで領域が消える・進行中に frame が
    /// 変わるといった旧実装の不安定さがそのまま残る）。
    private func beginReorder(at location: CGPoint) {
        guard let layout = reorderTarget(atContentX: Double(location.x)) else { return }
        reorderStartScrollOffset = autoScroll.scrollOffset
        reorderDraft = ReorderDraft(clipID: layout.clipID, translationSeconds: 0)
        if selectedClipID != layout.clipID { selectedClipID = layout.clipID }
        haptics.longPressImpact()
        autoScroll.updateDrag(fingerX: Double(location.x) - autoScroll.scrollOffset)
    }

    /// 成立後の移動。吸着を掛けた差分を下書きへ、指の x を自動スクロールへ渡す。
    private func updateReorder(translation: CGSize, location: CGPoint) {
        guard let draft = reorderDraft,
              let layout = layouts.first(where: { $0.id == draft.clipID }) else { return }
        let snapped = snappedReorder(layout, translationPixels: Double(translation.width))
        haptics.report(snappedTo: snapped.snappedTo)
        reorderDraft = ReorderDraft(clipID: layout.clipID, translationSeconds: snapped.translation)
        // 自動スクロールの入力は**可視領域左端からの x**。帯の x はトラック内 x なので
        // スクロール量を引く（`TimelineAutoScrollState.fingerX` の契約）。
        autoScroll.updateDrag(fingerX: Double(location.x) - autoScroll.scrollOffset)
    }

    /// 終了・中断のどちらでも必ず片付ける（中断で下書きが残ると自動スクロールが走り続ける）。
    private func finishReorder(translation: CGSize, committed: Bool) {
        let draft = reorderDraft
        reorderDraft = nil
        autoScroll.endDrag()
        haptics.end()
        defer { reorderStartScrollOffset = nil }
        guard committed, let draft,
              let layout = layouts.first(where: { $0.id == draft.clipID }) else { return }
        onCommit(.reorder(clipID: layout.clipID,
                          translationSeconds: snappedReorder(
                            layout, translationPixels: Double(translation.width)).translation))
    }

    /// 長押しが乗ったクリップ。**両端 `reorderInset` は対象から外す**
    /// （選択時にトリムハンドルが載る場所。ここで並べ替えが成立すると、ハンドルの
    /// 真上を掴んだつもりで並べ替えが始まる）。
    private func reorderTarget(atContentX x: Double) -> TimelineClipLayout? {
        let time = geometry.time(forX: x)
        guard let layout = layouts.first(where: { time >= $0.bandStart && time < $0.bandEnd }) else {
            return nil
        }
        let inset = geometry.duration(forWidth: Double(TimelineMetrics.reorderInset))
        let band = displayBand(layout)
        guard time >= band.start + inset, time < band.end - inset else { return nil }
        return layout
    }

    /// 指の移動量（px）を、自動スクロールぶんを足し戻して合成時刻の差分にする。
    private func translationSeconds(_ pixels: Double) -> Double {
        let scrolled = autoScroll.scrollOffset - (reorderStartScrollOffset ?? autoScroll.scrollOffset)
        return geometry.time(forX: pixels + scrolled)
    }

    // MARK: - 挿入位置インジケータ

    /// 並べ替えドラッグ中に、確定したら挿入される境界へ引く縦線。
    ///
    /// 位置は確定と**同じ純関数**（`TimelineBandLayout.reorderTargetIndex`）から引く
    /// （見えている線と実際の挿入先が別の規則で決まらないようにする）。
    /// `moveClip` は「抜いてから index へ差し込む」ので、前へ動かすなら対象帯の左端、
    /// 後ろへ動かすなら対象帯の右端が境界になる。
    @ViewBuilder
    private var insertionIndicator: some View {
        if let x = insertionX {
            Rectangle()
                .fill(TimelinePalette.structure)
                .frame(width: 2, height: TimelineMetrics.clipHeight)
                // 上下端の小さな爪。線だけだと、掴んだ帯の縁と見分けが付かない。
                .overlay(alignment: .top) { insertionCap }
                .overlay(alignment: .bottom) { insertionCap }
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: x - 1)
                .allowsHitTesting(false)
                .zIndex(3)
        }
    }

    private var insertionCap: some View {
        Circle()
            .fill(TimelinePalette.structure)
            .frame(width: 6, height: 6)
    }

    private var insertionX: Double? {
        guard let draft = reorderDraft,
              let source = layouts.first(where: { $0.clipID == draft.clipID }),
              let target = TimelineBandLayout.reorderTargetIndex(
                layouts: layouts, clipID: draft.clipID,
                translationSeconds: draft.translationSeconds),
              target != source.index,
              let destination = layouts.first(where: { $0.index == target }) else { return nil }
        return geometry.x(forTime: target < source.index ? destination.bandStart : destination.bandEnd)
    }
}

// MARK: - 吸着

private extension TimelineClipBandView {
    /// トリムのドラッグ量に吸着を掛けて合成時刻の差分へ戻す。掴んだ端の絶対時刻を基準にする。
    func snappedTrimDelta(_ layout: TimelineClipLayout, edge: TimelineTrimEdge,
                          translation: CGFloat) -> (delta: Double, snappedTo: Double?) {
        snappedDelta(anchor: edge == .start ? layout.bandStart : layout.bandEnd,
                     raw: geometry.time(forX: Double(translation)), layout: layout,
                     neighbourIndex: edge == .start ? layout.index - 1 : layout.index + 1)
    }

    /// 並べ替えの移動量に吸着を掛ける（掴んだ帯の**左端**が候補に吸い付く）。
    /// 表示（ゴースト帯・挿入インジケータ）と確定は**同じ吸着後の値**を使う。
    func snappedReorder(_ layout: TimelineClipLayout,
                        translationPixels: Double) -> (translation: Double, snappedTo: Double?) {
        let snapped = snappedDelta(anchor: layout.bandStart, raw: translationSeconds(translationPixels),
                                   layout: layout, neighbourIndex: layout.index - 1)
        return (snapped.delta, snapped.snappedTo)
    }

    /// 掴んだ端の絶対時刻（`anchor + raw`）に吸着を掛け、差分へ戻す。
    ///
    /// **順序は「吸着 → クランプ」**（逆にすると吸着結果がクランプで壊れる。`TimelineSnap` の
    /// doc 参照）。ここは吸着だけを行い、クランプは `trimPreview`（表示）と
    /// `MosaicEditorModel`（確定）が担う。許容量は **px 由来**にしてズーム段によらず
    /// 指の感覚を一定にする。
    ///
    /// 掴んだクリップに加えて `neighbourIndex` のクリップも候補から外す。帯は接しているので
    /// 片方だけでは継ぎ目の時刻が候補に残り、差分 0 に貼り付いて小さな操作が一切できなくなる
    /// （`TimelineSnap.candidates` の注意書き参照）。
    func snappedDelta(anchor: Double, raw: Double, layout: TimelineClipLayout,
                      neighbourIndex: Int) -> (delta: Double, snappedTo: Double?) {
        var excluded: Set<UUID> = [layout.clipID]
        if let neighbour = layouts.first(where: { $0.index == neighbourIndex }) {
            excluded.insert(neighbour.clipID)
        }
        let result = TimelineSnap.snapped(
            time: anchor + raw,
            candidates: TimelineSnap.candidates(layouts: layouts, applySpans: applySpans,
                                                playheadTime: playheadTime,
                                                totalDuration: totalDuration, excluding: excluded),
            tolerance: geometry.duration(forWidth: TimelineSnap.defaultTolerancePixels))
        return (result.time - anchor, result.snappedTo)
    }
}
