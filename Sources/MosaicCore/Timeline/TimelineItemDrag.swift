import Foundation

/// 適用区間ドラッグの種別。端の伸縮か、区間全体の移動か。
public enum TimelineItemDragKind: Equatable, Sendable {
    /// 端（`start` / `end`）だけを伸縮する。
    case edge(TimelineTrimEdge)
    /// 区間全体を平行移動する（両端が同じ量だけ動く）。
    case move
}

/// ドラッグ下書きの結果（合成時刻の区間）。
public struct TimelineItemDragResult: Equatable, Sendable {
    public let start: Double
    public let end: Double
    /// 吸着先。`nil` なら未吸着。
    ///
    /// **ハプティクスは「`snappedTo` が前回と変わったとき」だけ鳴らす**こと
    /// （`TimelineSnapResult.snappedTo` と同じ注意）。
    public let snappedTo: Double?

    public init(start: Double, end: Double, snappedTo: Double?) {
        self.start = start
        self.end = end
        self.snappedTo = snappedTo
    }
}

/// `TimelineItemDrag.snappedDraft` が吸着候補・クランプ範囲を作るのに要る周辺情報。
///
/// View 側のドラッグハンドラは毎フレーム同じ値を使い回す（`span` と
/// `translationPixels` だけがフレームごとに変わる）ため、まとめて1つの値として渡す。
public struct TimelineItemDragContext: Sendable {
    public let geometry: TimelineGeometry
    /// 吸着候補（クリップ帯の両端）と、`.move` の移動可能域（掴んだクリップの帯）の材料。
    public let layouts: [TimelineClipLayout]
    /// 吸着候補（適用区間の両端）の材料。
    public let applySpans: [TimelineApplySpan]
    public let playheadTime: Double
    public let totalDuration: Double

    public init(geometry: TimelineGeometry,
                layouts: [TimelineClipLayout],
                applySpans: [TimelineApplySpan],
                playheadTime: Double,
                totalDuration: Double) {
        self.geometry = geometry
        self.layouts = layouts
        self.applySpans = applySpans
        self.playheadTime = playheadTime
        self.totalDuration = totalDuration
    }
}

/// タイムライン適用区間のドラッグ算術（純ロジック）。
///
/// `TimelineApplyTrackView.snappedDraft` から抜き出した。View 側は
/// 「translation（px）→ delta（秒）→ 吸着 → クランプ → 最小尺保証」を毎フレーム
/// 呼ぶだけの薄い層にし、算術そのものはここへ閉じ込める。
public enum TimelineItemDrag {
    /// 端ドラッグで潰さない最小の合成尺（秒）。
    public static let defaultMinimumSpan: Double = 0.1

    /// ドラッグ量から確定候補の合成時刻区間を作る。
    ///
    /// **順序は「吸着 → クランプ」**（逆にすると吸着結果がクランプで壊れる。
    /// `TimelineSnap` の doc 参照）。適用区間の端はもともと絶対時刻なので素直に挟める。
    /// 許容量は **px 由来**にしてズーム段によらず指の感覚を一定にする。
    /// 候補からは掴んでいる区間（`span.rangeID`）だけを外す（クリップ帯の端は候補に残す。
    /// 適用区間をクリップ境界へ合わせるのが最も多い操作なので）。
    ///
    /// - Parameter isEdgeAdjustable == false: 写真クリップ由来のセグメント。伸縮・移動とも
    ///   no-op（入力をそのまま返す）。写真の素材時刻は常に 0 へ丸められるため、動かしても
    ///   確定時に必ず元へ戻る（`TimelineApplySpan.isEdgeAdjustable` の doc 参照）。
    /// - Parameter kind: `.move` の可動域は**アンカーで決まる**。素材時刻アンカー
    ///   （`span.anchorClipID != nil`。モザイク適用区間）は属するクリップの合成区間に
    ///   閉じ、帯が見つからなければ移動不可として入力をそのまま返す。合成時刻アンカー
    ///   （`anchorClipID == nil`。BGM）は**タイムライン全体**が可動域になる。
    public static func snappedDraft(span: TimelineApplySpan,
                                    kind: TimelineItemDragKind,
                                    translationPixels: Double,
                                    context: TimelineItemDragContext,
                                    minimumSpan: Double = defaultMinimumSpan) -> TimelineItemDragResult {
        guard span.isEdgeAdjustable else {
            return TimelineItemDragResult(start: span.start, end: span.end, snappedTo: nil)
        }

        let geometry = context.geometry
        let layouts = context.layouts
        let totalDuration = context.totalDuration
        let delta = geometry.time(forX: translationPixels)
        let candidates = TimelineSnap.candidates(layouts: layouts, applySpans: context.applySpans,
                                                 playheadTime: context.playheadTime, totalDuration: totalDuration,
                                                 excluding: [span.rangeID])
        let tolerance = geometry.duration(forWidth: TimelineSnap.defaultTolerancePixels)

        switch kind {
        case .edge(.start):
            let snapped = TimelineSnap.snapped(time: span.start + delta, candidates: candidates, tolerance: tolerance)
            let upper = span.end - minimumSpan
            let start = min(max(snapped.time, 0), max(0, upper))
            return TimelineItemDragResult(start: start, end: span.end, snappedTo: snapped.snappedTo)

        case .edge(.end):
            let snapped = TimelineSnap.snapped(time: span.end + delta, candidates: candidates, tolerance: tolerance)
            let lower = span.start + minimumSpan
            let end = max(min(snapped.time, totalDuration), lower)
            return TimelineItemDragResult(start: span.start, end: end, snappedTo: snapped.snappedTo)

        case .move:
            // 可動域はアンカーで決まる。
            //
            // - `.mosaic`（素材時刻アンカー）: 属するクリップの合成区間に閉じる。
            //   区間はクリップに紐づくので、クリップの外へは出られない。
            // - `.audio`（合成時刻アンカー = `anchorClipID == nil`）: **タイムライン全体**。
            //   BGM はどのクリップにも属さないので、クリップ境界で止める理由が無い。
            //   ここでクリップ帯を要求すると、BGM が「掴めるのに 1mm も動かない」になる。
            let bounds: (lower: Double, upper: Double)
            if let anchor = span.anchorClipID {
                guard let band = layouts.first(where: { $0.clipID == anchor }) else {
                    return TimelineItemDragResult(start: span.start, end: span.end, snappedTo: nil)
                }
                bounds = (band.spanStart, band.spanEnd)
            } else {
                bounds = (0, totalDuration)
            }
            let length = span.end - span.start

            // 先頭優先: 先頭（start）が候補に当たればそのシフト量を採用する。
            // 当たらなければ末尾（end）を試す。両方外れれば吸着なしでそのままシフトする。
            // 「先頭優先」にしたのは、掴んだ区間を左（先頭）から詰めて配置する操作
            // （クリップ境界に頭を揃える）が最も多い操作だと想定しているため。
            let startSnap = TimelineSnap.snapped(time: span.start + delta, candidates: candidates, tolerance: tolerance)
            let shift: Double
            let snappedTo: Double?
            if startSnap.isSnapped {
                shift = startSnap.time - span.start
                snappedTo = startSnap.snappedTo
            } else {
                let endSnap = TimelineSnap.snapped(time: span.end + delta, candidates: candidates, tolerance: tolerance)
                if endSnap.isSnapped {
                    shift = endSnap.time - span.end
                    snappedTo = endSnap.snappedTo
                } else {
                    shift = delta
                    snappedTo = nil
                }
            }

            let shiftedStart = span.start + shift
            // クランプ範囲は [0, totalDuration - length] を、さらに掴んだ区間が属する
            // クリップの**合成区間** [spanStart, spanEnd] へ絞る（移動は同一クリップ内に閉じる）。
            //
            // **`bandStart` / `bandEnd` を使ってはいけない。** あちらは
            // `bandStart = overlapEnd ?? span.start`（`TimelineBandLayout.clipLayouts`）で、
            // トランジションの重なりを隠すための**表示用の矩形**である。区間の可動域に
            // 使うと、確定側（`MosaicApplyGate.ranges(movingRangeID:)` は `span.start` /
            // `span.end` でクランプする）と可動域が食い違い、トランジションを設定した
            // 後続クリップでだけ「掴んで動かせるのに指を離すと必ず元へ戻る」になる。
            // **可動域の定義は確定側と 1 つに揃える。**
            let lowerBound = max(0, bounds.lower)
            let upperBound = max(lowerBound, min(totalDuration, bounds.upper) - length)
            let start = min(max(shiftedStart, lowerBound), upperBound)
            return TimelineItemDragResult(start: start, end: start + length, snappedTo: snappedTo)
        }
    }
}
