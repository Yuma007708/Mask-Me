import AVFoundation
import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// `MosaicEditorModel` のタイムライン編集 API と Composition 再構築（S4）。
///
/// 編集操作はすべて `TimelineState` の編集ラッパ（純関数）を経由する薄い層で、
/// 変更があったときだけ世代トークン付きの非同期再構築を走らせる。
/// UI（`VideoTimelineView` 一式）は S9 で接続済み。
///
/// **モザイク適用区間の編集も同じ `applyTimelineEdit` を通す。** 適用区間は
/// composition の構成に影響しないので再構築は本来不要だが、`timeline` の didSet が
/// 世代を進める設計上、再構築を省くと `compositionGeneration != timelineGeneration`
/// のまま残り `exportVideo` が「更新が完了していません」で止まる。世代と composition の
/// 整合を唯一の不変条件として保つため、余分な再構築を受け入れている
/// （区間編集はジェスチャ確定時の 1 回だけなので実用上の負荷は split/trim と同等）。
///
/// **注意（Swift の言語制約）**: `timeline` / `timelineGeneration` / `sources` /
/// `composition` は格納プロパティのため、この extension には物理的に移動できず
/// `MosaicEditorModel.swift`（本体）に残っている。
extension MosaicEditorModel {
    // MARK: - 正規化位置 → 合成時刻

    /// 0...1 の正規化再生位置を合成タイムライン時刻（秒）へ変換する唯一の入口。
    ///
    /// `videoDuration` はクリップ構築後 `mapping.totalDuration` に追随する
    /// （`timeline` の didSet 参照）ため、マルチクリップ・rate≠1 でも
    /// `position * videoDuration` が正しい合成時刻になる。S3 まで各所に散っていた
    /// `position * videoDuration` の集約先（seekTo / redetect / detectInRegion）。
    public func compositionTime(forPosition position: Double) -> Double {
        max(0, position) * videoDuration
    }

    // MARK: - 公開編集 API（TimelineState の編集ラッパを呼ぶ薄い層。UI 接続は S9）

    /// 現在の再生位置でクリップを 2 分割する（対象は帰属規則が決める）。
    /// 分割できない位置（クリップ境界・最小尺未満）では何もしない。
    ///
    /// **UI からはこれを使わない**（トランジションの重なり区間で選択と対象が食い違う。
    /// `TimelineState.splitting(atDisplayTime:)` の doc 参照）。UI は
    /// `splitClip(id:)` を使う。
    public func splitAtCurrentPosition() {
        let time = compositionTime(forPosition: playbackPosition)
        applyClipCreatingEdit { $0.splittingEdit(atDisplayTime: time) }
    }

    /// 指定クリップを現在の再生位置で 2 分割する（UI の「分割」ボタンの入口）。
    ///
    /// 対象を id で明示するため、トランジションの重なり区間でも選択したクリップが割れる。
    /// 押せるかどうかの判定は `TimelineState.canSplit(clipID:atDisplayTime:)`
    /// （実行と同じ純関数）を UI がそのまま使うこと。
    public func splitClip(id: UUID) {
        let time = compositionTime(forPosition: playbackPosition)
        applyClipCreatingEdit { $0.splittingEdit(clipID: id, atDisplayTime: time) }
    }

    /// 指定クリップを取り除く（最後の 1 本は消せない）。
    public func removeClip(id: UUID) {
        applyTimelineEdit { $0.removing(clipID: id) }
    }

    /// 指定クリップを複製し、その直後に挿入する（UI の「複製」ボタンの入口）。
    ///
    /// トリム範囲・速度・音量・モザイク適用区間の引き継ぎとトランジションの付け替えは
    /// `TimelineState.duplicating(clipID:)` の doc 参照。**複製後は複製されたほうを選択状態にする**
    /// （続けてトリム・速度調整などを行えるように。一般的な動画編集アプリと同じ挙動）。
    ///
    /// **物体マスク（`ObjectMask`）も複製先へ丸ごとコピーされる**
    /// （`ObjectMaskEditOperations.masks(duplicatingClipID:into:existing:)`。追従は
    /// `applyClipCreatingEdit` が `TimelineEdit.lineage` を見て行う）。
    ///
    /// 複製先の id は `applyTimelineEdit` 適用前後のクリップ id 集合の差分で特定する
    /// （`TimelineState.duplicating` は失敗時に自分自身を返す契約なので、差分が空なら
    /// 複製できなかったということであり、その場合は選択を変えない）。
    public func duplicateClip(id: UUID) {
        let oldIDs = Set(timeline.clips.map(\.id))
        applyClipCreatingEdit { $0.duplicatingEdit(clipID: id) }
        guard let newID = timeline.clips.first(where: { !oldIDs.contains($0.id) })?.id else { return }
        timelineSelection.selectClip(newID)
    }

    /// 指定クリップを `toIndex` の位置へ並べ替える。
    ///
    /// **再生位置は動かしたクリップを追いかける。** 並べ替えは合成時刻の意味を変えるので、
    /// 時刻を据え置くと掴んでいたクリップが画面から消えて別のクリップが映る。
    /// 再生位置が対象クリップの外にいたときは従来どおり時刻を据え置く
    /// （`TimelineState.compositionTime(following:from:to:time:)` が判定する）。
    public func moveClip(id: UUID, toIndex: Int) {
        let newState = timeline.moving(clipID: id, toIndex: toIndex)
        guard newState != timeline else { return }
        let followed = TimelineState.compositionTime(
            following: id, from: timeline, to: newState,
            time: compositionTime(forPosition: playbackPosition))
        replaceTimeline(newState, keepingCompositionSeconds: followed)
        // 再構築の完了を待たずにここでも反映する。`rebuildComposition` の復元は
        // Composition を作れたときにしか走らない（素材未登録では早期 return する）ので、
        // そこだけに任せると再生位置の写像が合成の成否に依存してしまう。
        // 同じ値を入れるので、再構築後の復元と食い違わない。
        if videoDuration > 0 {
            playbackPosition = min(max(followed, 0), videoDuration.nextDown) / videoDuration
        }
        commitEdit()
    }

    /// 指定クリップの素材使用範囲を変更する。
    ///
    /// `sourceEnd` は素材尺にクランプする。素材尺を超える範囲をコア層へ素通しすると
    /// 「1s 素材から 100s のクリップ」が無言で成立し、実体のない区間を含む壊れた
    /// composition ができる（S4 レビューの実測）。素材尺が取れない場合（テスト直注入等）
    /// はクランプせず、コア層の有限性・順序ガードに委ねる。
    public func trimClip(id: UUID, sourceStart: Double, sourceEnd: Double) {
        let clampedEnd = sourceDuration(forClipID: id).map { min(sourceEnd, $0) } ?? sourceEnd
        applyTimelineEdit { $0.trimming(clipID: id, sourceStart: sourceStart, sourceEnd: clampedEnd) }
    }

    /// 指定クリップの再生倍率（0.1x〜10x にクランプ）を設定する。
    public func setClipRate(id: UUID, rate: Double) {
        applyTimelineEdit { $0.settingRate(clipID: id, rate: rate) }
    }

    /// 指定クリップの元音声の音量（0〜1 にクランプ）を設定する。
    ///
    /// 音量は合成尺を変えないので composition の再構築は本来不要だが、
    /// ここでも `applyTimelineEdit` を通す（同ファイル冒頭 doc の規約。世代と
    /// composition の整合が唯一の不変条件なので、再構築を省くと世代だけ進んで
    /// `exportVideo` が恒久的に止まる）。
    public func setClipVolume(id: UUID, volume: Float) {
        applyTimelineEdit { $0.settingVolume(clipID: id, volume: volume) }
    }

    /// 指定クリップを**画面で見て**反時計回りに 90 度回す。
    ///
    /// 向きは合成尺を変えないが、`applyTimelineEdit` を必ず通す
    /// （`setClipVolume` と同じ理由に加えて、**向きは composition の再構築が要る**。
    /// `TimelineRenderLayout` は再構築でしか更新されないので、省くと映像だけ古い
    /// 向きのまま・モザイクの写像だけ新しい向き、という最悪の食い違いになる）。
    public func rotateClipLeft(id: UUID) {
        applyTimelineEdit { $0.rotatingClipLeft(clipID: id) }
    }

    /// 指定クリップを**画面で見て**時計回りに 90 度回す。
    public func rotateClipRight(id: UUID) {
        applyTimelineEdit { $0.rotatingClipRight(clipID: id) }
    }

    /// 指定クリップを**画面で見て**左右反転する。
    public func flipClipHorizontally(id: UUID) {
        applyTimelineEdit { $0.flippingClipHorizontally(clipID: id) }
    }

    /// 指定クリップの色調補正（明るさ・コントラスト・彩度・暖かみ）を設定する（P4）。
    ///
    /// `applyTimelineEdit` 経由なので undo/redo（`EditSnapshot.timeline`）と下書き
    /// （`TimelineState` の Codable）にそのまま載る。色調補正は合成尺・composition の
    /// 構造（トランジション・レターボックス）を一切変えないが、`TimelineStateColorGradeEditing`
    /// の doc どおり `applyTimelineEdit` を通す規約に揃える（他の設定系 API と同じ理由）。
    public func setColorGrade(clipID: UUID, _ colorGrade: ColorGrade) {
        applyTimelineEdit { $0.settingColorGrade(clipID: clipID, colorGrade: colorGrade) }
    }

    /// 現在のタイムラインの**すべての**クリップへ同じ色調補正を適用する（P4）。
    ///
    /// **1 回の `applyTimelineEdit` にまとめる。** クリップごとに `setColorGrade` を
    /// 繰り返し呼ぶと、クリップ数だけ composition 再構築と undo エントリが積まれる
    /// （「すべてのクリップに適用」ボタン 1 回の操作が undo で 1 回に戻らなくなる）。
    public func applyColorGradeToAllClips(_ colorGrade: ColorGrade) {
        applyTimelineEdit { state in
            state.clips.reduce(state) { partial, clip in
                partial.settingColorGrade(clipID: clip.id, colorGrade: colorGrade)
            }
        }
    }

    /// 素材IDに対応するローカルファイル URL（サムネイル生成用）。
    ///
    /// load / 下書き復元 / 写真クリップ追加の経路の asset は常に `AVURLAsset` である。
    /// URL を持たない asset（テスト直注入）では nil。
    public func sourceURL(forSourceID id: UUID) -> URL? {
        (sources[id] as? AVURLAsset)?.url
    }

    /// 指定クリップの素材の実尺（秒）。取得できない場合は nil。
    ///
    /// 用途は 2 つで、どちらも同じ値を見ることが要件:
    /// - `trimClip` の `sourceEnd` クランプ（素材尺を超える範囲をコアへ素通しさせない）
    /// - トリム UI が「右端をどこまで伸ばせるか」を知るため
    ///   （`TimelineBandLayout.trimmedBounds(clip:edge:deltaCompositionSeconds:sourceDuration:)`）
    ///
    /// 同期取得は `load(videoURL:)` の初期スキャンと同じ流儀（ローカル素材のみ）。
    /// 非同期の `load(.duration)` に置き換えないこと（トリムのドラッグ確定は同期経路）。
    public func sourceDuration(forClipID id: UUID) -> Double? {
        guard let clip = timeline.clips.first(where: { $0.id == id }),
              let asset = sources[clip.sourceID] else { return nil }
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // MARK: - トランジション（S9。S8 レビュー m-5 の「編集 API が無い」への対応）

    /// 指定クリップの直後の境界にトランジションを設定する（種類・長さの変更も同じ入口）。
    ///
    /// duration は `TimelineState.maximumTransitionDuration(afterClipID:)`
    /// （= min(両クリップ合成尺)/2）へクランプされる。設定できない境界（末尾クリップ・
    /// クリップが短すぎる）では何もしない。`applyTimelineEdit` 経由なので
    /// undo/redo（`EditSnapshot.timeline`）と下書き v2（`TimelineState` の Codable）に
    /// そのまま載る。
    public func setTransition(afterClipID id: UUID, kind: TransitionKind, duration: Double) {
        applyTimelineEdit { $0.settingTransition(afterClipID: id, kind: kind, duration: duration) }
    }

    /// 指定クリップの直後の境界からトランジションを取り除く。
    public func removeTransition(afterClipID id: UUID) {
        applyTimelineEdit { $0.removingTransition(afterClipID: id) }
    }

    // MARK: - 描画ゲート（S10）
    //
    // 判定ロジックの単一情報源は `MosaicApplyGate` であり、ここは
    // 「モデルが持つ状態（applyRanges / mapping / photoSourceIDs）を束ねて渡すだけ」の
    // 薄い入口である。**数式・判定の二重実装は禁止**（プレビューとエクスポートで
    // 同じ純関数を通すこと。境界フレームで結果が食い違う実装は不可）。
    //
    // ゲートは検出 lookup の**後段・描画直前**にしか置かない。区間外でもライブ検出は
    // 継続して検出キャッシュを埋める（区間を後から広げたときに再検出させないため）。
    // `lookupFaces` / `shouldDetectPreviewFrame` / `storeLiveDetection` /
    // `storePreScanResult` にゲートを入れてはならない。
    //
    // 判定に渡す区間は必ず `effectiveApplyRanges`（孤児区間を除いた有効区間）である。
    // 生の `timeline.applyRanges` をゲートへ渡してはならない（`effectiveApplyRanges` の
    // doc 参照。帯 UI とゲートの一致＝不変条件 I1 の担保がここにある）。

    /// **素材時刻**がモザイク適用区間内かを返す（顔ランドマークの素材別ゲート）。
    ///
    /// 呼び出し元は `displayFaces(at:matching:)` だけ。トランジションの重なり区間では
    /// 素材ごとにこれを通すので、片方の素材が区間内・もう片方が区間外なら
    /// **区間内の素材の顔にだけ**モザイクが乗る。
    ///
    /// 渡す `sourceTime` は必ず「その素材ブランチが lookup に使ったのと同じ素材時刻」。
    /// 合成時刻を渡してはならない（rate ≠ 1 のクリップで区間の位置がずれる）。
    ///
    /// 渡す `clipID` は**クランプ済みの解決結果**
    /// （`resolveSourceLocation(atComposition:)` / `sourceLocations(at:)` の clipID）。
    /// nil は写像不能を意味し、ゲートはフェイルオープンする（判定順序は
    /// `MosaicApplyGate.isActive(ranges:clipID:sourceID:sourceTime:)` の doc 参照）。
    func isMosaicActive(clipID: UUID?, sourceID: UUID, sourceTime: Double) -> Bool {
        MosaicApplyGate.isActive(ranges: effectiveApplyRanges, clipID: clipID,
                                 sourceID: sourceID, sourceTime: sourceTime)
    }

    /// **合成時刻**でモザイクを適用すべきかを返す（素材アンカーを持たない効果のゲート）。
    ///
    /// 手動矩形（`manualRegions`）と背景モザイクは合成タイムライン全体に対する設定で
    /// 素材アンカーを持たないため、素材別には分けられない。判定規則
    /// 「映っている素材のうち 1 つでも区間内なら適用」と、写像範囲外時刻のクランプ規則は
    /// `MosaicApplyGate.isActive(ranges:mapping:compositionTime:photoSourceIDs:)` に
    /// 集約してある（エクスポート `VideoMosaicExporter` も同じ関数を呼ぶ）。
    ///
    /// 渡す時刻は「いま描こうとしているフレームの合成時刻」。プレビューは
    /// `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` が返した**実フレーム時刻**、
    /// エクスポートは**シフト前の PTS** がそれにあたる（ランドマーク検索に使う時刻と
    /// 必ず同じものを渡すこと。食い違うと境界フレームで両経路の結果がずれる）。
    public func isMosaicActive(atComposition time: Double) -> Bool {
        MosaicApplyGate.isActive(ranges: effectiveApplyRanges, mapping: mapping,
                                 compositionTime: time,
                                 photoSourceIDs: timeline.photoSourceIDs)
    }

    // MARK: - 編集の適用（Composition 再構築の起動点）

    /// 編集ラッパを適用し、変化があれば Composition を再構築して編集履歴に確定する。
    ///
    /// 変化が無い場合（純関数の「失敗時は self を返す」契約）は世代も履歴も進めず
    /// 何もしない。履歴確定（`commitEdit`）により、タイムライン編集はパラメータ編集と
    /// 同じ undo/redo スタックに積まれる（S5）。
    /// （`private` にできないのは、素材追加経路（`MosaicEditorModel+TimelineMedia.swift`）が
    /// 同じ入口を通るため。）
    ///
    /// **物体マスクの追従はここで行う**（`followClipEdit(from:to:lineage:)`）。マスクは
    /// `TimelineState` に同居しないので、分割・複製・削除の付け替えを誰かが明示的に呼ぶ必要が
    /// ある。個々の編集 API ではなくこの唯一の入口に置くのは、新しい編集操作を足したときに
    /// 呼び忘れないため。**`commitEdit` より前**に行うこと（後にすると、undo で戻る
    /// スナップショットに追従前のマスクが載る）。
    ///
    /// **クリップを生む編集（分割・複製）はこれではなく `applyClipCreatingEdit` を使うこと。**
    /// 生まれたクリップの理由（`ClipLineage`）は差分から推測できず、推測すると複製が分割として
    /// 処理されて元クリップのマスクが潰れる（`ClipLineage` の doc）。渡し忘れは DEBUG で
    /// `ObjectMaskEditOperations` が落とす。
    func applyTimelineEdit(_ edit: (TimelineState) -> TimelineState) {
        applyEditResult(TimelineEdit(edit(timeline)))
    }

    /// **クリップを生む編集（分割・複製）の入口。** `TimelineState` の `splittingEdit` /
    /// `duplicatingEdit` が返す血統付きの結果をそのまま渡す。`applyTimelineEdit` の
    /// 多重定義にしないのは、クロージャの戻り値型でしか呼び分けられず複数文のクロージャ
    /// （`ensureApplyRangesExist` など）で型推論が壊れるため。
    func applyClipCreatingEdit(_ edit: (TimelineState) -> TimelineEdit) {
        applyEditResult(edit(timeline))
    }

    /// 編集結果の適用本体（`applyTimelineEdit` / `applyClipCreatingEdit` の共通後段）。
    private func applyEditResult(_ result: TimelineEdit) {
        guard result.state != timeline else { return }
        let previous = timeline
        replaceTimeline(result.state)
        followClipEdit(from: previous, to: result.state, lineage: result.lineage)
        commitEdit()
    }

    /// タイムラインを差し替え、世代トークン付きの非同期 Composition 再構築を積む。
    ///
    /// 再生位置は差し替え前の合成時刻を保持し、再構築後に新しい合成尺へクランプして
    /// 復元する（編集のたびに先頭へ飛ばない）。同一状態なら何もしない。
    /// 履歴確定は行わない: 編集 API（`applyTimelineEdit`）は確定するが、
    /// undo/redo の適用（`apply(_:)`）は lastCommitted を自前管理するため。
    ///
    /// - Parameter keepingCompositionSeconds: 復元したい合成時刻。`nil` なら差し替え前の
    ///   再生位置をそのまま保つ。並べ替えのように**合成時刻の意味が変わる**編集は、
    ///   写した先の時刻をここで明示する（`TimelineState.compositionTime(following:from:to:time:)`）。
    func replaceTimeline(_ newState: TimelineState, keepingCompositionSeconds: Double? = nil) {
        guard newState != timeline else { return }
        let keepSeconds = keepingCompositionSeconds ?? compositionTime(forPosition: playbackPosition)
        timeline = newState  // didSet が mapping 追随・世代インクリメント・尺更新を行う
        let generation = timelineGeneration
        // exportVideo が await できるようタスクを世代付きで保持する（本体 doc 参照）。
        // 完了時の後始末は「自分がまだ現行タスクか」を世代で照合してから行う
        // （連打編集・undo 連打で新しいタスクに置き換わっていたら触らない）。
        let task = Task { [weak self] in
            guard let self else { return }
            await self.rebuildComposition(generation: generation, keepingCompositionSeconds: keepSeconds)
            if self.pendingRebuild?.generation == generation { self.pendingRebuild = nil }
        }
        pendingRebuild = (generation: generation, task: task)
    }

    /// 進行中のタイムライン再構築が終わるまで待つ（無ければ即座に戻る）。
    ///
    /// 待機中に新しい編集が積まれた場合は、置き換わった新しいタスクも続けて待つ
    /// （ループ 1 周ごとに await したタスクは完了済みなので前進が保証される）。
    /// エクスポートなど「mapping と composition が同一世代であること」を要する
    /// 処理の入口で呼ぶ。
    func awaitPendingTimelineRebuild() async {
        while let pending = pendingRebuild {
            await pending.task.value
        }
    }

    // MARK: - Composition 再構築（世代トークン付き）

    /// build 結果一式（composition / videoComposition / audioMix / layout /
    /// 出力解像度の要約）を**必ず組で**適用する唯一の入口。
    ///
    /// これらは同じクリップ列から同時に作られており、片方だけ差し替えると
    /// 「旧尺の composition に新しい instruction」「向きだけ二重適用」
    /// 「実出力と食い違う解像度表示」といった不整合が黙って成立する。
    /// 世代トークンの記録もここに揃える。
    func apply(built: TimelineCompositionBuilder.Built, generation: Int) {
        composition = built.composition
        videoComposition = built.videoComposition
        audioMix = built.audioMix
        hasBackgroundAudio = built.hasBackgroundAudio
        builtLayout = built.layout
        // クリップが 1 本も無い build では `.zero` が来る（表示するサイズが無い ＝ nil）。
        let size = built.outputSize
        outputRenderSize = size.width > 0 && size.height > 0 ? size : nil
        outputFrameDuration = built.outputFrameDuration
        // **画面比率を自分で選んでいるときは注意表示を出さない。**
        //
        // `downscaledClipIDs` は「出力枠より大きいクリップ」を機械的に拾うので、
        // 16:9 の素材に 9:16 を選ぶ（＝ TikTok 向けの最も典型的な操作）と必ず立つ。
        // それは画質劣化の警告ではなく**意図した構図変更**なので、警告として出すと
        // 「比率を選ぶと毎回⚠︎が出る」状態になり、本来の用途——解像度混在や
        // 無料プランの上限で意図せず縮む——を知らせる合図として機能しなくなる。
        // 一般的な編集アプリも比率変更でこの種の警告は出さない。
        hasDownscaledClips = !built.downscaledClipIDs.isEmpty
            && timeline.aspectRatio == .source
        exportRestriction = built.exportRestriction
        compositionGeneration = generation  // mapping との整合性照合（exportVideo）に使う
    }

    /// 現在世代で再構築する便宜ラッパ。
    func rebuildComposition(keepingCompositionSeconds keepSeconds: Double? = nil) async {
        await rebuildComposition(generation: timelineGeneration, keepingCompositionSeconds: keepSeconds)
    }

    /// タイムラインから Composition を作り直し、プレビューの AVPlayerItem を差し替える。
    ///
    /// `generation` は呼び出し元が閉じ込めた世代トークン。await を跨ぐたびに
    /// `timelineGeneration` と照合し、途中でタイムラインが再度変わっていたら
    /// 結果を破棄する（連打編集で古い合成結果が新しい状態を上書きしない）。
    ///
    /// - Parameter keepSeconds: 復元したい再生位置（編集前の合成時刻）。
    ///   新しい合成尺にクランプして `playbackPosition` とプレビューへ反映する。
    func rebuildComposition(generation: Int, keepingCompositionSeconds keepSeconds: Double? = nil) async {
        // 再構築の全体（build → replaceAsset → seek）をデコード占有として宣言する。
        // `replaceAsset` と `seek` を個別に囲むだけでは両者の await の隙間で busy が
        // 0 に戻り、その窓でサムネイル生成が始まってしまう。
        beginPreviewDecode()
        defer { endPreviewDecode() }
        // 待ち表示は「遅かったときだけ」。猶予より早く終われば一度も立たない
        // （`isRebuildingComposition` / `beginRebuild` の doc 参照）。
        // **数で持つこと**（連続編集で再構築が重なるため。理由は `rebuildDepth` の doc）。
        beginRebuild()
        defer { endRebuild() }
        guard generation == timelineGeneration else { return }
        let clipsSnapshot = timeline.clips
        let sourcesSnapshot = sources
        // クリップ未構築・テスト直注入（sources 未登録）では再構築対象が無い。
        // builder に投げると missingSource で誤ったエラー表示になるため何もしない
        // （実アプリの経路では load(videoURL:) が必ず sources を登録している）。
        guard !clipsSnapshot.isEmpty,
              clipsSnapshot.allSatisfy({ sourcesSnapshot[$0.sourceID] != nil }) else { return }
        let transitionsSnapshot = timeline.transitions
        // BGM は**実効**（合成尺で切ったもの）だけを composition へ渡す。生の
        // `timeline.audioItems` を渡すと、クリップを消して縮んだタイムラインの外へ
        // 挿入しにいく（`AudioItem` 型の doc の温存規則）。
        // 音源が未登録の曲は composition が組めないので落とす（`missingSource` で
        // 再構築ごと失敗させると、音源を選び直すまで編集が一切できなくなる）。
        let audioItemsSnapshot = timeline
            .effectiveAudioItems(totalDuration: mapping.totalDuration)
            .filter { sourcesSnapshot[$0.sourceID] != nil }
        // 出力の画面比率も await を跨ぐ前に閉じ込める（他のスナップショットと同じ理由）。
        let aspectRatioSnapshot = timeline.aspectRatio
        // 出力枠のクロップも他のスナップショットと同じ位置（await を跨ぐ前）で閉じ込める。
        let cropSnapshot = timeline.crop
        // レターボックスの埋め方も同じ位置（await を跨ぐ前）で閉じ込める。
        let letterboxSnapshot = timeline.background
        let muteRangesSnapshot = timeline.clipAudioMuteRanges
        // BGM ダッキング（E2-3）の根拠も他のスナップショットと同じ位置（await を跨ぐ前）で
        // 閉じ込める（`TimelineCompositionBuilder.build(clipDuckRanges:)` の doc 参照）。
        let duckRangesSnapshot = timeline.clipDuckRanges
        do {
            let built = try await TimelineCompositionBuilder()
                .build(clips: clipsSnapshot, transitions: transitionsSnapshot,
                       audioItems: audioItemsSnapshot, sources: sourcesSnapshot,
                       aspectRatio: aspectRatioSnapshot,
                       clipAudioMuteRanges: muteRangesSnapshot,
                       clipDuckRanges: duckRangesSnapshot,
                       crop: cropSnapshot,
                       letterbox: letterboxSnapshot,
                       isPro: entitlements.isPro)
            guard generation == timelineGeneration else { return }  // 古い世代の結果は破棄
            apply(built: built, generation: generation)
            guard let controller = previewController else { return }
            await controller.replaceAsset(built.composition,
                                          videoComposition: built.videoComposition,
                                          audioMix: built.audioMix)
            guard generation == timelineGeneration else { return }
            let total = mapping.totalDuration
            if total > 0 {
                let clamped = min(max(keepSeconds ?? 0, 0), total.nextDown)
                playbackPosition = clamped / total
                await controller.seek(to: playbackPosition)
            }
        } catch {
            errorMessage = "タイムラインの更新に失敗しました"
        }
    }
}

#endif
