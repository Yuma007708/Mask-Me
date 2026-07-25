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
    @GestureState private var reorderDraft: ReorderDraft?
    /// 長押しが成立しているか（並べ替えの開始振動用）。
    @GestureState private var isReorderPressing = false
    /// 吸着ハプティクスの前回値保持。**参照型を `@State` に入れる**
    /// （`TimelineSnapHaptics` の doc 参照）。
    @State private var haptics = TimelineSnapHaptics()
    /// 並べ替えジェスチャ開始時のスクロール量（px）。
    ///
    /// `DragGesture.translation` は**指の移動量**なので、ドラッグ中に自動スクロールが
    /// 走るとコンテンツと指の相対関係が崩れる。確定・プレビューには
    /// 「指の移動量 + （現在のスクロール量 − 開始時のスクロール量）」を使う。
    @State private var reorderStartScrollOffset: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.06)
                .frame(height: TimelineMetrics.clipHeight)
                // 帯の空白タップで選択解除（目盛り帯には付けない。あちらは
                // `DragGesture(minimumDistance: 0)` がタップも拾うスクラブ帯なので誤爆する）。
                .contentShape(Rectangle())
                .onTapGesture { selectedClipID = nil }
            ForEach(layouts) { layout in
                clipView(layout)
            }
            insertionIndicator
        }
        .frame(height: TimelineMetrics.clipHeight, alignment: .topLeading)
        // ジェスチャのキャンセル（横スクロールへの奪取など）でも必ず後始末する。
        // `onEnded` は中断で呼ばれないので、そこだけに頼ると自動スクロールが走り続ける。
        .onChange(of: reorderDraft) { draft in
            guard draft == nil else { return }
            reorderStartScrollOffset = nil
            autoScroll.endDrag()
        }
        // 長押し成立（並べ替え開始）で 1 回だけ振動させる。`@GestureState` 由来なので
        // 中断でも false へ戻り、次の長押しでまた鳴る。
        .onChange(of: isReorderPressing) { active in
            if active { haptics.longPressImpact() } else { haptics.end() }
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
            badges(layout)
        }
        .frame(width: max(width, 2), height: TimelineMetrics.clipHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius)
                .strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.25),
                              lineWidth: isSelected ? 2 : 0.5)
        )
        .overlay(alignment: .leading) { if isSelected { trimHandle(.start, layout) } }
        .overlay(alignment: .trailing) { if isSelected { trimHandle(.end, layout) } }
        // 並べ替えの判定領域は**トリムハンドルを除いた中央**に限る。
        // 親クリップ全体に長押しシークエンスを付けると、静止した長押しでは
        // ハンドル側（`DragGesture(minimumDistance: 1)`）が認識対象にならず、
        // ハンドルの真上でも並べ替えが成立し得る。
        .overlay(alignment: .center) { reorderArea(layout, width: width) }
        .opacity(isReordering ? 0.75 : 1)
        .offset(x: geometry.x(forTime: band.start)
                + geometry.x(forTime: reorderTranslation(layout) ?? 0))
        .zIndex(isReordering ? 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = layout.clipID }
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
    private func previewClip(_ clip: TimelineClip, layout: TimelineClipLayout) -> TimelineClip {
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

    @ViewBuilder
    private func badges(_ layout: TimelineClipLayout) -> some View {
        let clip = model.timeline.clips.first { $0.id == layout.clipID }
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if model.timeline.sourceKind(of: layout.sourceID) == .photo {
                    badgeLabel("写真")
                }
                if let clip, abs(clip.rate - 1) > 1e-6 {
                    badgeLabel(String(format: "%.2gx", clip.rate))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(3)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - トリム

    private func trimHandle(_ edge: TimelineTrimEdge, _ layout: TimelineClipLayout) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: TimelineMetrics.handleWidth, height: TimelineMetrics.clipHeight)
            .overlay(
                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 2, height: 16)
            )
            .contentShape(Rectangle())
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

    /// 並べ替えジェスチャの判定領域（トリムハンドルぶんを左右から除く）。
    ///
    /// **inset を選択状態に依存させない。** `reorderGesture.onChanged` が
    /// `selectedClipID` を書くと同じ body 評価で `isSelected` が true になり、
    /// 「ジェスチャ進行中に、そのジェスチャが乗っているビューの frame が縮む」という
    /// 構造的に不安定な形になっていた（指がハンドル領域に入るとジェスチャが途切れ得る）。
    /// 非選択時に両端 14pt が並べ替え領域から外れる副作用は、そこがトリムハンドルの
    /// 位置であり、タップでの選択は下の `simultaneousGesture` が拾うので実害がない。
    private func reorderArea(_ layout: TimelineClipLayout, width: Double) -> some View {
        let inset = TimelineMetrics.handleWidth * 2
        return Color.clear
            .frame(width: max(CGFloat(width) - inset, 1), height: TimelineMetrics.clipHeight)
            .contentShape(Rectangle())
            .gesture(reorderGesture(layout))
            // 親（クリップ本体）のタップ到達性に依存せず選択できるようにする。
            .simultaneousGesture(TapGesture().onEnded { selectedClipID = layout.clipID })
    }

    /// 長押し（0.3 秒）してからのドラッグだけを並べ替えとして扱う。
    /// 素のドラッグは ScrollView の横スクロールに残す。
    ///
    /// ドラッグ量はスクロールビューの座標系（`TimelineCoordinateSpace.scroll`）で受ける。
    /// `translation` は**指の移動量**なので、自動スクロールで動いたぶんを
    /// `reorderStartScrollOffset` との差分で足し戻す。
    private func reorderGesture(_ layout: TimelineClipLayout) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0,
                                           coordinateSpace: .named(TimelineCoordinateSpace.scroll)))
            .updating($reorderDraft) { value, draft, _ in
                guard case let .second(true, drag) = value else { return }
                let snapped = snappedReorder(layout, drag)
                haptics.report(snappedTo: snapped.snappedTo)
                draft = ReorderDraft(clipID: layout.clipID,
                                     translationSeconds: snapped.translation)
            }
            .updating($isReorderPressing) { value, pressing, _ in
                switch value {
                case .first(true), .second: pressing = true
                default: break
                }
            }
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if reorderStartScrollOffset == nil { reorderStartScrollOffset = autoScroll.scrollOffset }
                // ドラッグ中に 60Hz で @State を書かないよう、未選択のときだけ書く。
                if selectedClipID != layout.clipID { selectedClipID = layout.clipID }
                guard let drag else { return }
                autoScroll.updateDrag(fingerX: Double(drag.location.x))
            }
            .onEnded { value in
                autoScroll.endDrag()
                defer { reorderStartScrollOffset = nil }
                guard case let .second(true, drag) = value, let drag else { return }
                onCommit(.reorder(clipID: layout.clipID,
                                  translationSeconds: snappedReorder(layout, drag).translation))
            }
    }

    /// 指の移動量（px）を、自動スクロールぶんを足し戻して合成時刻の差分にする。
    private func translationSeconds(_ drag: DragGesture.Value?) -> Double {
        guard let drag else { return 0 }
        let scrolled = autoScroll.scrollOffset - (reorderStartScrollOffset ?? autoScroll.scrollOffset)
        return geometry.time(forX: Double(drag.translation.width) + scrolled)
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
                .fill(Color.yellow)
                .frame(width: 2, height: TimelineMetrics.clipHeight)
                .offset(x: x - 1)
                .allowsHitTesting(false)
                .zIndex(3)
        }
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
                        _ drag: DragGesture.Value?) -> (translation: Double, snappedTo: Double?) {
        let snapped = snappedDelta(anchor: layout.bandStart, raw: translationSeconds(drag),
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
