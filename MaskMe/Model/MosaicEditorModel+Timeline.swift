import AVFoundation
import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` のタイムライン編集 API と Composition 再構築（S4）。
///
/// 編集操作はすべて `TimelineState` の編集ラッパ（純関数）を経由する薄い層で、
/// 変更があったときだけ世代トークン付きの非同期再構築を走らせる。UI 接続は S9。
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

    /// 現在の再生位置でクリップを 2 分割する。
    /// 分割できない位置（クリップ境界・最小尺未満）では何もしない。
    public func splitAtCurrentPosition() {
        let time = compositionTime(forPosition: playbackPosition)
        applyTimelineEdit { $0.splitting(atDisplayTime: time) }
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
        var clampedEnd = sourceEnd
        if let clip = timeline.clips.first(where: { $0.id == id }),
           let asset = sources[clip.sourceID] {
            // 同期取得は load(videoURL:) の初期スキャンと同じ流儀（ローカル素材のみ）。
            let sourceDuration = CMTimeGetSeconds(asset.duration)
            if sourceDuration.isFinite, sourceDuration > 0 {
                clampedEnd = min(sourceEnd, sourceDuration)
            }
        }
        applyTimelineEdit { $0.trimming(clipID: id, sourceStart: sourceStart, sourceEnd: clampedEnd) }
    }

    /// 指定クリップの再生倍率（0.1x〜10x にクランプ）を設定する。
    public func setClipRate(id: UUID, rate: Double) {
        applyTimelineEdit { $0.settingRate(clipID: id, rate: rate) }
    }

    /// 編集ラッパを適用し、変化があれば Composition を再構築する。
    ///
    /// 再生位置は編集前の合成時刻を保持し、再構築後に新しい合成尺へクランプして
    /// 復元する（編集のたびに先頭へ飛ばない）。変化が無い場合（純関数の
    /// 「失敗時は self を返す」契約）は世代も進めず何もしない。
    private func applyTimelineEdit(_ edit: (TimelineState) -> TimelineState) {
        let newState = edit(timeline)
        guard newState != timeline else { return }
        let keepSeconds = compositionTime(forPosition: playbackPosition)
        timeline = newState  // didSet が mapping 追随・世代インクリメント・尺更新を行う
        let generation = timelineGeneration
        // exportVideo が await できるようタスクを世代付きで保持する（本体 doc 参照）。
        // 完了時の後始末は「自分がまだ現行タスクか」を世代で照合してから行う
        // （連打編集で新しいタスクに置き換わっていたら触らない）。
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
        guard generation == timelineGeneration else { return }
        let clipsSnapshot = timeline.clips
        let sourcesSnapshot = sources
        // クリップ未構築・テスト直注入（sources 未登録）では再構築対象が無い。
        // builder に投げると missingSource で誤ったエラー表示になるため何もしない
        // （実アプリの経路では load(videoURL:) が必ず sources を登録している）。
        guard !clipsSnapshot.isEmpty,
              clipsSnapshot.allSatisfy({ sourcesSnapshot[$0.sourceID] != nil }) else { return }
        do {
            let built = try await TimelineCompositionBuilder()
                .build(clips: clipsSnapshot, sources: sourcesSnapshot)
            guard generation == timelineGeneration else { return }  // 古い世代の結果は破棄
            composition = built
            compositionGeneration = generation  // mapping との整合性照合（exportVideo）に使う
            guard let controller = previewController else { return }
            await controller.replaceAsset(built)
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
