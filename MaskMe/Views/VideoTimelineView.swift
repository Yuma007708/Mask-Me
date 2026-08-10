import AVFoundation
import MosaicCore
import SwiftUI

/// CapCut 風のマルチクリップタイムライン（S9）。
///
/// 構成（すべて同じ横スクロール内・同じ x 座標系）:
/// - 目盛り帯（`TimelineRulerTrackView`。表示専用）
/// - クリップ帯（`TimelineClipBandView`。選択・トリム・長押し並べ替え・継ぎ目ボタン）
/// - レイヤー段（`TimelineLayerTrackView`。モザイク適用区間トラック等）
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

    /// サムネイルの倉庫。**`@StateObject` にしないこと（＝購読しないこと）。**
    ///
    /// この View は倉庫のメソッド（`setPlaying` / `setSuspended` / `reset` など）を
    /// 呼ぶだけで、画像そのものは読まない。購読すると**コマが 1 枚届くたびに
    /// タイムライン全体の body が作り直される**。実測では、帯を 90px ドラッグする間に
    /// コマが 11 枚届き、そのたびに親が再評価されて **body の作り直しが 25 回**
    /// 走っていた（指の追従は 11 回）。帯の位置が前後にちらつく実機報告の原因。
    ///
    /// 画像を読むのは `TimelineClipBandView` だけなので、購読はあちらの
    /// `@ObservedObject` に閉じる（`trimPreviewRelay` と同じ設計）。
    @State var thumbnails = TimelineThumbnailStore()
    /// 素材ごとの音声波形（`TimelineWaveformStore` の doc 参照。1 素材 1 回で終わる）。
    /// 音声波形の倉庫。`thumbnails` と同じ理由で**購読しない**
    /// （この View は `reset()` を呼ぶだけ。波形を読むのは `TimelineClipBandView`）。
    @State var waveforms = TimelineWaveformStore()
    @Environment(\.scenePhase) private var scenePhase
    @State var geometry = TimelineGeometry()
    @State var speedSheetClipID: UUID?
    /// 音量シートの対象（クリップの元音声 or BGM）。**種を持つ型で持つこと**。
    /// UUID だけにすると、どちらの音量を編集しているのかが型から消える。
    @State var volumeSheetTarget: TimelineVolumeAvailability.Target?
    @State private var transitionSheetClipID: UUID?
    @State var showMediaPicker = false
    /// 音楽ファイル選択（E2）。`.fileImporter` の提示条件。
    @State var showAudioPicker = false
    /// テキスト入力シート（E3）の提示条件。プレイヘッド位置に新規テキストを置く。
    @State var showTextInputSheet = false
    /// スクロールの見え方（トラック内 x 座標系）。`TimelineScrollContainer` が更新し、
    /// サムネイル要求の可視範囲を決めるのに使う。
    @State var viewport = TimelineViewport(scrollOffset: 0, visibleWidth: 0, contentWidth: 0)
    /// 並べ替えドラッグ ⇔ スクロール容器の受け渡し口（`TimelineAutoScrollState` の doc 参照）。
    @StateObject var autoScroll = TimelineAutoScrollState()
    /// デバウンス中のサムネイル再要求。
    @State var thumbnailRefreshTask: Task<Void, Never>?
    /// この View が画面に載っているか（`setSuspended` の入力その 1）。
    @State private var isOnScreen = false
    /// クリップ帯のトリム下書き（表示専用）を適用区間トラックへ渡す中継。
    ///
    /// **`@StateObject` にしないこと。** 購読するとドラッグ中 60Hz でこの View の body が
    /// 再評価され、子のジェスチャが作り直される。`@State` に参照型を入れて**持つだけ**にし、
    /// 購読は追随が要る `TimelineLayerTrackView` にだけ持たせる（`TimelineTrimPreviewRelay` の doc）。
    @State var trimPreviewRelay = TimelineTrimPreviewRelay()
    /// レイヤー段の縦スクロール量（px）。**時間軸とは無関係**
    /// （`TimelineLayerScrollMath` の doc 参照）。
    @State var layerScrollOffset: Double = 0
    /// 縦ドラッグ開始時の `layerScrollOffset`（1 回のドラッグ中の基準）。
    @State var layerScrollDragBase: Double = 0

    /// 1 回の要求で投入するサムネイル枚数の上限（メモリと生成時間の歯止め）。
    ///
    /// **予算は未生成のジョブにだけ使う**（`TimelineThumbnailStore.needsGeneration`）。
    /// キャッシュ済みも数えると、常に同じ順の `clipLayouts` の先頭 2 クリップが予算を
    /// 食い切り、3 本目以降が永久に要求されない。
    static let thumbnailRequestLimit = 120
    /// サムネイル再要求のデバウンス（ナノ秒）。スクロール・ピンチ中は毎フレーム
    /// トリガが飛ぶので、指が止まってからまとめて 1 回だけ走査する。
    static let thumbnailRefreshDelay: UInt64 = 180_000_000

    // MARK: - 導出値

    var totalDuration: Double { max(model.videoDuration, 0) }
    var playheadTime: Double { model.compositionTime(forPosition: model.playbackPosition) }
    var contentWidth: CGFloat { CGFloat(max(geometry.width(forDuration: totalDuration), 1)) }
    var clipLayouts: [TimelineClipLayout] { TimelineBandLayout.clipLayouts(mapping: model.mapping) }
    private var jointLayouts: [TimelineJointLayout] { TimelineBandLayout.jointLayouts(mapping: model.mapping) }
    /// 写真クリップのセグメントは端ハンドルを出さない（`photoSourceIDs` を渡すことで
    /// `isEdgeAdjustable == false` になる。端ドラッグが構造的に no-op なため）。
    var applySpans: [TimelineApplySpan] {
        TimelineBandLayout.applySpans(ranges: model.timeline.applyRanges, mapping: model.mapping,
                                      photoSourceIDs: model.timeline.photoSourceIDs)
    }
    /// BGM の帯（E2）。**合成尺で切った実効だけ**を見せる
    /// （`TimelineBandLayout.audioSpans` の doc 参照。生の `audioItems` を渡すと、
    /// クリップを消して縮んだタイムラインの外へ帯が伸びる）。
    var audioSpans: [TimelineApplySpan] {
        TimelineBandLayout.audioSpans(items: model.timeline.audioItems,
                                      totalDuration: totalDuration)
    }
    // テキストの帯（`textSpans`）と種別選択の Binding（`layerSelection(for:)`）は
    // `VideoTimelineLayerViewport.swift`（file_length の都合で分けた段の器）へ置いてある。

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
            waveforms.reset()
            model.timelineSelection.clear()
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
            model: model, speedClipID: $speedSheetClipID, volumeTarget: $volumeSheetTarget,
            transitionClipID: $transitionSheetClipID, showMediaPicker: $showMediaPicker,
            showAudioPicker: $showAudioPicker, audioInsertTime: playheadTime,
            showTextInputSheet: $showTextInputSheet, textInsertTime: playheadTime))
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
        speedSheetClipID != nil || volumeSheetTarget != nil
            || transitionSheetClipID != nil || showMediaPicker || showAudioPicker
            || showTextInputSheet
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

    /// タイムラインの**下**に置く、この画面で唯一のツールバー。
    ///
    /// 中身は `model.dockRoute` で丸ごと入れ替わる（`EditorDockView`）。旧 UI は
    /// ここ（編集の道具）と画面最下部（モザイクの階層）に段が割れており、
    /// 戻る `‹` は下の段にしか無かったため現在地が読めなかった。
    private var bottomBar: some View {
        EditorDockView(model: model, rootItems: toolItems)
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
        // レイヤー段のアイコン列も**スクロールしない層**（`TimelineLayerRailView` の doc）。
        // 一番下＝レイヤー領域なので `bottomLeading` で段と行が揃う。
        .overlay(alignment: .bottomLeading) {
            TimelineLayerRailView(
                kinds: TimelineLayerRowKind.allCases,
                scrollOffset: layerScrollOffset,
                visibleHeight: TimelineMetrics.layerViewportHeight,
                selectedKind: nil,
                onSelect: { kind in
                    // 中身が未実装の段は押しても何もしない（`isImplemented`）。
                    guard kind.isImplemented else { return }
                    model.enterDock(.face)
                })
        }
        // プレイヘッドは**スクロールしない層**に置き、可視領域の中央へ固定する
        // （`TimelinePlayheadView` の doc）。中身の側に置くと、シークとスクロールの
        // 1 フレームのずれがそのまま線の震えになる。
        //
        // **アイコン列より後に重ねる**（線が列に隠れない）。
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
                    // 物体マスクのキーフレーム位置。帯の上に重ねるだけなので
                    // トラックの高さ（`TimelineMetrics.stackHeight`）は変わらない。
                    .overlay(alignment: .topLeading) { keyframeMarkers }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.clipBand")
            }
            layerViewport
        }
    }

    /// 物体マスクのキーフレーム位置を示す小さなひし形。
    ///
    /// クリップ帯に重ねる（専用トラックを足すとタイムライン全体の高さが変わり、
    /// プレビューが縮む——`TimelineMetrics.toolbarHeight` の doc と同じ理由）。
    /// 出すのは**選択中のクリップに属するマスク**のキーフレームだけ。全マスクを
    /// 常に出すと、クリップが増えたときに帯が点で埋まって何も読めなくなる。
    ///
    /// 分割の境界へ挿入したキーフレームは合成時刻へ写せないので出ない
    /// （`MosaicEditorModel.objectMaskKeyframeMarkers(maskID:)` の doc）。
    @ViewBuilder
    private var keyframeMarkers: some View {
        let times = model.objectMasks
            .filter { $0.anchor.clipID != nil && $0.anchor.clipID == selectedClipID }
            .flatMap { model.objectMaskKeyframeMarkers(maskID: $0.id) }
        ZStack(alignment: .topLeading) {
            ForEach(times, id: \.id) { marker in
                Image(systemName: "diamond.fill")
                    .font(.system(size: 8))
                    // 継ぎ目ボタンと同じ「編集の目印」の色（`TimelinePalette.structure`）。
                    // 以前はここだけ橙で、継ぎ目の黄・モザイク区間の青と合わせて
                    // 3 系統の色が意味なく並んでいた。
                    .foregroundStyle(TimelinePalette.structure)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: geometry.x(forTime: marker.compositionTime) - 4, y: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("timeline.objectMaskKeyframes")
    }

    @ViewBuilder
    private var clipBand: some View {
        if clipLayouts.isEmpty {
            TimelineEmptyBandView(contentWidth: contentWidth,
                                  text: model.isLoading ? "読み込み中…" : "クリップがありません")
        } else {
            TimelineClipBandView(
                model: model, thumbnails: thumbnails, waveforms: waveforms, geometry: geometry,
                layouts: clipLayouts, applySpans: applySpans, playheadTime: playheadTime,
                totalDuration: totalDuration, autoScroll: autoScroll,
                trimPreviewRelay: trimPreviewRelay,
                selectedClipID: clipSelection, onCommit: commit)
        }
    }

    /// 選択は**モデルが持つ**（下部ツールバーが別の段にあり、同じ選択を読むため）。
    /// 相互排他は `TimelineSelection` 側の契約なので、ここは橋渡しだけ。
    /// 子（クリップ帯・レイヤー段）は `Binding<UUID?>` のままで無改造。
    var selectedClipID: UUID? { model.timelineSelection.clipID }
    /// モザイク区間を選んでいるならその id（**種が `.mosaic` のときだけ**）。
    var selectedRangeID: UUID? { model.timelineSelection.layerID(of: .mosaic) }
    /// 種を持つ選択（`TimelineLayerSelection`）。ツールバーはこちらを見る
    /// （`rangeID` shim を経由すると、E2 で音声アイテムを選んだときに
    /// 削除ボタンが黙って「追加」に化ける）。
    var selectedLayer: TimelineLayerSelection? { model.timelineSelection.layer }

    private var clipSelection: Binding<UUID?> {
        Binding(get: { model.timelineSelection.clipID },
                set: { model.timelineSelection.selectClip($0) })
    }

    /// モザイク区間の選択。**種を落とさない**（`layerSelection(for:)` の別名）。
    var rangeSelection: Binding<UUID?> { layerSelection(for: .mosaic) }

    // MARK: - 操作の確定

    /// ジェスチャ確定（`onEnded`）からのモデル編集。**モデルを触るのはここだけ**。
    ///
    /// 編集が no-op（クランプで元の値に戻る等）だと `model.timeline` が変わらず
    /// `onChange(of: model.timeline)` が飛ばないので、ここでも再要求を積む
    /// （トリム中は帯の幅が動いてサムネイル枠がずれているため、積み直さないと灰色が残る）。
    func commit(_ committed: TimelineInteraction) {
        defer { scheduleThumbnailRefresh() }
        switch committed {
        case let .trim(clipID, edge, delta):
            commitTrim(clipID: clipID, edge: edge, delta: delta)
        case let .reorder(clipID, translation):
            guard let target = TimelineBandLayout.reorderTargetIndex(
                layouts: clipLayouts, clipID: clipID, translationSeconds: translation) else { return }
            model.moveClip(id: clipID, toIndex: target)
        case let .applyEdge(rangeID, clipID, kind, start, end):
            commitApplyEdge(rangeID: rangeID, clipID: clipID, kind: kind,
                            interval: CompositionInterval(start: start, end: end))
        case let .applyMove(rangeID, clipID, kind, delta, start, end):
            commitApplyMove(rangeID: rangeID, clipID: clipID, kind: kind, delta: delta,
                            interval: CompositionInterval(start: start, end: end))
        }
    }

    private func commitTrim(clipID: UUID, edge: TimelineTrimEdge, delta: Double) {
        guard let clip = model.timeline.clips.first(where: { $0.id == clipID }) else { return }
        let bounds = TimelineBandLayout.trimmedBounds(
            clip: clip, edge: edge, deltaCompositionSeconds: delta,
            sourceDuration: model.sourceDuration(forClipID: clipID))
        model.trimClip(id: clipID, sourceStart: bounds.sourceStart, sourceEnd: bounds.sourceEnd)
    }

    // `commitApplyEdge` / `commitApplyMove` / `reselectApplyRange` は
    // file_length の都合で `VideoTimelineLayerViewport.swift` へ移してある
    // （あちらもレイヤー段の確定を扱うので境界として自然）。

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

    /// 消えたクリップを指したままのシートを閉じる（削除・undo 後）。
    ///
    /// **クリップ／レイヤーの選択はここでは刈らない。** 選択はモデルが持ち、
    /// `timeline` の didSet が刈る（画面が載っていない間の編集でも漏れないため）。
    private func pruneSelection() {
        if let speedSheetClipID, !model.timeline.clips.contains(where: { $0.id == speedSheetClipID }) {
            self.speedSheetClipID = nil
        }
        // 音量シートも同様（消えたクリップ／BGM を指したまま空のシートを開かない）。
        switch volumeSheetTarget {
        case let .clip(id) where !model.timeline.clips.contains(where: { $0.id == id }):
            volumeSheetTarget = nil
        case let .audio(id) where !model.timeline.audioItems.contains(where: { $0.id == id }):
            volumeSheetTarget = nil
        default:
            break
        }
        // 継ぎ目シートも同じ扱い（undo でクリップが消えた状態のシートを開いたままにしない）。
        if let transitionSheetClipID,
           !model.timeline.clips.contains(where: { $0.id == transitionSheetClipID }) {
            self.transitionSheetClipID = nil
        }
    }

}
