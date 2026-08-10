import MosaicCore
import SwiftUI

/// タイムラインの「レイヤー段」の器（`VideoTimelineView` の一部）。
///
/// 本体から切り出してあるのは行数の都合だが、境界は意味とも合っている:
/// **ここに入るのは動画クリップより上に載る段だけ**で、クリップ帯・目盛り・
/// プレイヘッド（＝時間軸そのものの表現）は本体に残る。
extension VideoTimelineView {
    /// レイヤー段の器（モザイク・音声・テキスト…）。
    ///
    /// **高さは段数によらず固定**（`TimelineMetrics.layerViewportHeight`）で、
    /// はみ出したぶんは縦スクロールで辿る。段が増えるたびに背が伸びると、
    /// そのぶん必ずプレビューが縮む——それを避けるための器である。
    ///
    /// 動画クリップの段はこの中に**入れない**（VLLO と同じで常に見えている）。
    var layerViewport: some View {
        VStack(spacing: TimelineMetrics.trackSpacing) {
            ForEach(TimelineLayerRowKind.allCases) { kind in
                layerRow(kind)
            }
        }
        .offset(y: -layerScrollOffset)
        .frame(width: contentWidth, height: TimelineMetrics.layerViewportHeight,
               alignment: .top)
        .clipped()
        // 段の上での縦ドラッグは一覧の上下送り。**横スクロール（＝シーク）は
        // 押した時点で止める**（`blocksTimelinePan`）ので、縦に払ったつもりが
        // シークになることはない。
        .blocksTimelinePan(autoScroll)
        // **`.highPriorityGesture` にしてはいけない。**
        //
        // `highPriorityGesture` は名前のとおり「そのジェスチャを優先する」修飾で、
        // **親に付けると子のジェスチャより先に成立する**（深い方が勝つ、ではない）。
        // ここを高優先度にしていた間、段の上のドラッグはすべてこの段送りが先に取り、
        // 子（区間の移動・端つまみの伸縮）へは一切届いていなかった。
        // この段送りは `|dy| > |dx|` のときしか何もしないので、**横方向のドラッグは
        // 取られたまま捨てられる** ＝「つまみを掴んでも長さが変わらない」
        // 「帯を掴んでも動かない」という無言の失敗になる（実機・実機 UI テストで確認）。
        //
        // 通常の `.gesture` なら子が先に取り、子が取らなかったタッチだけがここへ来る。
        // 横スクロール（＝シーク）との競合は上の `blocksTimelinePan` が押下時点で
        // 止めているので、優先度を下げてもシークに漏れることはない。
        .gesture(layerScrollGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.layerStack")
    }

    @ViewBuilder
    func layerRow(_ kind: TimelineLayerRowKind) -> some View {
        switch kind {
        case .mosaic:
            if applySpans.isEmpty {
                // 区間 0 本＝まだ掛けていない。空段として「置ける場所」を見せる
                // （新規編集でレイヤーを出さない仕様の受け皿。押すと顔モザイクが入る）。
                TimelineEmptyLayerRow(kind: .mosaic, width: contentWidth) {
                    // 顔モザイクの段へ入る。**入った時点で区間が確保される**
                    // （`applyRouteSideEffects` → `setEffectOn` → `ensureApplyRangesExist`）
                    // ので、この段はタップした直後に中身のある帯へ変わる。
                    model.enterDock(.face)
                }
            } else {
                TimelineLayerTrackView(
                    geometry: geometry, spans: applySpans, totalDuration: totalDuration,
                    layouts: clipLayouts, playheadTime: playheadTime,
                    trimPreviewRelay: trimPreviewRelay,
                    selectedRangeID: rangeSelection, onCommit: commit,
                    onVerticalDrag: updateLayerScroll(translationHeight:),
                    onVerticalDragEnded: endLayerScrollDrag)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.applyTrack")
            }
        case .audio, .text:
            // **器だけ。** 中身（音声の取り込み・テキストの描画）は未実装なので
            // 押しても何もしない。段を出すのは「ここに置ける」を見せるため。
            TimelineEmptyLayerRow(kind: kind, width: contentWidth, onTap: nil)
        }
    }

    /// 段の縦送り。慣性もラバーバンドも付けない（`TimelineLayerScrollMath` の doc）。
    var layerScrollGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // 横に払っているなら段を動かさない（シークの邪魔をしない）。
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                updateLayerScroll(translationHeight: value.translation.height)
            }
            .onEnded { _ in endLayerScrollDrag() }
    }

    /// 段の縦送りの実体（`layerScrollGesture` と `TimelineLayerTrackView` の本体ドラッグの
    /// 両方から呼ぶ）。
    ///
    /// モザイク段の上で始まった本体ドラッグ（区間の移動）は `TimelineLayerTrackView` 自身が
    /// `.highPriorityGesture` で先取りするため（端ハンドルと同じ配線。doc 参照）、
    /// 祖先の `layerScrollGesture` はその領域のタッチを一切受け取れない。縦方向に確定した
    /// ときだけこの関数へ中継してもらうことで、段送りの見え方を 1 箇所（この関数と
    /// `TimelineLayerScrollMath`）に保ったまま、モザイク段の上でも縦送りを効かせる。
    func updateLayerScroll(translationHeight: CGFloat) {
        layerScrollOffset = TimelineLayerScrollMath.clampedOffset(
            layerScrollDragBase - Double(translationHeight),
            viewport: layerViewportMetrics)
    }

    /// 段の縦送りドラッグの確定（次のドラッグの基準点を更新するだけ）。
    func endLayerScrollDrag() {
        layerScrollDragBase = layerScrollOffset
    }

    var layerViewportMetrics: TimelineLayerViewport {
        TimelineLayerViewport(
            contentHeight: TimelineLayerScrollMath.contentHeight(
                rowHeights: TimelineLayerRowKind.allCases.map { _ in Double(TimelineMetrics.layerRowHeight) },
                spacing: Double(TimelineMetrics.trackSpacing)),
            visibleHeight: Double(TimelineMetrics.layerViewportHeight))
    }
}
