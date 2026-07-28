import AVFoundation
import MosaicCore
import SwiftUI

/// CapCut 風のマルチクリップタイムライン（S9）。
///
/// 構成（すべて同じ横スクロール内・同じ x 座標系）:
/// - 目盛り帯（`TimelineRulerTrackView`。表示専用）
/// - クリップ帯（`TimelineClipBandView`。選択・トリム・長押し並べ替え・継ぎ目ボタン）
/// - モザイク適用区間トラック（`TimelineApplyTrackView`）
///
/// プレイヘッドだけは**スクロールしない層**に置き、可視領域の中央に固定する
/// （`TimelineScrollContainer` / `TimelinePlayheadView`）。つまり
/// **タイムラインを横に払う操作がそのままシーク**であり、目盛りを掴んで
/// 絶対時刻へ飛ばす操作は無い。
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
/// トリム中のリップルだけは兄弟トラック（クリップ帯 → 適用区間）へ渡す必要があるので、
/// **表示専用の派生値**を `TimelineTrimPreviewRelay` で中継する（下書きの所有者は帯のまま）。
struct VideoTimelineView: View {
    @ObservedObject var model: MosaicEditorModel

    @StateObject private var thumbnails = TimelineThumbnailStore()
    @Environment(\.scenePhase) private var scenePhase
    @State var geometry = TimelineGeometry()
    @State var selectedClipID: UUID?
    @State var selectedRangeID: UUID?
    @State var speedSheetClipID: UUID?
    @State var volumeSheetClipID: UUID?
    @State private var transitionSheetClipID: UUID?
    @State var showMediaPicker = false
    /// スクロールの見え方（トラック内 x 座標系）。`TimelineScrollContainer` が更新し、
    /// サムネイル要求の可視範囲を決めるのに使う。
    @State private var viewport = TimelineViewport(scrollOffset: 0, visibleWidth: 0, contentWidth: 0)
    /// 並べ替えドラッグ ⇔ スクロール容器の受け渡し口（`TimelineAutoScrollState` の doc 参照）。
    @StateObject private var autoScroll = TimelineAutoScrollState()
    /// デバウンス中のサムネイル再要求。
    @State private var thumbnailRefreshTask: Task<Void, Never>?
    /// この View が画面に載っているか（`setSuspended` の入力その 1）。
    @State private var isOnScreen = false
    /// クリップ帯のトリム下書き（表示専用）を適用区間トラックへ渡す中継。
    ///
    /// **`@StateObject` にしないこと。** 購読するとドラッグ中 60Hz でこの View の body が
    /// 再評価され、子のジェスチャが作り直される。`@State` に参照型を入れて**持つだけ**にし、
    /// 購読は追随が要る `TimelineApplyTrackView` にだけ持たせる（`TimelineTrimPreviewRelay` の doc）。
    @State private var trimPreviewRelay = TimelineTrimPreviewRelay()

    /// 1 回の要求で投入するサムネイル枚数の上限（メモリと生成時間の歯止め）。
    ///
    /// **予算は未生成のジョブにだけ使う**（`TimelineThumbnailStore.needsGeneration`）。
    /// キャッシュ済みも数えると、常に同じ順の `clipLayouts` の先頭 2 クリップが予算を
    /// 食い切り、3 本目以降が永久に要求されない。
    private static let thumbnailRequestLimit = 120
    /// 「モザイク区間」ボタンで足す区間の既定長（秒）。
    private static let defaultApplyRangeLength = 2.0
    /// サムネイル再要求のデバウンス（ナノ秒）。スクロール・ピンチ中は毎フレーム
    /// トリガが飛ぶので、指が止まってからまとめて 1 回だけ走査する。
    private static let thumbnailRefreshDelay: UInt64 = 180_000_000

    // MARK: - 導出値

    var totalDuration: Double { max(model.videoDuration, 0) }
    var playheadTime: Double { model.compositionTime(forPosition: model.playbackPosition) }
    private var contentWidth: CGFloat { CGFloat(max(geometry.width(forDuration: totalDuration), 1)) }
    private var clipLayouts: [TimelineClipLayout] { TimelineBandLayout.clipLayouts(mapping: model.mapping) }
    private var jointLayouts: [TimelineJointLayout] { TimelineBandLayout.jointLayouts(mapping: model.mapping) }
    /// 写真クリップのセグメントは端ハンドルを出さない（`photoSourceIDs` を渡すことで
    /// `isEdgeAdjustable == false` になる。端ドラッグが構造的に no-op なため）。
    private var applySpans: [TimelineApplySpan] {
        TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges, mapping: model.mapping,
                                      photoSourceIDs: model.timeline.photoSourceIDs)
    }
    /// 選択中クリップ（消えたクリップを指したままにしないよう毎回引き直す）。
    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        return model.timeline.clips.first { $0.id == selectedClipID }
    }

    /// プレイヘッドが乗っているクリップ。**選択なしでも分割できるようにするための導出値**
    /// （一般的な動画編集アプリは「再生位置で切る」が既定で、事前の選択を要求しない）。
    ///
    /// 判定は帯（`bandStart..<bandEnd`）で行う。帯はトランジションの重なりを先行クリップが
    /// 占有する形で**隙間なく連続**しているので、どの時刻でも高々 1 本に決まる
    /// （`TimelineBandLayout.clipLayouts` の契約）。終端ちょうど（`playheadTime ==
    /// totalDuration`）はどの帯にも入らないが、そこは `canSplit` が false なので実害はない。
    var playheadClipID: UUID? {
        clipLayouts.first { playheadTime >= $0.bandStart && playheadTime < $0.bandEnd }?.clipID
    }

    var body: some View {
        VStack(spacing: 6) {
            tracks
            bottomBar
        }
        .padding(.vertical, 6)
        .onAppear {
            bindPreviewBusy()
            isOnScreen = true
            // 再生中にこの画面が現れた場合、`onChange` は発火しないのでストアの
            // `isPlaying` が false のまま残る（HW デコーダ競合の緩和が効かない）。
            // 初期シードをここで入れる。
            thumbnails.setPlaying(model.isPlaying)
            updateSuspension(phase: scenePhase)
        }
        .onChange(of: model.isPlaying) { playing in
            thumbnails.setPlaying(playing)
            if !playing { scheduleThumbnailRefresh() }
        }
        .onChange(of: model.timeline) { _ in
            pruneSelection()
            scheduleThumbnailRefresh()
        }
        .onChange(of: model.sourceVideoURL) { _ in
            // 素材が入れ替わったらキャッシュは無効（別動画のコマを描かない）。
            thumbnails.reset()
            selectedClipID = nil
            selectedRangeID = nil
            scheduleThumbnailRefresh()
        }
        // 抑止の入力源は 3 つ（画面表示・scenePhase・シート）。**必ず
        // `updateSuspension` へ集約する**（個別に `setSuspended` を叩くと、
        // シートを閉じた瞬間に background 中の抑止まで解除されるなど互いを潰し合う）。
        .onChange(of: scenePhase) { updateSuspension(phase: $0) }
        .onChange(of: isSheetPresented) { _ in updateSuspension(phase: scenePhase) }
        .onDisappear {
            isOnScreen = false
            thumbnailRefreshTask?.cancel()
            updateSuspension(phase: scenePhase)
            model.onPreviewDecodeBusyChanged = nil
        }
        // シート本体と提示条件は `TimelineEditSheetsModifier`（TimelineEditSheets.swift）へ
        // 寄せてある（このファイルが file_length の閾値に張り付いているため）。
        .modifier(TimelineEditSheetsModifier(
            model: model, speedClipID: $speedSheetClipID, volumeClipID: $volumeSheetClipID,
            transitionClipID: $transitionSheetClipID, showMediaPicker: $showMediaPicker))
    }

    /// サムネイル生成の抑止を 1 箇所で決める。
    ///
    /// SwiftUI の `.sheet` は提示元の `onDisappear` を呼ばないため、シート提示は
    /// 独立した入力として見る必要がある（`TimelineThumbnailStore.setSuspended` の doc が
    /// 「シートで隠れるときも止める」を要求している）。解除側では再要求を積み直す。
    private func updateSuspension(phase: ScenePhase) {
        let suspended = !isOnScreen || phase != .active || isSheetPresented
        thumbnails.setSuspended(suspended)
        if !suspended { scheduleThumbnailRefresh() }
    }

    /// いずれかのシートが出ているか（抑止の入力その 3）。
    private var isSheetPresented: Bool {
        speedSheetClipID != nil || volumeSheetClipID != nil
            || transitionSheetClipID != nil || showMediaPicker
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

    // MARK: - タイムライン直下の 1 段

    /// タイムラインの**下**に置く 1 段。編集ツールバーと粗さ調整バーが**入れ替わる**
    /// （積み上げない。`TimelineMetrics.toolbarHeight` で高さは常に一定）。
    ///
    /// ツールバーをタイムラインの下へ置くのは一般的な動画編集アプリの並びに合わせるため。
    /// 粗さ調整バーをここへ同居させているのは、効果タブを開いたときに段が増えて
    /// プレビューが潰れるのを防ぐため（旧 UI は 46% → 30% まで縮んでいた）。
    @ViewBuilder
    private var bottomBar: some View {
        if model.activeTab != nil {
            TimelineAdjustmentBarView(model: model)
        } else {
            TimelineToolbarView(items: toolItems)
        }
    }

    // MARK: - トラック

    /// 横スクロール容器。ビューポート観測・ピンチズーム・中央固定・払ってシークは
    /// すべて `TimelineScrollContainer` が持つ（この View は中身を組むだけ）。
    private var tracks: some View {
        TimelineScrollContainer(
            geometry: $geometry, viewport: $viewport,
            contentWidth: contentWidth, stackHeight: stackHeight,
            totalDuration: totalDuration,
            playheadTime: playheadTime, isPlaying: model.isPlaying,
            autoScroll: autoScroll,
            onRefreshNeeded: scheduleThumbnailRefresh,
            onSeek: seekFromScroll,
            // スクラブ中はサムネイル生成を止め（デコーダの取り合い）、
            // 再生位置の所有者をタイムライン側にする（描画経路の書き戻しを止める。
            // `MosaicEditorModel.isTimelineScrubbing`）。
            onScrubbingChanged: {
                thumbnails.setScrubbing($0)
                model.isTimelineScrubbing = $0
            },
            content: { trackStack })
        // プレイヘッドは**スクロールしない層**に置き、可視領域の中央へ固定する
        // （`TimelinePlayheadView` の doc）。中身の側に置くと、シークとスクロールの
        // 1 フレームのずれがそのまま線の震えになる。
        .overlay(alignment: .top) { TimelinePlayheadView(stackHeight: stackHeight) }
    }

    /// 積んだトラックの高さ。継ぎ目が無いときは継ぎ目レーンが畳まれるので
    /// 目盛り帯とクリップ帯が隣り合う（`TimelineMetrics.jointLaneHeight(hasJoints:)`）。
    private var stackHeight: CGFloat {
        TimelineMetrics.stackHeight(hasJoints: !jointLayouts.isEmpty)
    }

    /// スクロールする中身（目盛り・継ぎ目・クリップ帯・適用区間を同じ x 座標系で積む）。
    ///
    /// 各段に `accessibilityIdentifier` を付けてあるのは、UI テストが**段ごとに座標を
    /// 出して払う**ため（`MaskMeUITests/TimelineGestureUITests`。どの段でスクロール＝
    /// シークが起きるかがこの UI の契約なので、段を特定できないと検証できない）。
    /// `children: .contain` にして中身の要素（クリップ・区間）は畳まない。
    private var trackStack: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.trackSpacing) {
            TimelineRulerTrackView(geometry: geometry, totalDuration: totalDuration,
                                   contentWidth: contentWidth)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("timeline.ruler")
            // 継ぎ目レーンとクリップ帯は 1 段として積む
            // （`TimelineMetrics.stackHeight(hasJoints:)` と対応）。
            VStack(alignment: .leading, spacing: 0) {
                // シークの操作面は目盛り帯とクリップ帯だけ（`blocksTimelinePan` の doc）。
                TimelineJointLaneView(geometry: geometry, joints: jointLayouts,
                                      contentWidth: contentWidth,
                                      onJointTap: { transitionSheetClipID = $0 })
                    .blocksTimelinePan(autoScroll)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.jointLane")
                clipBand
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.clipBand")
            }
            TimelineApplyTrackView(
                geometry: geometry, spans: applySpans, totalDuration: totalDuration,
                layouts: clipLayouts, playheadTime: playheadTime,
                trimPreviewRelay: trimPreviewRelay,
                selectedRangeID: rangeSelection, onCommit: commit)
                .blocksTimelinePan(autoScroll)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("timeline.applyTrack")
        }
    }

    @ViewBuilder
    private var clipBand: some View {
        if clipLayouts.isEmpty {
            TimelineEmptyBandView(contentWidth: contentWidth,
                                  text: model.isLoading ? "読み込み中…" : "クリップがありません")
        } else {
            TimelineClipBandView(
                model: model, thumbnails: thumbnails, geometry: geometry,
                layouts: clipLayouts, applySpans: applySpans, playheadTime: playheadTime,
                totalDuration: totalDuration, autoScroll: autoScroll,
                trimPreviewRelay: trimPreviewRelay,
                selectedClipID: clipSelection, onCommit: commit)
        }
    }

    /// クリップ選択と区間選択は**相互排他**にする（どちらが編集対象かを一意にするため）。
    /// `@State` は 2 本のまま残し、子へ渡す `Binding` をここでラップする（子は無改造）。
    private var clipSelection: Binding<UUID?> {
        Binding(get: { selectedClipID },
                set: { selectedClipID = $0; if $0 != nil { selectedRangeID = nil } })
    }

    private var rangeSelection: Binding<UUID?> {
        Binding(get: { selectedRangeID },
                set: { selectedRangeID = $0; if $0 != nil { selectedClipID = nil } })
    }

    // MARK: - 操作の確定

    /// ジェスチャ確定（`onEnded`）からのモデル編集。**モデルを触るのはここだけ**。
    ///
    /// 編集が no-op（クランプで元の値に戻る等）だと `model.timeline` が変わらず
    /// `onChange(of: model.timeline)` が飛ばないので、ここでも再要求を積む
    /// （トリム中は帯の幅が動いてサムネイル枠がずれているため、積み直さないと灰色が残る）。
    private func commit(_ committed: TimelineInteraction) {
        defer { scheduleThumbnailRefresh() }
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

    func addApplyRangeAtPlayhead() {
        let end = min(playheadTime + Self.defaultApplyRangeLength, totalDuration)
        guard playheadTime < end else { return }
        model.addMosaicApplyRange(fromCompositionTime: playheadTime, to: end)
        reselectApplyRange(near: (playheadTime + end) / 2)
    }

    /// 編集後に区間を引き直す（マージで id が変わり得るため id を保持し続けない）。
    /// 相互排他を効かせるため `rangeSelection` 経由で書く（クリップ選択が残らない）。
    private func reselectApplyRange(near time: Double) {
        let spans = TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges,
                                                  mapping: model.mapping,
                                                  photoSourceIDs: model.timeline.photoSourceIDs)
        rangeSelection.wrappedValue = spans.first { time >= $0.start && time < $0.end }?.rangeID
    }

    private func scrub(toCompositionTime seconds: Double) {
        guard totalDuration > 0 else { return }
        let clamped = min(max(seconds, 0), totalDuration.nextDown)
        model.seekToLatest(position: clamped / totalDuration)
    }

    /// タイムラインを払ったときのシーク（中央のプレイヘッドが指す時刻へ移す）。
    ///
    /// 再生中に指で動かされたときは**再生を止める**。止めないと追従スクロールが指を
    /// 押し返し続ける（一般的な動画編集アプリでも、再生中のスクラブは再生を止める）。
    private func seekFromScroll(to seconds: Double) {
        if model.isPlaying { model.togglePlayback() }
        scrub(toCompositionTime: seconds)
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
        // 音量シートも同様（消えたクリップを指したまま空のシートを開きっぱなしにしない）。
        if let volumeSheetClipID, !model.timeline.clips.contains(where: { $0.id == volumeSheetClipID }) {
            self.volumeSheetClipID = nil
        }
        // 継ぎ目シートも同じ扱い（undo でクリップが消えた状態のシートを開いたままにしない）。
        if let transitionSheetClipID,
           !model.timeline.clips.contains(where: { $0.id == transitionSheetClipID }) {
            self.transitionSheetClipID = nil
        }
    }

}

// MARK: - サムネイル要求

private extension VideoTimelineView {
    /// サムネイル再要求をデバウンスして積む。**再要求のトリガはすべてここを通す。**
    ///
    /// 抑止条件（`TimelineThumbnailStore.canGenerate`）は store 側だけが握っており、
    /// `request` は抑止中でもキューに積むだけで生成を始めない。したがってトリガを増やしても
    /// HW デコーダの制約（同時 1 バッチ・再生中は生成しない）は壊れない。
    /// 実コストは `refreshThumbnailRequests` の走査 CPU だけなので、そこをデバウンスと
    /// 可視範囲限定で抑える。
    private func scheduleThumbnailRefresh() {
        thumbnailRefreshTask?.cancel()
        thumbnailRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.thumbnailRefreshDelay)
            guard !Task.isCancelled else { return }
            refreshThumbnailRequests()
        }
    }

    /// **可視範囲 ± 1 画面**の帯を埋めるサムネイルをまとめて要求する。
    ///
    /// 全長を走査していた版は、長尺 × 高倍率で毎回数千枠を回したうえに
    /// 予算（`thumbnailRequestLimit`）を画面外の枠に使ってしまっていた。
    /// 枠の列挙と優先度（可視中心からの距離）は `TimelineThumbnailPlanner.plan`
    /// （描画側と同じ `TimelineThumbnailLayout.slots` を通す純関数）に任せる。
    ///
    /// **`needsGeneration` で絞ってから `thumbnailRequestLimit` を掛ける順序を保つこと。**
    /// 逆にするとキャッシュ済みも予算を数え、常に同じ順の先頭 2 クリップが予算を食い切って
    /// 3 本目以降が何度 refresh しても 1 件も要求されない（実測: pps=160 / 20 秒クリップ）。
    /// 抑止中（再生・プレビューのデコード中）でもキューには積む（store 側が判断する）。
    /// body からは呼ばない（描画の副作用にしない）。
    private func refreshThumbnailRequests() {
        let clips = model.timeline.clips
        let planned = TimelineThumbnailPlanner.plan(
            layouts: clipLayouts, clips: clips, geometry: geometry,
            visibleRange: TimelineScrollMath.visibleTimeRange(viewport: requestViewport,
                                                              geometry: geometry),
            marginFactor: 1.0,
            preferredSlotWidth: Double(TimelineMetrics.thumbnailSlotWidth),
            sourceDurations: sourceDurations(clips: clips))
        var jobs: [TimelineThumbnailStore.Request] = []
        for slot in planned {
            guard let url = model.sourceURL(forSourceID: slot.sourceID) else { continue }
            // planner は素材実尺クランプを掛けない（キャッシュキーを揃えるのは呼び出し側）。
            let sourceTime = model.timeline.clampedSourceTime(slot.sourceTime, sourceID: slot.sourceID)
            guard thumbnails.needsGeneration(sourceID: slot.sourceID, sourceTime: sourceTime) else { continue }
            jobs.append(TimelineThumbnailStore.Request(sourceID: slot.sourceID, url: url,
                                                       sourceTime: sourceTime))
            if jobs.count >= Self.thumbnailRequestLimit { break }
        }
        guard !jobs.isEmpty else { return }
        thumbnails.request(jobs)
    }

    /// 要求に使うビューポート。初回レイアウト前（幅 0）は先頭 1 画面ぶんで代用する
    /// （幅 0 のままだと可視レンジが空になり、1 枚も要求されないまま止まる）。
    private var requestViewport: TimelineViewport {
        guard viewport.visibleWidth <= 0 else { return viewport }
        return TimelineViewport(scrollOffset: 0,
                                visibleWidth: min(Double(contentWidth), 400),
                                contentWidth: Double(contentWidth))
    }

    /// 素材実尺（sourceID → 秒）。外向きトリムのプレビューで枠が現行 `sourceEnd` の
    /// 1 コマに張り付かないよう planner へ渡す。
    private func sourceDurations(clips: [TimelineClip]) -> [UUID: Double] {
        var durations: [UUID: Double] = [:]
        for clip in clips where durations[clip.sourceID] == nil {
            guard let seconds = model.sourceDuration(forClipID: clip.id) else { continue }
            durations[clip.sourceID] = seconds
        }
        return durations
    }
}
