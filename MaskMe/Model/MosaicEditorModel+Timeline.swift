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
        applyTimelineEdit { $0.splitting(atDisplayTime: time) }
    }

    /// 指定クリップを現在の再生位置で 2 分割する（UI の「分割」ボタンの入口）。
    ///
    /// 対象を id で明示するため、トランジションの重なり区間でも選択したクリップが割れる。
    /// 押せるかどうかの判定は `TimelineState.canSplit(clipID:atDisplayTime:)`
    /// （実行と同じ純関数）を UI がそのまま使うこと。
    public func splitClip(id: UUID) {
        let time = compositionTime(forPosition: playbackPosition)
        applyTimelineEdit { $0.splitting(clipID: id, atDisplayTime: time) }
    }

    /// 指定クリップを取り除く（最後の 1 本は消せない）。
    public func removeClip(id: UUID) {
        applyTimelineEdit { $0.removing(clipID: id) }
    }

    /// 指定クリップを `toIndex` の位置へ並べ替える。
    public func moveClip(id: UUID, toIndex: Int) {
        applyTimelineEdit { $0.moving(clipID: id, toIndex: toIndex) }
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

    // MARK: - モザイク適用区間（S9。状態編集と表示まで。描画ゲートの配線は S10）

    /// 合成時刻の区間 [from, to) をモザイク適用区間として追加する。
    ///
    /// UI は合成時刻で操作し、保存は素材時刻アンカーへ写す（`MosaicApplyGate` が担当）。
    /// クリップを跨ぐ区間は素材ごとに分解され、重複・隣接はマージされる。
    public func addMosaicApplyRange(fromCompositionTime from: Double, to: Double) {
        applyTimelineEdit { $0.addingApplyRange(fromCompositionTime: from, to: to) }
    }

    /// 指定した適用区間を取り除く。
    public func removeMosaicApplyRange(id: UUID) {
        applyTimelineEdit { $0.removingApplyRange(id: id) }
    }

    /// 掴んだセグメント（適用区間 × クリップ）を新しい合成区間で置き換える（端ドラッグの確定）。
    ///
    /// 差し替えは素材時刻で行われ、当該クリップの使用範囲外にある素材区間は温存される
    /// （`TimelineState.replacingApplyRange(id:clipID:compositionInterval:)` の doc 参照）。
    /// マージで id が変わり得るので、UI は編集後に区間を引き直すこと。
    public func setMosaicApplyRange(id: UUID, clipID: UUID, interval: CompositionInterval) {
        applyTimelineEdit { $0.replacingApplyRange(id: id, clipID: clipID, compositionInterval: interval) }
    }

    // MARK: - 写真クリップ（S6）

    /// 写真を静止 mp4 へエンコードし、タイムライン末尾へクリップとして追加する。
    ///
    /// `PhotoClipEncoder`（15fps・上限 60s クランプ・長辺 1920px・EXIF 正規化済み）で
    /// 事前エンコードした mp4 を既存の「動画素材を追加」経路へ無分岐で合流させる:
    /// `sources` 登録 → `TimelineState.appending`（kind = .photo の素材メタ付き）→
    /// 世代トークン付き rebuild → `commitEdit`。下書き保存（`draftSources`）と
    /// undo/redo（EditSnapshot の timeline）は既存機構がそのまま追随する。
    ///
    /// **S8 で解像度・向きの混在を正式解禁した**ため、追加前の照合
    /// （旧 `photoFormatMatchesTimeline`）は廃止した。混在するタイムラインは
    /// `AVVideoComposition` が renderSize へアスペクトフィットで揃えて合成し、
    /// 顔座標も同じ配置計算（`TimelineRenderLayout`）で合成フレーム基準へ写される。
    ///
    /// 検出は写真の全フレームが同一なので素材時刻 t=0 に 1 回だけ seed する。
    /// 以後の lookup・ライブ検出は `resolveSourceTime` の clamp（写真素材 → 素材時刻 0）
    /// でこの seed にヒットし、写真区間で 2 回目以降の実検出・重複 submit は走らない。
    ///
    /// - Parameter seconds: クリップの尺（秒）。**固定 3 秒**（S9 の UI に尺の選択肢は無い。
    ///   追加後にクリップ端のトリムで伸縮できるため、追加時の選択 UI は設けていない）。
    ///   上限 60s へのクランプはエンコーダ側が保証する。
    public func appendPhotoClip(image: UIImage, seconds: Double = 3.0) async {
        // クリップ未構築（動画ロード完了前・写真モード）では追加先のタイムラインが無い。
        // 書き出しと同じく、ユーザーが結果を待つ操作なので黙って no-op にしない。
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してから写真を追加してください"
            return
        }
        do {
            let encoded = try await PhotoClipEncoder().encode(image: image, seconds: seconds)
            // load / 復元経路と同じく AVURLAsset として登録する（draftSources が
            // URL を取り出して下書きへコピーできる形）。
            let photoAsset = AVAsset(url: encoded.url)
            let sourceID = UUID()
            sources[sourceID] = photoAsset
            seedPhotoDetection(encoded.normalizedImage, sourceID: sourceID)
            let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: encoded.duration)
            applyTimelineEdit {
                $0.appending(clip: clip, source: TimelineSource(id: sourceID, kind: .photo))
            }
        } catch {
            errorMessage = "写真の追加に失敗しました"
        }
    }

    /// 写真クリップの検出 seed（素材時刻 t=0 の 1 回だけ）。
    ///
    /// ライブ検出・初期スキャンと同じ縮小幅（`downscaleForDetection`）で検出する。
    /// 空結果も記録する: 「スキャン済みで顔なし」の事実が
    /// `shouldDetectPreviewFrame` の再検出とホールドフォールバックの貼り付きを止める
    /// （ライブ検出の空エントリと同じ意味論）。
    private func seedPhotoDetection(_ normalizedImage: UIImage, sourceID: UUID) {
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let faces = scanner.allLandmarks(in: Self.downscaleForDetection(normalizedImage))
        cacheStore.store(faces, sourceID: sourceID, time: 0)
        guard !faces.isEmpty else { return }
        // 写真を追加する意図は「この顔にモザイクを掛けたい」なので即選択する
        // （detectInRegion と同じ理由。未選択のままだと写真区間だけモザイクが乗らない）。
        detectedFaces += faces.map { lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalizedImage),
                       isSelected: true, sourceID: sourceID)
        }
    }

    /// 編集ラッパを適用し、変化があれば Composition を再構築して編集履歴に確定する。
    ///
    /// 変化が無い場合（純関数の「失敗時は self を返す」契約）は世代も履歴も進めず
    /// 何もしない。履歴確定（`commitEdit`）により、タイムライン編集はパラメータ編集と
    /// 同じ undo/redo スタックに積まれる（S5）。
    private func applyTimelineEdit(_ edit: (TimelineState) -> TimelineState) {
        let newState = edit(timeline)
        guard newState != timeline else { return }
        replaceTimeline(newState)
        commitEdit()
    }

    /// タイムラインを差し替え、世代トークン付きの非同期 Composition 再構築を積む。
    ///
    /// 再生位置は差し替え前の合成時刻を保持し、再構築後に新しい合成尺へクランプして
    /// 復元する（編集のたびに先頭へ飛ばない）。同一状態なら何もしない。
    /// 履歴確定は行わない: 編集 API（`applyTimelineEdit`）は確定するが、
    /// undo/redo の適用（`apply(_:)`）は lastCommitted を自前管理するため。
    func replaceTimeline(_ newState: TimelineState) {
        guard newState != timeline else { return }
        let keepSeconds = compositionTime(forPosition: playbackPosition)
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

    /// build 結果一式（composition / videoComposition / audioMix / layout）を
    /// **必ず組で**適用する唯一の入口。
    ///
    /// 4 つは同じクリップ列から同時に作られており、片方だけ差し替えると
    /// 「旧尺の composition に新しい instruction」「向きだけ二重適用」といった
    /// 不整合が黙って成立する。世代トークンの記録もここに揃える。
    func apply(built: TimelineCompositionBuilder.Built, generation: Int) {
        composition = built.composition
        videoComposition = built.videoComposition
        audioMix = built.audioMix
        renderLayout = built.layout
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
        guard generation == timelineGeneration else { return }
        let clipsSnapshot = timeline.clips
        let sourcesSnapshot = sources
        // クリップ未構築・テスト直注入（sources 未登録）では再構築対象が無い。
        // builder に投げると missingSource で誤ったエラー表示になるため何もしない
        // （実アプリの経路では load(videoURL:) が必ず sources を登録している）。
        guard !clipsSnapshot.isEmpty,
              clipsSnapshot.allSatisfy({ sourcesSnapshot[$0.sourceID] != nil }) else { return }
        let transitionsSnapshot = timeline.transitions
        do {
            let built = try await TimelineCompositionBuilder()
                .build(clips: clipsSnapshot, transitions: transitionsSnapshot,
                       sources: sourcesSnapshot)
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
