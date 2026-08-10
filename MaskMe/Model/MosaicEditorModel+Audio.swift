import AVFoundation
import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` の BGM（E2）編集 API。
///
/// `MosaicEditorModel+Timeline.swift` が file_length の閾値に張り付いているため
/// 分けてある。編集はすべて `applyTimelineEdit` を通す（undo/redo と下書きに載せる、
/// という同ファイルの規約は変わらない）。
extension MosaicEditorModel {
    // MARK: - BGM（E2）

    /// 音楽ファイルを BGM として取り込む（UI からの入口）。
    ///
    /// `appendVideoClip(url:)` と同じ骨格: `AVAsset(url:)` として `sources` へ登録し、
    /// 状態は `applyTimelineEdit` 経由で足す。`AVURLAsset` で登録するので
    /// `draftSources` が下書きへコピーでき、undo/redo にも載る。
    ///
    /// **音声トラックの有無をここで確かめる。** 映像だけのファイルを選んでも
    /// composition 側は黙って飛ばす（書き出しを落とさないため）ので、入口で弾かないと
    /// 「追加したのに帯も出ない」が理由の分からない無反応になる。
    public func appendAudioItem(url: URL, atCompositionTime start: Double) async {
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してから音楽を追加してください"
            return
        }
        let asset = AVAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? .nan
        guard seconds.isFinite, seconds > 0 else {
            errorMessage = "音楽の追加に失敗しました"
            return
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            errorMessage = "このファイルには音声が入っていません"
            return
        }
        let sourceID = UUID()
        registerAudioSource(id: sourceID, asset: asset)
        let before = timeline.audioItems.count
        addAudioItem(sourceID: sourceID, sourceDuration: seconds, atCompositionTime: start)
        // 置けなかった（既存の曲の内側・隙間が足りない）ときは登録した音源を戻す。
        // 残すと下書きへ「どこからも参照されない音源」がコピーされ続ける。
        if timeline.audioItems.count == before {
            sources[sourceID] = nil
            var state = timeline
            state.sources[sourceID] = nil
            timeline = state
            errorMessage = "ここには音楽を置けません（別の曲と重なっています）"
        }
    }

    /// BGM を 1 曲追加する（`atCompositionTime` から素材の全長ぶん。次の曲の手前で切る）。
    ///
    /// **音源は先に `sources` へ登録しておくこと。** 未登録のまま追加すると、
    /// 状態には載るが composition には載らない（`rebuildComposition` が落とす）。
    public func addAudioItem(sourceID: UUID, sourceDuration: Double,
                             atCompositionTime start: Double) {
        applyTimelineEdit {
            $0.addingAudioItem(sourceID: sourceID, sourceDuration: sourceDuration,
                               atCompositionTime: start)
        }
    }

    /// 指定した BGM を取り除く。
    public func removeAudioItem(id: UUID) {
        applyTimelineEdit { $0.removingAudioItem(id: id) }
    }

    /// 指定した BGM を合成時刻で `delta` 秒だけ平行移動する（隣の曲はすり抜けない）。
    public func moveAudioItem(id: UUID, byCompositionDelta delta: Double) {
        applyTimelineEdit { $0.movingAudioItem(id: id, byCompositionDelta: delta) }
    }

    /// 指定した BGM の端を合成時刻で `delta` 秒だけ動かす（つまみの伸縮）。
    ///
    /// 音源の実尺は `sources` から引く。取れない場合は現在の `sourceEnd` を上限として渡す
    /// （伸ばせないだけで壊れない。`TimelineState.trimmingAudioItem` の契約）。
    public func trimAudioItem(id: UUID, edge: TimelineTrimEdge, byCompositionDelta delta: Double) {
        let fallback = timeline.audioItems.first { $0.id == id }?.sourceEnd ?? 0
        let duration = audioSourceDuration(forItemID: id) ?? fallback
        applyTimelineEdit {
            $0.trimmingAudioItem(id: id, edge: edge, byCompositionDelta: delta,
                                 sourceDuration: duration)
        }
    }

    /// 指定した BGM の音量（0...1）を設定する。元動画の音量とは独立。
    public func setAudioVolume(id: UUID, volume: Float) {
        applyTimelineEdit { $0.settingAudioVolume(id: id, volume: volume) }
    }

    /// 指定した BGM のフェードイン／アウト時間（秒）を設定する（E2-2）。
    ///
    /// 上限（`duration / 2`）は `TimelineState.settingAudioFade` が丸める。
    /// ここでは呼び出しを `applyTimelineEdit` へ橋渡しするだけ（undo/redo・下書きに載せる）。
    public func setAudioFade(id: UUID, fadeIn: Double, fadeOut: Double) {
        applyTimelineEdit { $0.settingAudioFade(id: id, fadeIn: fadeIn, fadeOut: fadeOut) }
    }

    /// BGM の音源の実尺（秒）。取得できない場合は nil。
    ///
    /// `sourceDuration(forClipID:)` と同じ流儀（同期取得・ローカル素材のみ）。
    /// 端ドラッグの確定は同期経路なので `load(.duration)` へ置き換えないこと。
    public func audioSourceDuration(forItemID id: UUID) -> Double? {
        guard let item = timeline.audioItems.first(where: { $0.id == id }),
              let asset = sources[item.sourceID] else { return nil }
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// BGM の音源を登録する（`sources` への追加と素材種別の記録）。
    ///
    /// **`addAudioItem` の前に必ず呼ぶこと。** 音源が `sources` に無いと、状態には
    /// 載るのに composition には載らない（帯は出るのに鳴らない）。
    ///
    /// 素材種別（`TimelineSource.Kind.audio`）も同時に記録する。記録しないと
    /// `TimelineState.sources` のエントリが無い扱い＝動画とみなされ、写真判定や
    /// 将来の種別分岐が誤る。
    public func registerAudioSource(id: UUID, asset: AVAsset) {
        sources[id] = asset
        var state = timeline
        state.sources[id] = TimelineSource(id: id, kind: .audio)
        timeline = state
    }
}

#endif
