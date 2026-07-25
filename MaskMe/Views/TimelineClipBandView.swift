import MosaicCore
import SwiftUI

/// タイムラインの寸法（全トラックで共有。x 座標系を揃えるため 1 箇所に置く）。
enum TimelineMetrics {
    static let rulerHeight: CGFloat = 16
    static let clipHeight: CGFloat = 52
    static let applyTrackHeight: CGFloat = 18
    static let trackSpacing: CGFloat = 4
    /// トリムハンドルの幅（ドラッグ判定領域も兼ねる）。
    static let handleWidth: CGFloat = 14
    /// サムネイル 1 枚が占める幅。
    static let thumbnailSlotWidth: CGFloat = 44
    /// 継ぎ目ボタンの一辺。
    static let jointButtonSize: CGFloat = 22
    static let cornerRadius: CGFloat = 4

    static var stackHeight: CGFloat {
        rulerHeight + clipHeight + applyTrackHeight + trackSpacing * 2
    }
}

/// ジェスチャの**確定**（`onEnded`）で親へ渡す編集内容。
///
/// **ジェスチャ中はモデルを一切変更しない**。進行中の下書きは各トラックの
/// `@GestureState`（`TimelineClipBandView.TrimDraft` / `ReorderDraft` /
/// `TimelineApplyTrackView.ApplyDraft`）が持ち、描画専用に使う。
/// `@GestureState` はジェスチャがキャンセルされると**自動で初期値に戻る**ため、
/// 「中断で下書きが取り残されて帯が伸びたまま」という状態が原理的に作れない
/// （`@State` に持たせていた S9 初版は、横スクロールでの中断だけ回収経路が無かった）。
/// 確定は `onEnded` の 1 回だけで、そこから親がモデルの編集 API を呼ぶ。
enum TimelineInteraction: Equatable {
    /// クリップ端のトリム（`deltaSeconds` は合成時刻の差分）。
    case trim(clipID: UUID, edge: TimelineTrimEdge, deltaSeconds: Double)
    /// 長押しドラッグでの並べ替え（`translationSeconds` は合成時刻の差分）。
    case reorder(clipID: UUID, translationSeconds: Double)
    /// モザイク適用区間の端ドラッグ（合成時刻の絶対区間）。
    /// `clipID` はどのセグメントを掴んでいるかの識別（1 本の区間は複数クリップに
    /// またがって複数セグメントに見えるため）。確定もこのセグメント単位で行う。
    case applyEdge(rangeID: UUID, clipID: UUID, start: Double, end: Double)
}

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
    let joints: [TimelineJointLayout]
    @Binding var selectedClipID: UUID?
    /// ジェスチャ確定（`onEnded`）の通知。モデルの編集はすべて親が行う。
    let onCommit: (TimelineInteraction) -> Void
    /// 継ぎ目ボタンのタップ（引数は先行クリップの id）。
    let onJointTap: (UUID) -> Void

    @GestureState private var trimDraft: TrimDraft?
    @GestureState private var reorderDraft: ReorderDraft?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.06)
                .frame(height: TimelineMetrics.clipHeight)
            ForEach(layouts) { layout in
                clipView(layout)
            }
            ForEach(joints) { joint in
                jointButton(joint)
            }
        }
        .frame(height: TimelineMetrics.clipHeight, alignment: .topLeading)
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
        .overlay(alignment: .center) { reorderArea(layout, width: width, isSelected: isSelected) }
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
                clip: clip, spanStart: layout.spanStart,
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
                        draft = TrimDraft(clipID: layout.clipID, edge: edge,
                                          deltaSeconds: geometry.time(forX: value.translation.width))
                    }
                    .onEnded { value in
                        onCommit(.trim(clipID: layout.clipID, edge: edge,
                                       deltaSeconds: geometry.time(forX: value.translation.width)))
                    }
            )
    }

    /// 描画用の帯区間。トリム中は**クランプ後の**実効差分を反映する
    /// （行き過ぎたドラッグが帯を素材の外へ伸ばして見せない）。
    ///
    /// **`.start` 側でも動くのは右端**。クリップは合成タイムライン上で突き合わせて並ぶので、
    /// start トリムでは左端（= 先行クリップの終端）は動かず、尺が縮んだぶん右端が縮んで
    /// 後続クリップが左へ寄る。左端を動かすプレビューにすると、指を離した瞬間に帯が
    /// ドラッグ量ぶん横へ飛ぶ（実測: preview (5.0, 8.0) に対し確定後は (4.0, 7.0)）。
    private func displayBand(_ layout: TimelineClipLayout) -> (start: Double, end: Double) {
        guard let draft = trimDraft, draft.clipID == layout.clipID,
              let clip = model.timeline.clips.first(where: { $0.id == draft.clipID }) else {
            return (layout.bandStart, layout.bandEnd)
        }
        let bounds = TimelineBandLayout.trimmedBounds(
            clip: clip, edge: draft.edge, deltaCompositionSeconds: draft.deltaSeconds,
            sourceDuration: model.sourceDuration(forClipID: draft.clipID))
        switch draft.edge {
        case .start:
            let effective = (bounds.sourceStart - clip.sourceStart) / clip.rate
            return (layout.bandStart, max(layout.bandEnd - effective, layout.bandStart))
        case .end:
            let effective = (bounds.sourceEnd - clip.sourceEnd) / clip.rate
            return (layout.bandStart, max(layout.bandEnd + effective, layout.bandStart))
        }
    }

    // MARK: - 並べ替え

    private func reorderTranslation(_ layout: TimelineClipLayout) -> Double? {
        guard let draft = reorderDraft, draft.clipID == layout.clipID else { return nil }
        return draft.translationSeconds
    }

    /// 並べ替えジェスチャの判定領域（選択中はトリムハンドルぶんを左右から除く）。
    private func reorderArea(_ layout: TimelineClipLayout,
                             width: Double,
                             isSelected: Bool) -> some View {
        let inset = isSelected ? TimelineMetrics.handleWidth * 2 : 0
        return Color.clear
            .frame(width: max(CGFloat(width) - inset, 1), height: TimelineMetrics.clipHeight)
            .contentShape(Rectangle())
            .gesture(reorderGesture(layout))
    }

    /// 長押し（0.3 秒）してからのドラッグだけを並べ替えとして扱う。
    /// 素のドラッグは ScrollView の横スクロールに残す。
    private func reorderGesture(_ layout: TimelineClipLayout) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($reorderDraft) { value, draft, _ in
                guard case let .second(true, drag) = value else { return }
                let dx = Double(drag?.translation.width ?? 0)
                draft = ReorderDraft(clipID: layout.clipID,
                                     translationSeconds: geometry.time(forX: dx))
            }
            .onChanged { value in
                guard case .second(true, _) = value else { return }
                selectedClipID = layout.clipID
            }
            .onEnded { value in
                guard case let .second(true, drag) = value, let drag else { return }
                onCommit(.reorder(clipID: layout.clipID,
                                  translationSeconds: geometry.time(forX: Double(drag.translation.width))))
            }
    }

    // MARK: - 継ぎ目（トランジション）

    private func jointButton(_ joint: TimelineJointLayout) -> some View {
        let size = TimelineMetrics.jointButtonSize
        return Button {
            onJointTap(joint.outgoingClipID)
        } label: {
            Image(systemName: joint.kind == nil ? "plus" : "square.on.square.dashed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(joint.kind == nil ? Color.white.opacity(0.85) : Color.yellow)
                )
        }
        .buttonStyle(.plain)
        .offset(x: geometry.x(forTime: joint.time) - size / 2,
                y: (TimelineMetrics.clipHeight - size) / 2)
        .zIndex(3)
    }
}
