import AVFoundation
import Foundation
import MosaicCore
import UIKit

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

    // MARK: - 写真クリップ（S6）

    /// 写真を静止 mp4 へエンコードし、タイムライン末尾へクリップとして追加する。
    ///
    /// `PhotoClipEncoder`（15fps・上限 60s クランプ・長辺 1920px・EXIF 正規化済み）で
    /// 事前エンコードした mp4 を既存の「動画素材を追加」経路へ無分岐で合流させる:
    /// `sources` 登録 → `TimelineState.appending`（kind = .photo の素材メタ付き）→
    /// 世代トークン付き rebuild → `commitEdit`。下書き保存（`draftSources`）と
    /// undo/redo（EditSnapshot の timeline）は既存機構がそのまま追随する。
    ///
    /// 追加前に解像度・向きを既存素材と照合し、builder の `mixedVideoFormats` と
    /// 同一基準で不一致なら**状態を一切変えずに** reject する（S8 で解禁予定）。
    ///
    /// 検出は写真の全フレームが同一なので素材時刻 t=0 に 1 回だけ seed する。
    /// 以後の lookup・ライブ検出は `resolveSourceTime` の clamp（写真素材 → 素材時刻 0）
    /// でこの seed にヒットし、写真区間で 2 回目以降の実検出・重複 submit は走らない。
    ///
    /// - Parameter seconds: クリップの尺（秒）。既定 3 秒は UI（S9）実装までの固定値。
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
            // 解像度・向きの事前照合。builder の `mixedVideoFormats` と同一基準
            // （`TimelineCompositionBuilder.videoFormat` の Equatable 比較）で、
            // **一切の状態変異（sources 登録・seed・commitEdit）より前に**不一致を弾く。
            // commit 後の非同期 rebuild で落とすと、壊れたクリップ・世代不一致
            // （export 恒久拒否）・汎用エラーが残留し、復旧手段が undo しかなくなる
            // （実測）。reject 時は状態を完全に無変化に保ち、エンコード済み一時 mp4
            // だけ削除する。レターボックス化はしない（S8 の AVVideoComposition が
            // 解像度混在を正式解禁する）。
            guard await photoFormatMatchesTimeline(photoAsset) else {
                try? FileManager.default.removeItem(at: encoded.url)
                errorMessage = "写真の縦横比が動画と一致しないため追加できません（今後対応予定です）"
                return
            }
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

    /// エンコード済み写真素材の映像フォーマットが既存タイムラインと一致するか。
    ///
    /// 基準は先頭クリップの素材（builder が `reference` に取るのと同じ「先頭」。
    /// 既存クリップは構築済み composition の存在により相互一致が保証されている）。
    /// 判定は `TimelineCompositionBuilder.videoFormat` の Equatable 比較で、builder の
    /// `mixedVideoFormats` ガードと同一（判定ロジックの二重実装を避ける）。
    /// フォーマットが取得できない場合も不一致扱い（builder に投げれば必ず失敗する組
    /// なので、事前 reject が安全側）。
    private func photoFormatMatchesTimeline(_ photoAsset: AVAsset) async -> Bool {
        guard let firstClip = timeline.clips.first,
              let referenceAsset = sources[firstClip.sourceID],
              let reference = try? await TimelineCompositionBuilder.videoFormat(of: referenceAsset),
              let photoFormat = try? await TimelineCompositionBuilder.videoFormat(of: photoAsset)
        else { return false }
        return photoFormat == reference
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
