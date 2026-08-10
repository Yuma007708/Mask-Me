import Foundation

/// BGM を段のセグメントへ写す層（E2）。
///
/// `TimelineViewGeometry.swift` が file_length の閾値に張り付いているため分けてある。
/// 中身は `TimelineBandLayout` の一部で、`applySpans`（素材時刻アンカー）と対になる
/// **合成時刻アンカー版**である。
extension TimelineBandLayout {
    /// BGM を段のセグメントへ写す（表示用。E2）。
    ///
    /// **写像はほぼ恒等である**（BGM は合成時刻アンカーなので、`compositionStart` が
    /// そのまま帯の位置になる）。それでも `applySpans` と同じ型を返すのは、段の View
    /// （`TimelineLayerTrackView`）を種に依存しない汎用トラックのまま使うためである。
    ///
    /// **`totalDuration` で切ること。** 生の `audioItems` をそのまま渡すと、クリップを
    /// 消して縮んだタイムラインの外へ帯が伸びる（`TimelineState.effectiveAudioItems`
    /// と同じ規則。実効だけを見せる）。
    ///
    /// `anchorClipID` は必ず nil（BGM はクリップに属さない）。端の伸縮・移動は
    /// どちらも可能なので `isEdgeAdjustable` は常に true。
    public static func audioSpans(items: [AudioItem],
                                  totalDuration: Double) -> [TimelineApplySpan] {
        items.compactMap { item in
            guard let clipped = item.clipped(toTotalDuration: totalDuration) else { return nil }
            return TimelineApplySpan(rangeID: clipped.id,
                                     anchorClipID: nil,
                                     kind: .audio,
                                     start: clipped.compositionStart,
                                     end: clipped.compositionEnd,
                                     isEdgeAdjustable: true)
        }
    }
}
