import AVFoundation
import MosaicCore
import SwiftUI

/// CapCut 風のマルチクリップタイムライン（S9）。
///
/// 構成（すべて同じ横スクロール内・同じ x 座標系）:
/// - 目盛り + スクラブ帯（`TimelineRulerTrackView`。ドラッグでシーク）
/// - クリップ帯（`TimelineClipBandView`。選択・トリム・長押し並べ替え・継ぎ目ボタン）
/// - モザイク適用区間トラック（`TimelineApplyTrackView`）
/// - プレイヘッド（縦線）
///
/// **時間表現の扱い**: この View が扱う時間は**合成時刻（秒）**に統一してある。
/// `model.playbackPosition`（0〜1）との往復は `compositionTime(forPosition:)` と
/// `totalDuration` の除算だけ、px との往復は `TimelineGeometry`（MosaicCore の純関数）
/// だけを通す。素材時刻は `TimelineBandLayout` / `MosaicApplyGate` に任せ、
/// この層では扱わない（サムネイル位置の算出だけが例外で、`clampedSourceTime` を通す）。
///
/// **クリップ帯は合成タイムライン上に並ぶ**（編集タイムラインではない）。
/// トランジションの重なり区間は先行クリップの帯が占有し、後続クリップの帯は
/// 重なり終了から始まる（`TimelineBandLayout.clipLayouts` の契約）。これにより
/// 分割・適用区間・プレイヘッドがすべて同じ時間軸で扱える。
///
/// **進行中のジェスチャ下書きはこの View が持たない**。各トラックの `@GestureState`
/// （キャンセルで自動的に初期値へ戻る）に閉じ込めてあるため、横スクロールでの中断など
/// 回収イベントが飛んでこない経路でも取り残しが起きない（`TimelineInteraction` の doc）。
struct VideoTimelineView: View {
    @ObservedObject var model: MosaicEditorModel

    @StateObject private var thumbnails = TimelineThumbnailStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var geometry = TimelineGeometry()
    @State private var selectedClipID: UUID?
    @State private var selectedRangeID: UUID?
    @State private var speedSheetClipID: UUID?
    @State private var transitionSheetClipID: UUID?
    @State private var showPhotoPicker = false

    /// 1 回の要求で投入するサムネイル枚数の上限（メモリと生成時間の歯止め）。
    ///
    /// **予算は未生成のジョブにだけ使う**（`TimelineThumbnailStore.needsGeneration`）。
    /// キャッシュ済みも数えると、常に同じ順の `clipLayouts` の先頭 2 クリップが予算を
    /// 食い切り、3 本目以降が永久に要求されない。
    private static let thumbnailRequestLimit = 120
    /// 「モザイク区間」ボタンで足す区間の既定長（秒）。
    private static let defaultApplyRangeLength = 2.0

    // MARK: - 導出値

    private var totalDuration: Double { max(model.videoDuration, 0) }
    private var playheadTime: Double { model.compositionTime(forPosition: model.playbackPosition) }
    private var contentWidth: CGFloat { CGFloat(max(geometry.width(forDuration: totalDuration), 1)) }
    private var clipLayouts: [TimelineClipLayout] { TimelineBandLayout.clipLayouts(mapping: model.mapping) }
    private var jointLayouts: [TimelineJointLayout] { TimelineBandLayout.jointLayouts(mapping: model.mapping) }
    private var applySpans: [TimelineApplySpan] {
        TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges, mapping: model.mapping)
    }
    /// 選択中クリップ（消えたクリップを指したままにしないよう毎回引き直す）。
    private var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        return model.timeline.clips.first { $0.id == selectedClipID }
    }

    var body: some View {
        VStack(spacing: 6) {
            TimelineToolbarView(items: toolItems)
            tracks
        }
        .padding(.vertical, 6)
        .onAppear {
            bindPreviewBusy()
            thumbnails.setSuspended(false)
            refreshThumbnailRequests()
        }
        .onChange(of: model.isPlaying) { playing in
            thumbnails.setPlaying(playing)
            if !playing { refreshThumbnailRequests() }
        }
        .onChange(of: model.timeline) { _ in
            pruneSelection()
            refreshThumbnailRequests()
        }
        .onChange(of: geometry) { _ in refreshThumbnailRequests() }
        .onChange(of: model.sourceVideoURL) { _ in
            // 素材が入れ替わったらキャッシュは無効（別動画のコマを描かない）。
            thumbnails.reset()
            selectedClipID = nil
            selectedRangeID = nil
            refreshThumbnailRequests()
        }
        .onChange(of: scenePhase) { phase in
            // バックグラウンドでは進行中バッチのデコードを止める（`Task` は self が
            // 消えても完走するので、明示的に打ち切らないと裏で走り続ける）。
            thumbnails.setSuspended(phase != .active)
            if phase == .active { refreshThumbnailRequests() }
        }
        .onDisappear {
            thumbnails.setSuspended(true)
            model.onPreviewDecodeBusyChanged = nil
        }
        .sheet(isPresented: showSpeedSheet) { speedSheet }
        .sheet(isPresented: showTransitionSheet) { transitionSheet }
        .sheet(isPresented: $showPhotoPicker) { photoPicker }
    }

    /// プレビューのデコード占有をサムネイル生成の抑止条件へ繋ぐ。
    ///
    /// `@Published` ではなくコールバックで受けるのは、`renderCurrentFrame` が再生中
    /// 30fps で立ち上げ下げを繰り返すため（`@Published` だと画面全体が毎フレーム再描画される）。
    private func bindPreviewBusy() {
        let store = thumbnails
        model.onPreviewDecodeBusyChanged = { busy in store.setPreviewBusy(busy) }
        thumbnails.setPreviewBusy(model.isPreviewDecodeBusy)
    }

    // MARK: - トラック

    private var tracks: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: TimelineMetrics.trackSpacing) {
                        TimelineRulerTrackView(geometry: geometry, totalDuration: totalDuration,
                                               contentWidth: contentWidth, onScrub: scrub,
                                               onScrubbingChanged: { thumbnails.setScrubbing($0) })
                        clipBand
                        TimelineApplyTrackView(
                            geometry: geometry, spans: applySpans, totalDuration: totalDuration,
                            selectedRangeID: $selectedRangeID, onCommit: commit)
                    }
                    playhead
                }
                .frame(width: contentWidth, height: TimelineMetrics.stackHeight, alignment: .topLeading)
                .padding(.horizontal, 16)
            }
            .onChange(of: playheadTickIndex) { index in
                // 再生中だけプレイヘッドを追う（一時停止中に自動スクロールすると
                // ユーザーのスクロール操作と喧嘩する）。
                guard model.isPlaying else { return }
                withAnimation(.linear(duration: 0.15)) {
                    proxy.scrollTo(TimelineTickID(index: index), anchor: .center)
                }
            }
        }
        .frame(height: TimelineMetrics.stackHeight)
    }

    @ViewBuilder
    private var clipBand: some View {
        if clipLayouts.isEmpty {
            RoundedRectangle(cornerRadius: TimelineMetrics.cornerRadius)
                .fill(Color.black.opacity(0.4))
                .frame(width: contentWidth, height: TimelineMetrics.clipHeight)
                .overlay(
                    Text(model.isLoading ? "読み込み中…" : "クリップがありません")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                )
        } else {
            TimelineClipBandView(
                model: model, thumbnails: thumbnails, geometry: geometry,
                layouts: clipLayouts, joints: jointLayouts,
                selectedClipID: $selectedClipID,
                onCommit: commit, onJointTap: { transitionSheetClipID = $0 })
        }
    }

    /// プレイヘッドが乗っている目盛りの index。**描く側と同じ実効間隔**を使う
    /// （違う間隔だと `scrollTo` の対象 id が存在せず追従が黙って止まる）。
    private var playheadTickIndex: Int {
        let interval = geometry.effectiveTickInterval(totalDuration: totalDuration)
        guard interval > 0 else { return 0 }
        return Int((playheadTime / interval).rounded(.down))
    }

    private var playhead: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: TimelineMetrics.stackHeight)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .offset(x: geometry.x(forTime: playheadTime) - 1)
            .allowsHitTesting(false)
    }

    // MARK: - ツールバー

    private var toolItems: [TimelineToolItem] {
        [
            TimelineToolItem(title: "分割", systemImage: "scissors", isEnabled: canSplit) {
                guard let id = selectedClipID else { return }
                model.splitClip(id: id)
            },
            TimelineToolItem(title: "削除", systemImage: "trash", isEnabled: canRemoveClip) {
                guard let id = selectedClipID else { return }
                selectedClipID = nil
                model.removeClip(id: id)
            },
            TimelineToolItem(title: "速度", systemImage: "speedometer", isEnabled: selectedClip != nil) {
                speedSheetClipID = selectedClipID
            },
            TimelineToolItem(title: "写真追加", systemImage: "photo.on.rectangle",
                             isEnabled: !model.timeline.clips.isEmpty) {
                showPhotoPicker = true
            },
            TimelineToolItem(title: "モザイク区間", systemImage: "plus.rectangle.on.rectangle",
                             isEnabled: canAddApplyRange, separatorBefore: true) {
                addApplyRangeAtPlayhead()
            },
            TimelineToolItem(title: "区間削除", systemImage: "minus.rectangle",
                             isEnabled: selectedRangeID != nil) {
                guard let id = selectedRangeID else { return }
                selectedRangeID = nil
                model.removeMosaicApplyRange(id: id)
            },
            TimelineToolItem(title: "縮小", systemImage: "minus.magnifyingglass",
                             isEnabled: geometry.zoomedOut() != geometry, separatorBefore: true) {
                geometry = geometry.zoomedOut()
            },
            TimelineToolItem(title: "拡大", systemImage: "plus.magnifyingglass",
                             isEnabled: geometry.zoomedIn() != geometry) {
                geometry = geometry.zoomedIn()
            }
        ]
    }

    /// 分割の活性判定。**実行と同じ純関数**（`TimelineState.canSplit`）を使う。
    ///
    /// 帯の区間（`spanStart`/`spanEnd`）で自前判定すると、トランジションの重なり区間で
    /// 「押せる/押せない」と「実際に割れるクリップ」が別の規則で決まってしまう。
    private var canSplit: Bool {
        guard let selectedClipID else { return false }
        return model.timeline.canSplit(clipID: selectedClipID, atDisplayTime: playheadTime)
    }

    private var canRemoveClip: Bool { selectedClip != nil && model.timeline.clips.count > 1 }

    private var canAddApplyRange: Bool {
        !model.timeline.clips.isEmpty && totalDuration > 0 && playheadTime < totalDuration
    }

    // MARK: - シート

    private var showSpeedSheet: Binding<Bool> {
        Binding(get: { speedSheetClipID != nil }, set: { if !$0 { speedSheetClipID = nil } })
    }

    private var showTransitionSheet: Binding<Bool> {
        Binding(get: { transitionSheetClipID != nil }, set: { if !$0 { transitionSheetClipID = nil } })
    }

    @ViewBuilder
    private var speedSheet: some View {
        if let id = speedSheetClipID, let clip = model.timeline.clips.first(where: { $0.id == id }) {
            // 上限はクリップ尺から決まる（合成尺が最小尺を割る倍率を選べないようにする。
            // `TimelineRateScale.maximumRate(forClip:)` の doc 参照）。
            TimelineSpeedSheet(initialRate: clip.rate,
                               maximumRate: TimelineRateScale.maximumRate(forClip: clip)) { rate in
                model.setClipRate(id: id, rate: rate)
            }
        }
    }

    @ViewBuilder
    private var transitionSheet: some View {
        if let id = transitionSheetClipID,
           let maximum = model.timeline.maximumTransitionDuration(afterClipID: id) {
            TimelineTransitionSheet(
                current: model.timeline.transitions[id],
                maximumDuration: maximum,
                onApply: { kind, duration in
                    model.setTransition(afterClipID: id, kind: kind, duration: duration)
                },
                onRemove: { model.removeTransition(afterClipID: id) })
        } else {
            Text("このつなぎ目にはトランジションを付けられません（クリップが短すぎます）")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(24)
                .presentationDetents([.height(140)])
        }
    }

    private var photoPicker: some View {
        MediaPicker(filter: .images) { picked in
            showPhotoPicker = false
            guard case let .image(image) = picked else { return }
            Task { await model.appendPhotoClip(image: image) }
        }
        .ignoresSafeArea()
    }

    // MARK: - 操作の確定

    /// ジェスチャ確定（`onEnded`）からのモデル編集。**モデルを触るのはここだけ**。
    private func commit(_ committed: TimelineInteraction) {
        switch committed {
        case let .trim(clipID, edge, delta):
            commitTrim(clipID: clipID, edge: edge, delta: delta)
        case let .reorder(clipID, translation):
            guard let target = TimelineBandLayout.reorderTargetIndex(
                layouts: clipLayouts, clipID: clipID, translationSeconds: translation) else { return }
            model.moveClip(id: clipID, toIndex: target)
        case let .applyEdge(rangeID, clipID, start, end):
            commitApplyEdge(rangeID: rangeID, clipID: clipID, start: start, end: end)
        }
    }

    private func commitTrim(clipID: UUID, edge: TimelineTrimEdge, delta: Double) {
        guard let clip = model.timeline.clips.first(where: { $0.id == clipID }) else { return }
        let bounds = TimelineBandLayout.trimmedBounds(
            clip: clip, edge: edge, deltaCompositionSeconds: delta,
            sourceDuration: model.sourceDuration(forClipID: clipID))
        model.trimClip(id: clipID, sourceStart: bounds.sourceStart, sourceEnd: bounds.sourceEnd)
    }

    /// 掴んだセグメント（`rangeID` × `clipID`）の新区間だけを渡す。
    /// 差し替えは素材時刻で行われ、他セグメントぶん・クリップ使用範囲外の素材区間は
    /// コア層が温存する（`TimelineState.replacingApplyRange(id:clipID:compositionInterval:)`）。
    private func commitApplyEdge(rangeID: UUID, clipID: UUID, start: Double, end: Double) {
        model.setMosaicApplyRange(id: rangeID, clipID: clipID,
                                  interval: CompositionInterval(start: start, end: end))
        reselectApplyRange(near: (start + end) / 2)
    }

    private func addApplyRangeAtPlayhead() {
        let end = min(playheadTime + Self.defaultApplyRangeLength, totalDuration)
        guard playheadTime < end else { return }
        model.addMosaicApplyRange(fromCompositionTime: playheadTime, to: end)
        reselectApplyRange(near: (playheadTime + end) / 2)
    }

    /// 編集後に区間を引き直す（マージで id が変わり得るため id を保持し続けない）。
    private func reselectApplyRange(near time: Double) {
        let spans = TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges, mapping: model.mapping)
        selectedRangeID = spans.first { time >= $0.start && time < $0.end }?.rangeID
    }

    private func scrub(toCompositionTime seconds: Double) {
        guard totalDuration > 0 else { return }
        let clamped = min(max(seconds, 0), totalDuration.nextDown)
        model.seekToLatest(position: clamped / totalDuration)
    }

    /// 消えたクリップ・区間を選択したままにしない（削除・undo 後）。
    private func pruneSelection() {
        if let selectedClipID, !model.timeline.clips.contains(where: { $0.id == selectedClipID }) {
            self.selectedClipID = nil
        }
        if let selectedRangeID, !model.timeline.applyRanges.contains(where: { $0.id == selectedRangeID }) {
            self.selectedRangeID = nil
        }
        if let speedSheetClipID, !model.timeline.clips.contains(where: { $0.id == speedSheetClipID }) {
            self.speedSheetClipID = nil
        }
        // 継ぎ目シートも同じ扱い（undo でクリップが消えた状態のシートを開いたままにしない）。
        if let transitionSheetClipID,
           !model.timeline.clips.contains(where: { $0.id == transitionSheetClipID }) {
            self.transitionSheetClipID = nil
        }
    }

    // MARK: - サムネイル要求

    /// 表示中の帯を埋めるサムネイルをまとめて要求する。
    ///
    /// **予算（`thumbnailRequestLimit`）は未生成のジョブにだけ使い、プレイヘッドに
    /// 近い枠を優先する。** キャッシュ済みも数えると先頭のクリップが予算を食い切り、
    /// 3 本目以降のクリップが何度 refresh しても 1 件も要求されない（実測: pps=160 /
    /// 20 秒クリップで 120 枠に収まるのは 2 クリップ）。
    /// 抑止中（再生・プレビューのデコード中）でもキューには積む（store 側が判断する）。
    /// body からは呼ばない（描画の副作用にしない）。
    private func refreshThumbnailRequests() {
        var candidates: [(distance: Double, request: TimelineThumbnailStore.Request)] = []
        for layout in clipLayouts {
            guard let clip = model.timeline.clips.first(where: { $0.id == layout.clipID }),
                  let url = model.sourceURL(forSourceID: clip.sourceID) else { continue }
            // 描画側（TimelineClipBandView）と同じ枠配置を使う（別々に計算すると
            // 要求したキーと描画で引くキーがずれて帯が埋まらない）。
            let slots = TimelineThumbnailLayout.slots(
                clip: clip, spanStart: layout.spanStart,
                band: CompositionInterval(start: layout.bandStart, end: layout.bandEnd),
                geometry: geometry,
                preferredSlotWidth: Double(TimelineMetrics.thumbnailSlotWidth),
                sourceDuration: model.sourceDuration(forClipID: layout.clipID))
            let slotDuration = geometry.duration(forWidth: slots.slotWidth)
            for (index, time) in slots.sourceTimes.enumerated() {
                let sourceTime = model.timeline.clampedSourceTime(time, sourceID: clip.sourceID)
                guard thumbnails.needsGeneration(sourceID: clip.sourceID, sourceTime: sourceTime)
                else { continue }
                let slotCenter = layout.bandStart + (Double(index) + 0.5) * slotDuration
                candidates.append((abs(slotCenter - playheadTime),
                                   TimelineThumbnailStore.Request(sourceID: clip.sourceID, url: url,
                                                                  sourceTime: sourceTime)))
            }
        }
        let ordered = candidates.sorted { $0.distance < $1.distance }
            .prefix(Self.thumbnailRequestLimit)
            .map(\.request)
        thumbnails.request(Array(ordered))
    }
}
