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
        /// 出力解像度。既定（`TimelineAspectRatio.source`）では先頭クリップ基準で、
        /// 比率を選んでいればその枠、無料プランの上限に当たっていれば縮小後のサイズ。
        /// **`videoComposition` が nil でもこの値が
        /// 出力サイズになる**（無装着構成は先頭＝唯一のフォーマットがそのまま出る）ので、
        /// UI へ出す値をここから取ること。クリップが 1 本も無いときだけ `.zero`。
        let outputSize: CGSize
        /// 出力 1 コマの長さ（秒）。**`videoComposition` が nil でもこの値が実際のコマ間隔**
        /// （無装着構成は素材のフレームレートがそのまま出る）なので、UI へ出す値は
        /// `outputSize` と同じくここから取ること。クリップが 1 本も無いときだけ nil。
        /// 算出は `VideoCompositionFactory.frameDuration(for:)` の単一実装。
        let outputFrameDuration: Double?
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
    /// - Parameter aspectRatio: 出力の画面比率（`TimelineState.aspectRatio`）。
    ///   `.source`（既定）は従来どおり先頭クリップの表示サイズがそのまま出力枠になる。
    ///
    ///   **プレビューと書き出しで比率が食い違わないのは、ここが唯一の入口だからである。**
    ///   この値は `videoComposition.renderSize` と `Built.layout`（顔座標の写像）を
    ///   同時に決め、両者は `MosaicEditorModel.apply(built:generation:)` で必ず組で
    ///   差し替わる。新しい経路からこの builder を呼ぶときは必ず
    ///   `timeline.aspectRatio` を渡すこと（既定値 `.source` は、比率を意識しない
    ///   既存の呼び出し＝テストの挙動を変えないための後方互換値）。
    /// - Parameter clipAudioMuteRanges: クリップ内消音区間（`timeline.clipAudioMuteRanges`）。
    ///   既定値 `[]`（消音なし）は Core 層の規約と同じ「触っていなければ元の音声のまま」
    ///   （`ClipAudioMuteRange` 型の doc 参照）と一致するので、他の「既定値を置かない」
    ///   引数と違い安全に既定化できる。実アプリの 2 経路は必ず `timeline.clipAudioMuteRanges`
    ///   を渡す。
    /// - Parameter clipDuckRanges: BGM ダッキング（E2-3）の根拠となる声区間
    ///   （`timeline.clipDuckRanges`）。既定値 `[]`（ダッキングなし）は
    ///   `clipAudioMuteRanges` と同じ理由で安全に既定化できる。実アプリの 2 経路は必ず
    ///   `timeline.clipDuckRanges` を渡す。
    /// - Parameter crop: 出力枠のクロップ（`timeline.crop`）。既定値 `.full`（クロップなし）は
    ///   `aspectRatio` と同じく、クロップを意識しない既存の呼び出し（テスト等）の挙動を
    ///   変えないための後方互換値。実アプリの 2 経路は必ず `timeline.crop` を渡す。
    ///   段の順序は `outputSizing(placements:aspectRatio:crop:isPro:totalDuration:)` の doc 参照
    ///   （自然な枠 → 画面比率 → クロップ → 無料プランの上限）。
    func build(clips: [TimelineClip],
               transitions: [UUID: TransitionSpec] = [:],
               audioItems: [AudioItem] = [],
               sources: [UUID: AVAsset],
               aspectRatio: TimelineAspectRatio = .source,
               clipAudioMuteRanges: [ClipAudioMuteRange] = [],
               clipDuckRanges: [ClipDuckRange] = [],
               crop: CropRect = .full,
               // **`background` という名前は使わない。** この関数の中では既に
               // BGM トラック（`let background = ...`）がその名前を使っており、
               // 同名にすると「音の背景」と「絵の余白」が同じ語で 2 つ存在する。
               letterbox: TimelineBackground = .default,
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
        // **戻り値の `items` を audioMix へ渡すこと**（生の `audioItems` ではない）。
        // 挿入側は音源の実尺へクランプし、載らなかった曲を落とすので、両者は食い違う。
        let background = try await insertBackgroundAudio(audioItems, sources: sources,
                                                         into: composition)
        let backgroundTrack = background.track

        // instruction の被覆に使う尺は「写像の合計」と「実際の composition 尺」の大きい方。
        // 挿入は timescale 600 へ丸められるため composition 尺が写像の合計より数 ms
        // 長くなり得る。短い方を使うと末尾に instruction の隙間ができ、AVFoundation の
        // 検証（再生・書き出し）が破綻する。
        let compositionSeconds = CMTimeGetSeconds(composition.duration)
        let totalDuration = max(mapping.totalDuration,
                                compositionSeconds.isFinite ? compositionSeconds : 0)

        let sizing = Self.outputSizing(placements: placements, aspectRatio: aspectRatio,
                                       crop: crop, isPro: isPro, totalDuration: totalDuration)
        let naturalOutputSize = sizing.natural
        let clampedOutputSize = sizing.clamped
        let exportRestriction = sizing.restriction
        let renderSizeOverride = sizing.renderSizeOverride
        let preCropFrameOverride = sizing.preCropFrameOverride

        let (videoComposition, layout) = VideoCompositionFactory.make(
            placements: placements, overlaps: mapping.overlaps,
            totalDuration: totalDuration, crop: crop, background: letterbox,
            preCropFrameOverride: preCropFrameOverride, renderSizeOverride: renderSizeOverride)
        let audioMix = AudioMixFactory.make(
            placements: placements, overlaps: mapping.overlaps, tracks: survivingAudio,
            mapping: mapping, muteRanges: clipAudioMuteRanges, backgroundItems: background.items,
            backgroundTrack: backgroundTrack, clipDuckRanges: clipDuckRanges)
        // 実際に適用された出力解像度（縮小したならそのサイズ）。UI・書き出しはこちらを
        // 見ること（`outputSize` の doc 参照）。
        let outputSize = clampedOutputSize
        let downscaled = TimelineOutputSummary.downscaledIndices(
            renderSize: outputSize,
            displaySizes: placements.map {
                VideoCompositionFactory.displaySize(of: $0.format,
                                                    orientation: $0.clip.orientation)
            })
        // 1 コマの長さも「実際に出るもの」を 1 箇所で決めて配る（`outputSize` と同じ規約）。
        // `videoComposition` を装着しない構成でも素材のフレームレートは分かるので、
        // UI が既定値 30fps へ落ちずに済む。
        let frameSeconds = CMTimeGetSeconds(VideoCompositionFactory.frameDuration(for: placements))
        return Built(composition: composition, videoComposition: videoComposition,
                     audioMix: audioMix, layout: layout, outputSize: outputSize,
                     outputFrameDuration: placements.isEmpty || !frameSeconds.isFinite
                         || frameSeconds <= 0 ? nil : frameSeconds,
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
    ///
    /// ## 戻り値の `items` を必ず audioMix へ渡すこと
    ///
    /// ここは音源の実尺へクランプし、音声トラックの無い素材・短すぎる区間を**落とす**。
    /// つまり「タイムライン上の曲の一覧」と「実際にトラックへ載った曲の一覧」は食い違う。
    /// 生の一覧を `AudioMixFactory` へ渡すと**フェードアウトが無音区間に落ちる**:
    /// 曲の後ろが実尺で切られているのに、ランプは切られる前の `compositionEnd` を
    /// 基準に置かれるため、音が鳴っている間はずっと最大音量のままで、フェードは
    /// 音が終わった後の何も無いところで進む＝**ぶつ切りに聞こえる**。
    /// `AudioMixFactory.make` の `backgroundItems` の doc（「実際に載った曲を渡すこと」）
    /// が指しているのはこの食い違いのこと。
    private func insertBackgroundAudio(_ items: [AudioItem],
                                       sources: [UUID: AVAsset],
                                       into composition: AVMutableComposition) async throws
        -> (track: AVMutableCompositionTrack?, items: [AudioItem]) {
        guard !items.isEmpty,
              let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { return (nil, []) }
        var insertedItems: [AudioItem] = []
        for item in items {
            guard let asset = sources[item.sourceID] else {
                throw BuildError.missingSource(item.sourceID)
            }
            // 音声トラックの無い素材（映像だけの mp4 を選んだ等）は黙って飛ばす。
            // ここで throw すると、選び直すまで書き出しもプレビューも一切できなくなる。
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            // **`asset.duration` ではなく音声トラックの終端で切ること。**
            // `asset.duration` は全トラックの最大長なので、映像 12 秒・音声 3 秒の
            // mp4 を BGM の音源に選ぶと 12 秒まで載ると誤判定する。実際に鳴るのは
            // 3 秒までなので、フェードアウトが音の終わった後に置かれる（＝上の doc の
            // 「無音区間に落ちる」がこの経路で残っていた）。音源に映像ファイルを
            // 選べることは `test_backgroundAudio_sourceWithoutAudioTrack_isSkipped` の
            // 前提でもある。
            let trackEnd = CMTimeGetSeconds(
                CMTimeRangeGetEnd(try await sourceTrack.load(.timeRange)))
            let end = trackEnd.isFinite && trackEnd > 0
                ? min(item.sourceEnd, trackEnd) : item.sourceEnd
            guard end - item.sourceStart >= AudioItem.minimumDuration else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: item.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: end - item.sourceStart, preferredTimescale: 600))
            try track.insertTimeRange(
                range, of: sourceTrack,
                at: CMTime(seconds: item.compositionStart, preferredTimescale: 600))
            // 実尺で切った姿を記録する。`sourceEnd` を縮めると `duration` が縮むので、
            // フェードは `clampFades()` で新しい尺の半分へ丸め直す（丸めないと
            // フェードインの終わりよりフェードアウトの始まりが前に来る）。
            var effective = item
            effective.sourceEnd = end
            effective.clampFades()
            insertedItems.append(effective)
        }
        guard !insertedItems.isEmpty else {
            composition.removeTrack(track)
            return (nil, [])
        }
        return (track, insertedItems)
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

// MARK: - 出力サイズの決定
//
// `OutputSizing` / `outputSizing(placements:aspectRatio:crop:isPro:totalDuration:)` は
// `TimelineCompositionBuilder+OutputSizing.swift` へ分けてある（`function_body_length` /
// `file_length` 対策。`build` とこのファイルが上限に達したため）。
