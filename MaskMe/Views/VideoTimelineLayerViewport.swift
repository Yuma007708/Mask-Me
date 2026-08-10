import MosaicCore
import SwiftUI

/// タイムラインの「レイヤー段」の器（`VideoTimelineView` の一部）。
///
/// 本体から切り出してあるのは行数の都合だが、境界は意味とも合っている:
/// **ここに入るのは動画クリップより上に載る段だけ**で、クリップ帯・目盛り・
/// プレイヘッド（＝時間軸そのものの表現）は本体に残る。
extension VideoTimelineView {
    /// テキストの帯（E3）。**合成尺で切った実効だけ**を見せる
    /// （`TimelineBandLayout.textSpans` の doc 参照。`audioSpans` と同じ規則）。
    var textSpans: [TimelineApplySpan] {
        TimelineBandLayout.textSpans(items: model.timeline.textItems,
                                     totalDuration: totalDuration)
    }

    /// 種を指定したレイヤー選択の `Binding`（`rangeSelection` の kind 対応版）。
    ///
    /// **`rangeSelection`（`TimelineSelection.rangeID` shim）を経由しないこと。**
    /// あの shim は setter が常に `kind: .mosaic` を付けるため、`.audio` / `.text` の
    /// 段でこれを使うと選択そのものは（UUID の一致だけで比較する帯のハイライトには）
    /// 効いて見えるが、内部の選択は `.mosaic` として記録される。その結果、種で絞り込む
    /// 判定（`TimelineVolumeAvailability.target` や削除の `switch layer.kind`）が
    /// 誤った種を見て「選んだのに音量ボタンが出ない／削除ボタンが違うものを消そうとして
    /// 何も起きない」を作る。テキストの段はこの shim を経由させず、素直に
    /// `TimelineSelection.selectLayer` を直接呼ぶ。
    func layerSelection(for kind: TimelineLayerKind) -> Binding<UUID?> {
        Binding(
            get: {
                guard let layer = model.timelineSelection.layer, layer.kind == kind else { return nil }
                return layer.id
            },
            set: { id in
                model.timelineSelection.selectLayer(id.map { TimelineLayerSelection(kind: kind, id: $0) })
            })
    }

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
        case .audio:
            if audioSpans.isEmpty {
                // 空段を押したら音楽ファイルを選ぶ（`.mosaic` と同じ「押せば置ける」）。
                TimelineEmptyLayerRow(kind: .audio, width: contentWidth) {
                    showAudioPicker = true
                }
            } else {
                TimelineLayerTrackView(
                    geometry: geometry, spans: audioSpans, totalDuration: totalDuration,
                    layouts: clipLayouts, playheadTime: playheadTime,
                    trimPreviewRelay: trimPreviewRelay,
                    selectedRangeID: layerSelection(for: .audio), onCommit: commit,
                    onVerticalDrag: updateLayerScroll(translationHeight:),
                    onVerticalDragEnded: endLayerScrollDrag)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.audioTrack")
            }
        case .text:
            if textSpans.isEmpty {
                // 空段を押したらテキストを入力する（`.mosaic` / `.audio` と同じ「押せば置ける」）。
                TimelineEmptyLayerRow(kind: .text, width: contentWidth) {
                    showTextInputSheet = true
                }
            } else {
                TimelineLayerTrackView(
                    geometry: geometry, spans: textSpans, totalDuration: totalDuration,
                    layouts: clipLayouts, playheadTime: playheadTime,
                    trimPreviewRelay: trimPreviewRelay,
                    selectedRangeID: layerSelection(for: .text), onCommit: commit,
                    onVerticalDrag: updateLayerScroll(translationHeight:),
                    onVerticalDragEnded: endLayerScrollDrag)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.textTrack")
            }
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

    // MARK: - レイヤー段の確定（`VideoTimelineView.commit(_:)` から呼ばれる）
    //
    // `VideoTimelineView.swift` が file_length の閾値に張り付いているため、
    // モザイク・BGM・テキストに共通する「区間の確定」一式をこちらへ寄せてある。

    /// 掴んだセグメント（`rangeID` × `clipID`）の新区間だけを渡す。
    /// 差し替えは素材時刻で行われ、他セグメントぶん・クリップ使用範囲外の素材区間は
    /// コア層が温存する（`TimelineState.replacingApplyRange(id:clipID:compositionInterval:)`）。
    /// **種ごとの `switch` で全 case を網羅し、`default` は書かない**
    /// （`TimelineSelection.prune` と同じ理由。種が増えたときに書き忘れると、
    /// つまみは動くのに指を離すと必ず元へ戻る＝無言の no-op になる）。
    func commitApplyEdge(rangeID: UUID, clipID: UUID?, kind: TimelineLayerKind,
                         interval: CompositionInterval) {
        let (start, end) = (interval.start, interval.end)
        switch kind {
        case .mosaic:
            // `.mosaic` の clipID は必ず非 nil（`TimelineApplySpan.anchorClipID` の約束）。
            // nil で来たら型の不変条件が壊れているので、黙って別のものを編集せず何もしない。
            guard let clipID else { return }
            model.setMosaicApplyRange(id: rangeID, clipID: clipID,
                                      interval: CompositionInterval(start: start, end: end))
        case .audio:
            // BGM の端ドラッグは「差し替え」ではなく**現在位置からの差分**で確定する
            // （素材時刻の伸縮に写す必要があるため。`TimelineState.trimmingAudioItem`）。
            guard let item = model.timeline.audioItems.first(where: { $0.id == rangeID })
            else { return }
            let startDelta = start - item.compositionStart
            let endDelta = end - item.compositionEnd
            // 動いた方の端だけを確定する（両端が同時に動くことはない）。
            if abs(startDelta) > abs(endDelta) {
                model.trimAudioItem(id: rangeID, edge: .start, byCompositionDelta: startDelta)
            } else {
                model.trimAudioItem(id: rangeID, edge: .end, byCompositionDelta: endDelta)
            }
        case .text:
            // テキストの端ドラッグも BGM と同じく「現在位置からの差分」で確定する
            // （`TimelineState.trimmingTextItem` は delta 引数のみを受ける）。
            guard let item = model.timeline.textItems.first(where: { $0.id == rangeID })
            else { return }
            let startDelta = start - item.compositionStart
            let endDelta = end - item.compositionEnd
            if abs(startDelta) > abs(endDelta) {
                model.trimTextItem(id: rangeID, edge: .start, byCompositionDelta: startDelta)
            } else {
                model.trimTextItem(id: rangeID, edge: .end, byCompositionDelta: endDelta)
            }
        }
        // **引き直すのはモザイクだけ。** 適用区間はマージで id が変わり得るので
        // 引き直しが要るが、BGM・テキストは id が変わらない。種を問わず
        // `reselectApplyRange` を呼ぶと、BGM を編集した直後にモザイク区間の選択へ
        // 化ける（該当する区間が無ければ選択が外れる）。
        if kind == .mosaic { reselectApplyRange(near: (start + end) / 2) }
    }

    /// 本体ドラッグ（移動）の確定。`start` / `end` はドラッグ表示と同じ最終位置で、
    /// 確定後の選択引き直し（マージで id が変わり得る）に使うだけ。実際の編集は
    /// `TimelineState.movingApplyRange` へそのまま渡す `delta`（合成時刻）が行う。
    func commitApplyMove(rangeID: UUID, clipID: UUID?, kind: TimelineLayerKind,
                         delta: Double, interval: CompositionInterval) {
        let (start, end) = (interval.start, interval.end)
        switch kind {
        case .mosaic:
            guard let clipID else { return }
            model.moveMosaicApplyRange(id: rangeID, clipID: clipID, byCompositionDelta: delta)
        case .audio:
            model.moveAudioItem(id: rangeID, byCompositionDelta: delta)
        case .text:
            model.moveTextItem(id: rangeID, byCompositionDelta: delta)
        }
        // 引き直すのはモザイクだけ（`commitApplyEdge` と同じ理由）。
        if kind == .mosaic { reselectApplyRange(near: (start + end) / 2) }
    }

    func addApplyRangeAtPlayhead() {
        let end = min(playheadTime + Self.defaultApplyRangeLength, totalDuration)
        guard playheadTime < end else { return }
        model.addMosaicApplyRange(fromCompositionTime: playheadTime, to: end)
        reselectApplyRange(near: (playheadTime + end) / 2)
    }

    /// 編集後に区間を引き直す（マージで id が変わり得るため id を保持し続けない）。
    /// 相互排他を効かせるため `rangeSelection` 経由で書く（クリップ選択が残らない）。
    func reselectApplyRange(near time: Double) {
        let spans = TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges,
                                                  mapping: model.mapping,
                                                  photoSourceIDs: model.timeline.photoSourceIDs)
        rangeSelection.wrappedValue = spans.first { time >= $0.start && time < $0.end }?.rangeID
    }
}
