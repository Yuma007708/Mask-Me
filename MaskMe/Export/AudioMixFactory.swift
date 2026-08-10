import AVFoundation
import Foundation
import MosaicCore

/// `VideoCompositionFactory.swift` が file_length の閾値に張り付いているため分けてある。
/// 中身は同ファイルの一部で、`VideoCompositionFactory` と対になる音声側の factory。
///
/// トランジションの音声クロスフェードと、クリップごとの元音声音量
/// （`TimelineClip.originalAudioVolume`）を `AVMutableAudioMix` にまとめる。
///
/// 映像側（`VideoCompositionFactory`）と同じ重なりモデル（`TimelineMapping.overlaps`）
/// から作るので、音と絵のクロスフェード区間が必ず一致する。
///
/// **audioMix を付けたら音声はパススルーできない**（元パケットのコピーには音量が
/// 反映されない）。`AudioExportPipeline.decide(isTrimming:hasAudioMix:conditions:)` が
/// 再エンコード経路を強制する。
enum AudioMixFactory {
    /// - Returns: 必要なとき（重なりがある / 音量が 1.0 でないクリップがある /
    ///   区間ミュートが掛かっている）だけ非 nil。無変換構成では nil を返し、
    ///   従来のパススルー経路を温存する。
    /// - Parameters:
    ///   - mapping: `placements` と同じ build から作った `TimelineMapping`。
    ///     区間ミュート（素材時刻アンカー）を合成時刻へ写す唯一の経路として使う。
    ///     **自前の式を書かないこと**（`rate ≠ 1` のクリップでずれる。同ファイルの
    ///     doc 参照）。
    ///   - muteRanges: クリップ内消音区間（`TimelineState.clipAudioMuteRanges`）。
    ///     ON/OFF の判定は必ず `ClipAudioMuteGate.isMuted` を通す
    ///     （判定式をここへ書き写さない）。
    ///   - backgroundItems: BGM（E2）。**`backgroundTrack` へ実際に載った曲**を渡すこと。
    ///   - backgroundTrack: BGM 専用トラック（無ければ nil）。元音声のトラック
    ///     （`tracks`）とは**別の入力パラメータ**を持つ。これが「元動画の音と BGM の
    ///     音量を別々に調整できる」ことの実体である。
    ///   - clipDuckRanges: BGM ダッキング（E2-3）の根拠となる声区間（`timeline.clipDuckRanges`）。
    ///     **無音クリップの区間・区間ミュートに掛かる部分は、ここではなく `make` の中で
    ///     `AudioDuckingFilter.audibleVoiceRanges` を通して都度絞り込む**（音量やミュートを
    ///     後から変えても、保存済みの検出結果を書き換えずに追随させるため）。既定値 `[]`
    ///     は「ダッキングなし」で他の「既定値を置いてよい」引数と同じ安全な既定。
    static func make(placements: [ClipPlacement],
                     overlaps: [TimelineMapping.Overlap],
                     tracks: [AVMutableCompositionTrack],
                     mapping: TimelineMapping,
                     muteRanges: [ClipAudioMuteRange] = [],
                     backgroundItems: [AudioItem] = [],
                     backgroundTrack: AVMutableCompositionTrack? = nil,
                     clipDuckRanges: [ClipDuckRange] = []) -> AVMutableAudioMix? {
        // BGM があるならトラックが無くても mix は要る（BGM だけの構成）。
        guard !tracks.isEmpty || backgroundTrack != nil else { return nil }
        let needsVolume = placements.contains { clampedVolume($0.clip.originalAudioVolume) != 1.0 }
        // 区間ミュートが実際に置かれているクリップが 1 本でもあるか。
        let hasMuteRanges = !muteRanges.isEmpty && placements.contains { placement in
            muteRanges.contains { $0.clipID == placement.clip.id }
        }
        // **BGM がある構成では常に mix を作る。** 音量が既定（1.0）でも作るのは、
        // ここが nil になると `hasAudioMix` が false になり、書き出しが圧縮パススルーへ
        // 落ちる経路が 1 つ増えるためである（`AudioExportPipeline` の
        // `hasBackgroundAudio` と二重の守りにする）。区間ミュートも同じ理由で
        // ここへ足す（無いと消音区間だけの構成がパススルーへ落ち、消音が効かなくなる）。
        let hasBackground = backgroundTrack != nil
        guard !overlaps.isEmpty || needsVolume || hasBackground || hasMuteRanges else { return nil }

        // トラック順に固定して作る（辞書順の非決定性を持ち込まない）。
        let parameters: [(track: AVMutableCompositionTrack, params: AVMutableAudioMixInputParameters)] =
            tracks.map { ($0, AVMutableAudioMixInputParameters(track: $0)) }

        for placement in placements {
            guard let audioTrack = placement.audioTrack,
                  let entry = parameters.first(where: { $0.track === audioTrack }) else { continue }
            applyVolumeKeyframes(to: entry.params, placement: placement, overlaps: overlaps,
                                 mapping: mapping, muteRanges: muteRanges)
        }

        // BGM トラック（E2）。**曲ごとに区切りを打ち直す。**
        //
        // トラックは 1 本を共有するので、曲の切れ目で `setVolume(_:at:)` を打ち直す
        // 必要がある（曲 A を 0.3、曲 B を 1.0 にしたとき、B の頭で戻さないと
        // A の音量が最後まで効き続ける）。曲どうしは重ならないので、開始時刻に
        // 打つだけで足りる。
        // **フェード（E2-2）とダッキング（E2-3）は `applyBackgroundKeyframes` へ
        // 集約する**（元音声側の `applyVolumeKeyframes` と同じ「区切りごとに 1 回だけ
        // 打つ」構造。両者は乗算で重ねる。詳細は同関数の doc）。
        var backgroundParams: AVMutableAudioMixInputParameters?
        if let backgroundTrack {
            let params = AVMutableAudioMixInputParameters(track: backgroundTrack)
            // ダッキングの絞り込み（無音クリップ・区間ミュートの除外）はここで一度だけ行う。
            // 曲ごとに繰り返し計算しても結果は同じだが、無駄な再計算を避ける。
            let audibleDuckRanges = AudioDuckingFilter.audibleVoiceRanges(
                clipDuckRanges, clips: placements.map(\.clip), muteRanges: muteRanges)
            for item in backgroundItems.sorted(by: { $0.compositionStart < $1.compositionStart }) {
                applyBackgroundKeyframes(to: params, item: item,
                                        duckRanges: audibleDuckRanges, mapping: mapping)
            }
            backgroundParams = params
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters.map(\.params) + [backgroundParams].compactMap { $0 }
        return mix
    }

    /// 音量は 0...1 にクランプする。NaN は min/max を素通りするため等倍（1）に落とす
    /// （`TimelineClip.clampedRate` と同じ流儀）。
    static func clampedVolume(_ volume: Float) -> Float {
        volume.isNaN ? 1 : min(max(volume, 0), 1)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - 1 クリップぶんの音量キーフレーム（クロスフェード ＋ 区間ミュート）

    /// 1 クリップの音声区間 `[placement.start, placement.end)` に音量キーフレームを積む。
    ///
    /// **クロスフェードのランプと区間ミュートが同居しても打ち消し合わないよう**、
    /// 両方の境界時刻（トランジションの重なり境界 ＋ ミュート区間の境界）を合成時刻の
    /// 「区切り」として集め、区切りの間ごとに 1 回だけ `setVolume` / `setVolumeRamp` を
    /// 置く。ミュート区間の中はホールド 0、外はクロスフェードの本来の値
    /// （`baselineVolume`）を置くので、ミュート区間がランプの途中に掛かっても
    /// ランプの残りは正しい値から再開する。
    /// 1 クリップぶんの音量キーフレーム計算に要る材料の束
    /// （`applyVolumeKeyframes` の分割用。関数の引数個数を絞るためだけの型）。
    private struct VolumeContext {
        let clip: TimelineClip
        let volume: Float
        let incoming: TimelineMapping.Overlap?
        let outgoing: TimelineMapping.Overlap?
        let mapping: TimelineMapping
        let muteRanges: [ClipAudioMuteRange]
    }

    private static func applyVolumeKeyframes(to params: AVMutableAudioMixInputParameters,
                                             placement: ClipPlacement,
                                             overlaps: [TimelineMapping.Overlap],
                                             mapping: TimelineMapping,
                                             muteRanges: [ClipAudioMuteRange]) {
        let clip = placement.clip
        let context = VolumeContext(
            clip: clip, volume: clampedVolume(clip.originalAudioVolume),
            incoming: overlaps.first { $0.incomingClipID == clip.id },
            outgoing: overlaps.first { $0.outgoingClipID == clip.id },
            mapping: mapping, muteRanges: muteRanges)
        let sorted = breakpoints(for: placement, context: context)
        guard sorted.count >= 2 else {
            params.setVolume(context.volume, at: time(placement.start))
            return
        }
        for index in 0..<(sorted.count - 1) {
            let t0 = sorted[index]
            let t1 = sorted[index + 1]
            guard t1 > t0 else { continue }
            emitSegment(to: params, from: t0, to: t1, context: context)
        }
    }

    /// クロスフェードの重なり境界 ＋ 区間ミュートの境界を、この配置区間
    /// `[placement.start, placement.end]` 内の合成時刻の「区切り」として集める。
    ///
    /// 区間ミュートの境界（素材時刻）は、この build と同じ `mapping` で合成時刻へ写す。
    /// `compositionTime` は半開区間 [sourceStart, sourceEnd) しか受け付けないため、
    /// 終端がクリップの `sourceEnd` そのものに一致するときは `.nextDown` へ逃がす
    /// （`TimelineMapping.sourceLocation` と同じ流儀）。
    private static func breakpoints(for placement: ClipPlacement, context: VolumeContext) -> [Double] {
        let clip = context.clip
        var points: Set<Double> = [placement.start, placement.end]
        if let incoming = context.incoming { points.insert(incoming.start); points.insert(incoming.end) }
        if let outgoing = context.outgoing { points.insert(outgoing.start); points.insert(outgoing.end) }
        for muteRange in context.muteRanges
        where muteRange.clipID == clip.id && muteRange.sourceID == clip.sourceID {
            let start = max(muteRange.sourceStart, clip.sourceStart)
            let end = min(muteRange.sourceEnd, clip.sourceEnd)
            guard start < end else { continue }
            let clampedEnd = min(end, clip.sourceEnd.nextDown)
            if let t = context.mapping.compositionTime(clipID: clip.id, sourceTime: start) { points.insert(t) }
            if let t = context.mapping.compositionTime(clipID: clip.id, sourceTime: clampedEnd) { points.insert(t) }
        }
        return points.filter { $0 >= placement.start && $0 <= placement.end }.sorted()
    }

    /// 区切り 1 つぶんの音量キーフレームを積む（ミュート優先、外はクロスフェードの本来値）。
    private static func emitSegment(to params: AVMutableAudioMixInputParameters,
                                    from t0: Double, to t1: Double, context: VolumeContext) {
        if isMuted(clip: context.clip, mapping: context.mapping,
                  atCompositionTime: t0, muteRanges: context.muteRanges) {
            params.setVolume(0, at: time(t0))
            return
        }
        let v0 = baselineVolume(at: t0, volume: context.volume,
                                incoming: context.incoming, outgoing: context.outgoing)
        let v1 = baselineVolume(at: t1, volume: context.volume,
                                incoming: context.incoming, outgoing: context.outgoing)
        if abs(Double(v0) - Double(v1)) < 1e-6 {
            params.setVolume(v0, at: time(t0))
        } else {
            params.setVolumeRamp(fromStartVolume: v0, toEndVolume: v1,
                                 timeRange: CMTimeRange(start: time(t0), end: time(t1)))
        }
    }

    /// 合成時刻 `t` がこのクリップの区間ミュートに掛かっているか。
    ///
    /// **ON/OFF の判定は必ず `ClipAudioMuteGate.isMuted` を通す**（判定式をここへ
    /// 書き写さない。同ファイル冒頭 doc の規約）。ここでの仕事は「どの素材時刻を
    /// 判定すればよいか」を `mapping` から引くことだけ。
    private static func isMuted(clip: TimelineClip, mapping: TimelineMapping,
                                atCompositionTime t: Double,
                                muteRanges: [ClipAudioMuteRange]) -> Bool {
        guard !muteRanges.isEmpty,
              let hit = mapping.sourceLocations(at: t).first(where: { $0.location.clipID == clip.id })
        else { return false }
        return ClipAudioMuteGate.isMuted(ranges: muteRanges, clipID: clip.id,
                                         sourceID: hit.location.sourceID, sourceTime: hit.location.time)
    }

    /// 区間ミュートを考慮しない、クロスフェードだけの音量（`t` は合成時刻）。
    /// トランジションの重なり内では線形にランプし、外では素の `volume`。
    ///
    /// **上端は閉区間で判定する**（`t <= end`）。呼び出し側はこれを breakpoint の
    /// 区切り値（セグメントの終端）としても呼ぶため、`outgoing.end` ちょうどを
    /// 半開区間で弾くと「先行クリップの重なり終端の値」が `0` ではなく素の `volume`
    /// に化ける（クロスフェードの終わりが無音へ落ちきらない）。ミュート区間の
    /// ON/OFF 判定（半開区間が正しい）とは別の関数なので、ここだけ閉区間にしても
    /// `ClipAudioMuteGate` の契約とは無関係。
    private static func baselineVolume(at t: Double, volume: Float,
                                       incoming: TimelineMapping.Overlap?,
                                       outgoing: TimelineMapping.Overlap?) -> Float {
        if let incoming, incoming.duration > 0, t >= incoming.start, t <= incoming.end {
            let progress = (t - incoming.start) / incoming.duration
            return Float(Double(volume) * min(max(progress, 0), 1))
        }
        if let outgoing, outgoing.duration > 0, t >= outgoing.start, t <= outgoing.end {
            let progress = (t - outgoing.start) / outgoing.duration
            return Float(Double(volume) * (1 - min(max(progress, 0), 1)))
        }
        return volume
    }

    // MARK: - BGM の音量キーフレーム（フェード ＋ ダッキング。E2-2 / E2-3）

    /// 1 曲ぶんの音量キーフレームを積む。**フェードとダッキングを乗算で重ねる**
    /// （`min` にしないこと。フェードの途中でダッキングが 0.25 → 1 のように戻ると、
    /// `min` では戻った瞬間にフェードのランプが無視されて音量が段差状に跳ねる。
    /// 乗算なら常に両方の効きが滑らかに合成される）。
    ///
    /// 区切り = `{曲の開始, フェードイン終端, フェードアウト開始, 曲の終端} ∪
    /// {ダッキング曲線のノード時刻}`（`AudioDuckingCurve.nodes` が返す、曲の範囲内に
    /// クランプ済みの時刻列）。区切りの間ごとに 1 回だけ `setVolume` / `setVolumeRamp`
    /// を置く（元音声側 `applyVolumeKeyframes` と同じ構造）。
    ///
    /// フェード・ダッキングとも区間の**内側**では直線（ランプ）だが、両方が同時に
    /// ランプしている区切りでは積は 2 次曲線になり、`AVMutableAudioMixInputParameters`
    /// は直線ランプしか表現できない。ここでは区切りの両端の値だけを直線でつないで
    /// 近似する（attack/release は 0.12〜0.35 秒と短く、フェードと重なる区間も
    /// 実用上は誤差が知覚できない）。
    private static func applyBackgroundKeyframes(to params: AVMutableAudioMixInputParameters,
                                                 item: AudioItem,
                                                 duckRanges: [ClipDuckRange],
                                                 mapping: TimelineMapping) {
        let volume = clampedVolume(item.volume)
        let songStart = item.compositionStart
        let songEnd = item.compositionEnd
        guard songEnd > songStart else { return }

        let duckNodes = AudioDuckingCurve.nodes(ranges: duckRanges, gain: item.duckingGain,
                                                mapping: mapping, songStart: songStart, songEnd: songEnd)

        var points: Set<Double> = [songStart, songEnd]
        if item.fadeInDuration > 0 { points.insert(songStart + item.fadeInDuration) }
        if item.fadeOutDuration > 0 { points.insert(songEnd - item.fadeOutDuration) }
        for node in duckNodes { points.insert(node.time) }
        let sorted = points.filter { $0 >= songStart && $0 <= songEnd }.sorted()
        guard sorted.count >= 2 else {
            params.setVolume(volume, at: time(songStart))
            return
        }
        for index in 0..<(sorted.count - 1) {
            let t0 = sorted[index]
            let t1 = sorted[index + 1]
            guard t1 > t0 else { continue }
            let v0 = fadeValue(at: t0, item: item, volume: volume) * duckGain(at: t0, nodes: duckNodes)
            let v1 = fadeValue(at: t1, item: item, volume: volume) * duckGain(at: t1, nodes: duckNodes)
            if abs(Double(v0) - Double(v1)) < 1e-6 {
                params.setVolume(v0, at: time(t0))
            } else {
                params.setVolumeRamp(fromStartVolume: v0, toEndVolume: v1,
                                     timeRange: CMTimeRange(start: time(t0), end: time(t1)))
            }
        }
    }

    /// ダッキングを考慮しない、フェードだけの音量（`t` は合成時刻）。
    /// `item.fadeInDuration` / `fadeOutDuration` は既に `duration / 2` 以下へ
    /// クランプ済み（`AudioItem.clampFades` の doc）なので、ここでは値をそのまま使う。
    private static func fadeValue(at t: Double, item: AudioItem, volume: Float) -> Float {
        let songStart = item.compositionStart
        let songEnd = item.compositionEnd
        if item.fadeInDuration > 0 {
            let fadeInEnd = songStart + item.fadeInDuration
            if t >= songStart, t <= fadeInEnd {
                let progress = (t - songStart) / item.fadeInDuration
                return Float(Double(volume) * min(max(progress, 0), 1))
            }
        }
        if item.fadeOutDuration > 0 {
            let fadeOutStart = songEnd - item.fadeOutDuration
            if t >= fadeOutStart, t <= songEnd {
                let progress = (songEnd - t) / item.fadeOutDuration
                return Float(Double(volume) * min(max(progress, 0), 1))
            }
        }
        return volume
    }

    /// ダッキング曲線のノード列から、合成時刻 `t` の BGM ゲインを線形補間で読む。
    /// ノード列の外側（最初のノードより前・最後のノードより後）は `1`（下げない）。
    /// 別々の声区間に属するノードどうしの間も、両端のゲインが `1` なのでそのまま
    /// 補間して問題ない（`AudioDuckingCurve.nodes` の契約: 区間外は常に `1`）。
    private static func duckGain(at t: Double, nodes: [AudioDuckingCurve.Node]) -> Float {
        guard let first = nodes.first, let last = nodes.last else { return 1 }
        if t <= first.time { return t == first.time ? first.gain : 1 }
        if t >= last.time { return t == last.time ? last.gain : 1 }
        for index in 0..<(nodes.count - 1) {
            let a = nodes[index]
            let b = nodes[index + 1]
            guard t >= a.time, t <= b.time else { continue }
            guard b.time > a.time else { return a.gain }
            let progress = Float((t - a.time) / (b.time - a.time))
            return a.gain + progress * (b.gain - a.gain)
        }
        return 1
    }
}
