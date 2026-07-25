import MosaicCore
import SwiftUI

/// モザイク適用区間トラック（クリップ帯の下）。
///
/// **座標系**: UI 操作はすべて**合成時刻**で行い、保存は
/// `MosaicApplyGate` / `TimelineState.addingApplyRange` が素材時刻アンカーへ写す。
/// 表示は逆写像 `TimelineBandLayout.applySpans(ranges:mapping:)` の結果を描くだけで、
/// この View は素材時刻を一切扱わない。
///
/// **1 区間が複数セグメントに見えることがある**: 適用区間は素材アンカーなので、
/// 同じ素材を使うクリップが複数あれば同じ `rangeID` のセグメントが複数現れる
/// （分割したクリップを跨ぐ区間など）。掴んだセグメントは `clipID` で区別して
/// プレビューし、確定も**掴んだセグメント単位**で行う（差し替えは素材時刻で行われ、
/// 他セグメントぶん・クリップ使用範囲外の素材区間はコア層が温存する。
/// `TimelineState.replacingApplyRange(id:clipID:compositionInterval:)` 参照）。
///
/// **S9 の範囲**: 状態編集と表示まで。描画ゲート（区間外でモザイクを載せない）の
/// 配線は S10 の担当。
struct TimelineApplyTrackView: View {
    /// 端ドラッグの下書き（ジェスチャ中だけ非 nil）。
    /// `@GestureState` なのでキャンセルで自動的に初期値へ戻る。
    struct ApplyDraft: Equatable {
        let rangeID: UUID
        let clipID: UUID
        let start: Double
        let end: Double
    }

    let geometry: TimelineGeometry
    let spans: [TimelineApplySpan]
    let totalDuration: Double
    @Binding var selectedRangeID: UUID?
    let onCommit: (TimelineInteraction) -> Void

    @GestureState private var draft: ApplyDraft?

    /// 端ドラッグで潰さない最小の合成尺（秒）。
    private static let minimumSpan: Double = 0.1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: max(geometry.width(forDuration: totalDuration), 1),
                       height: TimelineMetrics.applyTrackHeight)
            ForEach(spans) { span in
                spanView(span)
            }
        }
        .frame(height: TimelineMetrics.applyTrackHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func spanView(_ span: TimelineApplySpan) -> some View {
        let bounds = displayBounds(span)
        let width = geometry.width(forDuration: bounds.end - bounds.start)
        let isSelected = selectedRangeID == span.rangeID

        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(isSelected ? 0.85 : 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
            )
            .frame(width: max(width, 3), height: TimelineMetrics.applyTrackHeight)
            .overlay(alignment: .leading) { if isSelected { edgeHandle(span, edge: .start) } }
            .overlay(alignment: .trailing) { if isSelected { edgeHandle(span, edge: .end) } }
            .offset(x: geometry.x(forTime: bounds.start))
            .contentShape(Rectangle())
            .onTapGesture { selectedRangeID = span.rangeID }
    }

    private func edgeHandle(_ span: TimelineApplySpan, edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 8, height: TimelineMetrics.applyTrackHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($draft) { value, draft, _ in
                        draft = Self.draft(span, edge: edge,
                                           translation: Double(value.translation.width),
                                           geometry: geometry, totalDuration: totalDuration)
                    }
                    .onEnded { value in
                        let committed = Self.draft(span, edge: edge,
                                                   translation: Double(value.translation.width),
                                                   geometry: geometry, totalDuration: totalDuration)
                        onCommit(.applyEdge(rangeID: committed.rangeID, clipID: committed.clipID,
                                            start: committed.start, end: committed.end))
                    }
            )
    }

    /// ドラッグ量から確定候補の合成時刻区間を作る（最小尺・タイムライン端でクランプ）。
    private static func draft(_ span: TimelineApplySpan,
                              edge: TimelineTrimEdge,
                              translation: Double,
                              geometry: TimelineGeometry,
                              totalDuration: Double) -> ApplyDraft {
        let delta = geometry.time(forX: translation)
        switch edge {
        case .start:
            let upper = span.end - minimumSpan
            let start = min(max(span.start + delta, 0), max(0, upper))
            return ApplyDraft(rangeID: span.rangeID, clipID: span.clipID, start: start, end: span.end)
        case .end:
            let lower = span.start + minimumSpan
            let end = max(min(span.end + delta, totalDuration), lower)
            return ApplyDraft(rangeID: span.rangeID, clipID: span.clipID, start: span.start, end: end)
        }
    }

    private func displayBounds(_ span: TimelineApplySpan) -> (start: Double, end: Double) {
        guard let draft, draft.rangeID == span.rangeID, draft.clipID == span.clipID else {
            return (span.start, span.end)
        }
        return (draft.start, draft.end)
    }
}
