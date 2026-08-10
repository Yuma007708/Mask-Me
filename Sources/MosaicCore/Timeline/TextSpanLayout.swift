import Foundation

/// テキスト（`TextItem`）を段のセグメントへ写す層（E3）。
///
/// `TimelineViewGeometry.swift` が file_length の閾値に張り付いているため分けてある。
/// 中身は `TimelineBandLayout` の一部で、`audioSpans`（`AudioSpanLayout.swift`）と
/// **同じ合成時刻アンカーの流儀**である。
extension TimelineBandLayout {
    /// テキストを段のセグメントへ写す（表示用。E3）。
    ///
    /// **写像はほぼ恒等である**（テキストは合成時刻アンカーなので、`compositionStart` が
    /// そのまま帯の位置になる）。それでも `applySpans` / `audioSpans` と同じ型を返すのは、
    /// 段の View（`TimelineLayerTrackView`）を種に依存しない汎用トラックのまま使うためである。
    ///
    /// **`totalDuration` で切ること。** 生の `textItems` をそのまま渡すと、クリップを
    /// 消して縮んだタイムラインの外へ帯が伸びる（`TimelineState.effectiveTextItems`
    /// と同じ規則。実効だけを見せる）。
    ///
    /// `anchorClipID` は必ず nil（テキストはクリップに属さない）。端の伸縮・移動は
    /// どちらも可能なので `isEdgeAdjustable` は常に true。テキストは BGM と違って
    /// **重なってよい**が、それは正規化（`TimelineState.normalizedTextItems`）側の話で、
    /// この写像自体は重なりを気にしない（複数の帯が同じ x 座標へ出るだけ）。
    public static func textSpans(items: [TextItem],
                                 totalDuration: Double) -> [TimelineApplySpan] {
        items.compactMap { item in
            guard let clipped = item.clipped(toTotalDuration: totalDuration) else { return nil }
            return TimelineApplySpan(rangeID: clipped.id,
                                     anchorClipID: nil,
                                     kind: .text,
                                     start: clipped.compositionStart,
                                     end: clipped.compositionEnd,
                                     isEdgeAdjustable: true)
        }
    }
}
