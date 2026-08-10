import Foundation

/// トリム下書き中の**表示専用**レイアウト（リップル表示）。
///
/// ## なぜモデルを触らずにここで計算するか
///
/// タイムライン編集の契約は「**ジェスチャ中はモデル（＝編集状態）を変更しない /
/// 確定は `onEnded` の 1 回だけ**」（`TimelineInteraction` の doc）。進行中の下書きは
/// View の `@GestureState` が持つ。**その下書きから表示を導出するのは契約の内側**で、
/// ここの関数は入力の配列を写した新しい配列を返すだけの純関数である。ジェスチャが
/// 中断されると `@GestureState` が初期値へ戻り、レイアウトも自動で元へ戻る。
///
/// リップルを入れないと、内向きトリム中は縮んだ帯の右に**空白の隙間**が見え、
/// 外向きトリム中は次クリップの上に**重なって**見える（指を離した瞬間に詰め直される）。
public extension TimelineBandLayout {
    /// 下書き中に「掴んだクリップの帯の右端」と「以降のクリップ全体」が動く量（秒）。
    ///
    /// `effectiveDeltaSeconds` は `trimmedBounds` の結果から作った**クランプ済み**の
    /// 実効差分で、符号は次のとおり（`TimelineClipBandView.trimPreview` と対）:
    /// - `.start`: `(bounds.sourceStart - clip.sourceStart) / rate`（正 = 内向き = 帯が縮む）
    /// - `.end`: `(bounds.sourceEnd - clip.sourceEnd) / rate`（正 = 外向き = 帯が伸びる）
    ///
    /// **どちらの端でも帯の左端は動かさない。** クリップは合成タイムライン上で
    /// 突き合わせて並ぶので、start トリムでも左端（= 先行クリップの終端）は動かず、
    /// 尺が変わったぶん右端が動いて後続クリップが寄る。左端を動かすプレビューにすると
    /// 指を離した瞬間に帯がドラッグ量ぶん横へ飛ぶ。
    ///
    /// 非有限な差分は 0（＝恒等）に落とす。
    static func previewShift(edge: TimelineTrimEdge, effectiveDeltaSeconds delta: Double) -> Double {
        guard delta.isFinite else { return 0 }
        return edge == .start ? -delta : delta
    }

    /// トリム下書き中の**表示専用**レイアウト。掴んだクリップの帯を伸縮させ、
    /// それ以降のクリップの帯を同じ量だけ平行移動する（リップル表示）。
    /// **モデルは一切変更しない。**
    ///
    /// 帯は元どおり「接するが重ならない」まま保たれる（掴んだ帯の右端と後続の帯が
    /// 同じ量だけ動くため）。`effectiveDeltaSeconds` が 0 のときは入力をそのまま返す。
    static func previewLayouts(layouts: [TimelineClipLayout],
                               trimmingClipID: UUID,
                               edge: TimelineTrimEdge,
                               effectiveDeltaSeconds: Double) -> [TimelineClipLayout] {
        let shift = previewShift(edge: edge, effectiveDeltaSeconds: effectiveDeltaSeconds)
        guard shift != 0,
              let grabbed = layouts.first(where: { $0.clipID == trimmingClipID }) else { return layouts }
        return layouts.map { layout in
            guard layout.index >= grabbed.index else { return layout }
            // 掴んだクリップだけは左端を据え置き、右端（と合成尺）だけ動かす。
            let leading = layout.index == grabbed.index ? 0 : shift
            return TimelineClipLayout(clipID: layout.clipID, sourceID: layout.sourceID,
                                      index: layout.index,
                                      spanStart: layout.spanStart + leading,
                                      spanEnd: layout.spanEnd + shift,
                                      bandStart: layout.bandStart + leading,
                                      bandEnd: max(layout.bandStart + leading, layout.bandEnd + shift))
        }
    }

    /// `previewLayouts` と同じシフトを適用区間スパンにも掛ける（帯とズレないようにする）。
    ///
    /// - 掴んだクリップより**後ろ**のクリップのスパン: 帯と同じ `shift` だけ平行移動。
    /// - 掴んだクリップ**自身**のスパン: `.start` では素材の入り口が動くので中身も一緒に
    ///   流れる（＝ `shift` だけ移動）、`.end` では中身は動かず右端だけ伸縮する。
    ///   どちらもプレビュー帯の外へは出さない（トリムで消える領域に区間を描かない）。
    /// - 掴んだクリップより**前**のクリップのスパン: 不変。
    ///
    /// `layouts` に載っていない `clipID` のスパンは触らない。
    static func previewApplySpans(spans: [TimelineApplySpan],
                                  layouts: [TimelineClipLayout],
                                  trimmingClipID: UUID,
                                  edge: TimelineTrimEdge,
                                  effectiveDeltaSeconds: Double) -> [TimelineApplySpan] {
        let shift = previewShift(edge: edge, effectiveDeltaSeconds: effectiveDeltaSeconds)
        guard shift != 0,
              let grabbed = layouts.first(where: { $0.clipID == trimmingClipID }) else { return spans }
        let indices = Dictionary(layouts.map { ($0.clipID, $0.index) }, uniquingKeysWith: { first, _ in first })
        let previewEnd = max(grabbed.bandStart, grabbed.bandEnd + shift)
        let inner = edge == .start ? shift : 0
        return spans.map { span in
            guard let index = indices[span.clipID], index >= grabbed.index else { return span }
            guard index == grabbed.index else { return span.shifted(by: shift) }
            return TimelineApplySpan(
                rangeID: span.rangeID, clipID: span.clipID, kind: span.kind,
                start: min(max(span.start + inner, grabbed.bandStart), previewEnd),
                end: min(max(span.end + inner, grabbed.bandStart), previewEnd),
                isEdgeAdjustable: span.isEdgeAdjustable)
        }
    }
}

private extension TimelineApplySpan {
    func shifted(by shift: Double) -> TimelineApplySpan {
        TimelineApplySpan(rangeID: rangeID, clipID: clipID, kind: kind,
                          start: start + shift, end: end + shift,
                          isEdgeAdjustable: isEdgeAdjustable)
    }
}
