import AVFoundation
import Foundation
import MosaicCore

/// クリップ列から `AVMutableComposition` を構築する。
///
/// `AVMutableComposition` は `AVAsset` のサブクラスなので、
/// プレビューの `AVPlayerItem` も書き出しの `AVAssetReader` も
/// 合成結果をそのまま1本の動画として扱える。
///
/// 単一クリップの場合も必ず Composition を経由させる。
/// 「1本のときは素の AVAsset を使う」という分岐を作ると、
/// 単一と複数で挙動が分かれて必ず腐るため。
///
/// **S8: トランジションのある境界では映像・音声とも A/B 2 トラックへ交互配置する。**
/// 重なりの位置と長さは `TimelineMapping`（`clipSpans` / `overlaps`）からしか取らない
/// ＝ builder は独自の重なり計算を持たない。ここがずれると顔位置の写像とフレームが
/// 食い違ってモザイクが漏れる。
struct TimelineCompositionBuilder {
    enum BuildError: Error, Equatable {
        /// クリップが参照する素材が `sources` に無い。
        case missingSource(UUID)
        case noVideoTrack
    }

    /// クリップ間の映像フォーマット（解像度と向き）。
    /// この型の Equatable 比較が「フォーマット混在」の唯一の判定基準で、
    /// `VideoCompositionConditions.from` が videoComposition の装着判定に使う
    /// （S6 までの `mixedVideoFormats` エラーは S8 で解禁され、混在は renderSize へ
    /// 揃えて合成される）。
    struct VideoFormat: Equatable {
        let size: CGSize
        let transform: CGAffineTransform
    }

    /// build の結果一式。
    ///
    /// `videoComposition` / `audioMix` は**装着が必要なときだけ**非 nil になる
    /// （判定は `VideoCompositionPlan.decide` と `needsAudioMix`）。無変換構成では
    /// どちらも nil で、フェーズ1 と同じ無装着の経路を通る
    /// （`CompositionFidelityTests` の bit 同一契約）。
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let audioMix: AVMutableAudioMix?
        /// 顔ランドマーク（素材フレーム基準）を合成フレーム基準へ写すレイアウト。
        let layout: TimelineRenderLayout
        /// 出力解像度（先頭クリップ基準）。**`videoComposition` が nil でもこの値が
        /// 出力サイズになる**（無装着構成は先頭＝唯一のフォーマットがそのまま出る）ので、
        /// UI へ出す値をここから取ること。クリップが 1 本も無いときだけ `.zero`。
        let outputSize: CGSize
        /// 出力枠より大きく、縮小されて収まるクリップの id（UI の注意表示用）。
        /// 判定は `TimelineOutputSummary.downscaledIndices`（コア層の純関数）。
        let downscaledClipIDs: Set<UUID>
        /// BGM（E2）を実際に 1 曲でも載せたか。
        ///
        /// **書き出しの音声経路の判定に必ず渡すこと**
        /// （`AudioExportPipeline.decide(isTrimming:hasAudioMix:hasBackgroundAudio:conditions:)`）。
        /// BGM がある構成を圧縮パススルーで書き出してはならない。
        let hasBackgroundAudio: Bool
        /// 現在のタイムラインに適用すべき書き出し制限（`ExportRestrictionPolicy.decide` の結果）。
        ///
        /// **UI（書き出しボタンの活性・案内表示）と `exportVideo()` の入口は必ずこの値を
        /// 読むこと。** 両者が別々に `ExportRestrictionPolicy.decide` を呼び直すと、
        /// 呼び出しタイミングのずれで「押せたのに止まる／止まるはずが書き出せる」という
        /// 食い違いが起き得る。ここで 1 回だけ判定し、`apply(built:generation:)` を経由して
        /// `MosaicEditorModel.exportRestriction` に届く値が唯一の情報源。
        let exportRestriction: ExportRestriction
    }

    /// 映像トラックの混在判定用フォーマット（naturalSize / preferredTransform）。
    static func videoFormat(of track: AVAssetTrack) async throws -> VideoFormat {
        VideoFormat(size: try await track.load(.naturalSize),
                    transform: try await track.load(.preferredTransform))
    }

    /// 素材（先頭映像トラック）の混在判定用フォーマット。映像トラックが無い素材は
    /// `noVideoTrack`（build に投げても必ず失敗する組）。
    static func videoFormat(of asset: AVAsset) async throws -> VideoFormat {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError.noVideoTrack
        }
        return try await videoFormat(of: track)
    }

    /// - Parameters:
    ///   - clips: 並び順どおりに連結される。`rate ≠ 1` のクリップは挿入後に
    ///     合成尺（素材長 ÷ rate）へ `scaleTimeRange` される（映像・音声とも）。
    ///   - transitions: クリップ境界のトランジション（キーは先行クリップ id）。
    ///     指定があるとその境界でクリップが重なり、A/B トラックへ交互配置される。
    ///   - sources: 素材IDから AVAsset への対応表。
    /// - Parameter audioItems: BGM（E2）。**`TimelineState.effectiveAudioItems(totalDuration:)`
    ///   を通した実効の列を渡すこと**（生の `audioItems` を渡すと、クリップを消して縮んだ
    ///   タイムラインの外へ挿入しにいく）。既定値 `[]` は `transitions` と同じ流儀だが、
    ///   アプリ本体の 2 経路（プレビュー再構築・書き出し）は必ず渡す。
    /// - Parameter isPro: Pro 権限（`Entitlements.shared.isPro` を渡す）。
    ///   `ExportRestrictionPolicy.decide` の入力にのみ使い、`Built.exportRestriction` へ届く。
    ///
    ///   **既定値を置かないこと。** 置くと渡し忘れが黙って通り、その経路だけ
    ///   制限が外れる（無料なのに長尺も 4K も透かし無しで書き出せる）。課金の穴は
    ///   例外が出ないので、気づくのは売上を見たときになる。この案件の他の
    ///   「既定値を置かない」引数（`photoSourceIDs` / `hasAudioMix` /
    ///   `hasBackgroundAudio`）と同じ理由で、渡し忘れをコンパイルエラーにする。
    ///   既定 `true`（無制限）は、権限を意識しない既存の呼び出し（テスト等）の挙動を
    ///   変えないための後方互換値。実アプリの 2 経路
    ///   （プレビュー再構築・書き出し＝どちらも `rebuildComposition`）は必ず明示して渡す。
    func build(clips: [TimelineClip],
               transitions: [UUID: TransitionSpec] = [:],
               audioItems: [AudioItem] = [],
               sources: [UUID: AVAsset],
               isPro: Bool) async throws -> Built {
        let mapping = TimelineMapping(clips: clips, transitions: transitions)
        // 重なりがあるときだけ 2 トラックへ交互配置する。重なりが無い構成では
        // 従来どおり単一トラックのまま（無変換タイムラインの忠実度を壊さない）。
        let usesTwoTracks = !mapping.overlaps.isEmpty

        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.noVideoTrack
        }
        var videoTracks = [videoA]
        var audioTracks = [composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)]
        if usesTwoTracks {
            guard let videoB = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw BuildError.noVideoTrack
            }
            videoTracks.append(videoB)
            audioTracks.append(composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        }

        // トラックごとの書き込み位置（合成時刻）。開始が先なら empty range で埋める。
        var cursors = [CMTime](repeating: .zero, count: videoTracks.count)
        // 実データ（empty range ではない音声）を挿入したトラックの追跡。
        var insertedAudio = [Bool](repeating: false, count: audioTracks.count)
        var placements: [ClipPlacement] = []

        for (index, span) in mapping.clipSpans.enumerated() {
            guard let asset = sources[span.clip.sourceID] else {
                throw BuildError.missingSource(span.clip.sourceID)
            }
            let slot = usesTwoTracks ? index % 2 : 0
            let placement = try await insertClip(
                span: span, asset: asset, isFirst: index == 0,
                into: TrackSlot(video: videoTracks[slot], audio: audioTracks[slot]),
                cursor: &cursors[slot])
            if placement.audioTrack != nil { insertedAudio[slot] = true }
            placements.append(placement)
        }

        // どの素材にも音声が無いトラックは残さない。
        // セグメントが 1 つも無いトラックが残っていると、`VideoMosaicExporter` が
        // formatDescription の無い音声トラックへ reader/writer を組んでしまい、
        // 書き出しが AVFoundation エラー（-11800）で失敗する。
        var survivingAudio: [AVMutableCompositionTrack] = []
        for (slot, track) in audioTracks.enumerated() {
            guard let track else { continue }
            if insertedAudio[slot] {
                survivingAudio.append(track)
            } else {
                composition.removeTrack(track)
            }
        }

        // BGM（E2）。**videoComposition を作る前に挿入する**（後にすると、丸めで
        // composition 尺が伸びたぶん instruction の被覆が足りなくなる）。
        let backgroundTrack = try await insertBackgroundAudio(audioItems, sources: sources,
                                                              into: composition)

        // instruction の被覆に使う尺は「写像の合計」と「実際の composition 尺」の大きい方。
        // 挿入は timescale 600 へ丸められるため composition 尺が写像の合計より数 ms
        // 長くなり得る。短い方を使うと末尾に instruction の隙間ができ、AVFoundation の
        // 検証（再生・書き出し）が破綻する。
        let compositionSeconds = CMTimeGetSeconds(composition.duration)
        let totalDuration = max(mapping.totalDuration,
                                compositionSeconds.isFinite ? compositionSeconds : 0)

        // 出力解像度の**自然な**値の算出は `VideoCompositionFactory.renderSize(for:)` の
        // 単一実装を使う（コア層に再実装しない。表示と実出力が食い違う二重管理を作らない
        // ため。`TimelineOutputSummary` の doc 参照）。無料プランの書き出し制限は、この
        // 自然な値の**結果に対して**判定・縮小する（`ExportRestrictionPolicy` の doc 参照）。
        let naturalOutputSize = placements.first.map { VideoCompositionFactory.renderSize(for: $0.format) }
            ?? .zero
        let exportRestriction = ExportRestrictionPolicy.decide(
            isPro: isPro, durationSeconds: totalDuration, resolution: naturalOutputSize)
        let renderSizeOverride: CGSize?
        if case .exceedsResolution(let limit) = exportRestriction {
            renderSizeOverride = ExportRestrictionPolicy.clampedResolution(
                naturalOutputSize, shortSideLimit: limit)
        } else {
            renderSizeOverride = nil
        }

        let (videoComposition, layout) = VideoCompositionFactory.make(
            placements: placements, overlaps: mapping.overlaps,
            totalDuration: totalDuration, renderSizeOverride: renderSizeOverride)
        let audioMix = AudioMixFactory.make(placements: placements,
                                            overlaps: mapping.overlaps,
                                            tracks: survivingAudio,
                                            backgroundItems: audioItems,
                                            backgroundTrack: backgroundTrack)
        // 実際に適用された出力解像度（縮小したならそのサイズ）。UI・書き出しはこちらを
        // 見ること（`outputSize` の doc 参照）。
        let outputSize = renderSizeOverride ?? naturalOutputSize
        let downscaled = TimelineOutputSummary.downscaledIndices(
            renderSize: outputSize,
            displaySizes: placements.map { VideoCompositionFactory.displaySize(of: $0.format) })
        return Built(composition: composition, videoComposition: videoComposition,
                     audioMix: audioMix, layout: layout, outputSize: outputSize,
                     downscaledClipIDs: Set(downscaled.map { placements[$0].clip.id }),
                     hasBackgroundAudio: backgroundTrack != nil,
                     exportRestriction: exportRestriction)
    }

    /// BGM を専用トラック 1 本へ差し込む（E2）。
    ///
    /// **曲どうしは重ならない**（不変条件 I-A1）ので**トラックは 1 本で足りる**。
    /// 置く位置は合成時刻そのもの（BGM は合成時刻アンカー）。曲間・先頭の隙間は
    /// `insertTimeRange(_:of:at:)` が empty edit として残すので、こちらで埋めない
    /// （`fillGap` のような明示的な穴埋めは要らないし、むしろ empty edit が残ることで
    /// `AudioExportPipeline` が圧縮パススルーを避ける方向に働く）。
    ///
    /// **素材の実尺へクランプする。** 尺を超える区間は `insertTimeRange` が失敗して
    /// 書き出しごと落ちる。編集操作の側でもクランプしているが、下書きの復元や
    /// 音源ファイルの差し替えでは超え得るので、実データを触るここでも守る。
    ///
    /// 1 曲も載らなかったらトラックごと除去して nil を返す（空セグメントだけの
    /// 音声トラックを writer へ渡さない、という既存の規約と同じ）。
    private func insertBackgroundAudio(_ items: [AudioItem],
                                       sources: [UUID: AVAsset],
                                       into composition: AVMutableComposition) async throws
        -> AVMutableCompositionTrack? {
        guard !items.isEmpty,
              let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var inserted = false
        for item in items {
            guard let asset = sources[item.sourceID] else {
                throw BuildError.missingSource(item.sourceID)
            }
            // 音声トラックの無い素材（映像だけの mp4 を選んだ等）は黙って飛ばす。
            // ここで throw すると、選び直すまで書き出しもプレビューも一切できなくなる。
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            let sourceSeconds = CMTimeGetSeconds(asset.duration)
            let end = sourceSeconds.isFinite && sourceSeconds > 0
                ? min(item.sourceEnd, sourceSeconds) : item.sourceEnd
            guard end - item.sourceStart >= AudioItem.minimumDuration else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: item.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: end - item.sourceStart, preferredTimescale: 600))
            try track.insertTimeRange(
                range, of: sourceTrack,
                at: CMTime(seconds: item.compositionStart, preferredTimescale: 600))
            inserted = true
        }
        guard inserted else {
            composition.removeTrack(track)
            return nil
        }
        return track
    }

    /// A/B いずれかのトラック組（同じスロットの映像トラックと音声トラック）。
    private struct TrackSlot {
        let video: AVMutableCompositionTrack
        let audio: AVMutableCompositionTrack?
    }

    /// クリップ 1 本を指定トラックへ差し込み、factory へ渡す合成情報を返す。
    ///
    /// - `cursor` はそのトラックの書き込み位置（合成時刻）。交互配置で空く区間は
    ///   `fillGap` が empty range で埋める。
    /// - `isFirst` のときだけトラックの `preferredTransform` を素材の向きに合わせる
    ///   （videoComposition を装着しない構成での出力の向き）。
    private func insertClip(span: TimelineMapping.ClipSpan,
                            asset: AVAsset,
                            isFirst: Bool,
                            into slot: TrackSlot,
                            cursor: inout CMTime) async throws -> ClipPlacement {
        let video = slot.video
        let audio = slot.audio
        let clip = span.clip
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError.noVideoTrack
        }
        let format = try await Self.videoFormat(of: sourceVideo)
        let frameRate = (try? await sourceVideo.load(.nominalFrameRate)) ?? 0
        if isFirst {
            // videoComposition を装着しない構成では、このトラックの向きが出力の向きになる。
            // 装着する構成では instruction 側に畳み込むためこの値は参照されない。
            video.preferredTransform = format.transform
        }

        // 素材側のレンジなので素材内の長さを使う（`clip.duration` は rate で割った合成尺のため不可）。
        let range = CMTimeRange(
            start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
            duration: CMTime(seconds: clip.sourceEnd - clip.sourceStart, preferredTimescale: 600))
        // 等速クリップにはスケールを掛けない: 無変換タイムラインの出力を
        // フェーズ1と bit 同一に保つ（CompositionFidelityTests の契約）。
        let scaledDuration = clip.rate == 1.0
            ? range.duration
            : CMTime(seconds: clip.duration, preferredTimescale: 600)
        let start = CMTime(seconds: span.start, preferredTimescale: 600)

        // トラック上の空き（交互配置で前のクリップとの間に空く区間）を埋める。
        fillGap(upTo: start, cursor: cursor, video: video, audio: audio)

        try video.insertTimeRange(range, of: sourceVideo, at: start)
        if clip.rate != 1.0 {
            video.scaleTimeRange(
                CMTimeRange(start: start, duration: range.duration), toDuration: scaledDuration)
        }

        var clipAudioTrack: AVMutableCompositionTrack?
        if let audio {
            // 実音声を挿入したクリップだけ audioMix の対象にする
            // （empty range しか無いクリップに音量ランプを引いても意味が無い）。
            let inserted = try await insertAudio(of: asset, range: range,
                                                 scaledDuration: scaledDuration,
                                                 at: start, into: audio)
            if inserted { clipAudioTrack = audio }
        }
        cursor = CMTimeAdd(start, scaledDuration)
        return ClipPlacement(clip: clip, format: format, frameRate: frameRate,
                             track: video, audioTrack: clipAudioTrack,
                             start: span.start, end: span.end)
    }

    /// トラックの書き込み位置と挿入開始位置の間の空きを empty range で埋める。
    ///
    /// A/B 交互配置では 1 本のトラックに「1 つ飛ばし」でクリップが載るため、
    /// 間が必ず空く。暗黙の空きに頼らず明示的に埋めることで、セグメント列が
    /// 合成タイムラインと 1 対 1 に対応する（音声位置ずれの回帰ガード）。
    /// 交互配置しない構成では常に `start == cursor` なので何も起きない（挙動不変）。
    private func fillGap(upTo start: CMTime,
                         cursor: CMTime,
                         video: AVMutableCompositionTrack,
                         audio: AVMutableCompositionTrack?) {
        guard start > cursor else { return }
        let gap = CMTimeRange(start: cursor, duration: CMTimeSubtract(start, cursor))
        video.insertEmptyTimeRange(gap)
        audio?.insertEmptyTimeRange(gap)
    }

    /// クリップ 1 本分の音声を合成トラックへ差し込む。音声は無い素材もあるため、
    /// あるときだけ実データを挿入し、映像と同じ区間を同じ合成尺へスケールして
    /// トラック間の同期を保つ。ピッチ保持は再生・書き出し側の
    /// `audioTimePitchAlgorithm`（`.spectral`）で行う
    /// （`MosaicPreviewController.makePlayerItem` / `VideoMosaicExporter` の再エンコード経路）。
    ///
    /// 音声トラックを持たない素材（写真クリップ等）の区間は明示的に empty range で
    /// 埋める（S6）。これで音声トラックのセグメント列が映像と同じ時間軸を保ち、
    /// 後続クリップの音声挿入位置がずれない。最終的に 1 クリップも音声が無ければ
    /// 呼び出し側がトラックごと除去するため、空セグメントだけの音声トラックが
    /// writer に渡ることもない。
    ///
    /// - Returns: 実データ（empty range ではない音声）を挿入したかどうか。
    private func insertAudio(of asset: AVAsset,
                             range: CMTimeRange,
                             scaledDuration: CMTime,
                             at cursor: CMTime,
                             into audioTrack: AVMutableCompositionTrack) async throws -> Bool {
        guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: scaledDuration))
            return false
        }
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
        // 等速クリップは scaledDuration == range.duration（呼び出し側の計算）なので
        // スケール不要。差があるときだけ映像側と同じ合成尺へスケールする。
        if scaledDuration != range.duration {
            audioTrack.scaleTimeRange(
                CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDuration)
        }
        return true
    }
}
