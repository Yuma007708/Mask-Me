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
    /// - Returns: 必要なとき（重なりがある / 音量が 1.0 でないクリップがある）だけ
    ///   非 nil。無変換構成では nil を返し、従来のパススルー経路を温存する。
    /// - Parameters:
    ///   - backgroundItems: BGM（E2）。**`backgroundTrack` へ実際に載った曲**を渡すこと。
    ///   - backgroundTrack: BGM 専用トラック（無ければ nil）。元音声のトラック
    ///     （`tracks`）とは**別の入力パラメータ**を持つ。これが「元動画の音と BGM の
    ///     音量を別々に調整できる」ことの実体である。
    static func make(placements: [ClipPlacement],
                     overlaps: [TimelineMapping.Overlap],
                     tracks: [AVMutableCompositionTrack],
                     backgroundItems: [AudioItem] = [],
                     backgroundTrack: AVMutableCompositionTrack? = nil) -> AVMutableAudioMix? {
        // BGM があるならトラックが無くても mix は要る（BGM だけの構成）。
        guard !tracks.isEmpty || backgroundTrack != nil else { return nil }
        let needsVolume = placements.contains { clampedVolume($0.clip.originalAudioVolume) != 1.0 }
        // **BGM がある構成では常に mix を作る。** 音量が既定（1.0）でも作るのは、
        // ここが nil になると `hasAudioMix` が false になり、書き出しが圧縮パススルーへ
        // 落ちる経路が 1 つ増えるためである（`AudioExportPipeline` の
        // `hasBackgroundAudio` と二重の守りにする）。
        let hasBackground = backgroundTrack != nil
        guard !overlaps.isEmpty || needsVolume || hasBackground else { return nil }

        // トラック順に固定して作る（辞書順の非決定性を持ち込まない）。
        let parameters: [(track: AVMutableCompositionTrack, params: AVMutableAudioMixInputParameters)] =
            tracks.map { ($0, AVMutableAudioMixInputParameters(track: $0)) }

        for placement in placements {
            guard let audioTrack = placement.audioTrack,
                  let entry = parameters.first(where: { $0.track === audioTrack }) else { continue }
            let volume = clampedVolume(placement.clip.originalAudioVolume)
            // 後続（incoming）側はトランジションの間に 0 → 音量へ立ち上げる。
            if let overlap = overlaps.first(where: { $0.incomingClipID == placement.clip.id }) {
                entry.params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                           timeRange: range(of: overlap))
                // ランプ終了後の値を明示的に固定する（以降の区間の音量が
                // 実装依存にならないように）。
                entry.params.setVolume(volume, at: time(overlap.end))
            } else {
                entry.params.setVolume(volume, at: time(placement.start))
            }
            // 先行（outgoing）側はトランジションの間に音量 → 0 へ落とす。
            if let overlap = overlaps.first(where: { $0.outgoingClipID == placement.clip.id }) {
                entry.params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                           timeRange: range(of: overlap))
            }
        }

        // BGM トラック（E2）。**曲ごとに音量を切り替える。**
        //
        // トラックは 1 本を共有するので、曲の切れ目で `setVolume(_:at:)` を打ち直す
        // 必要がある（曲 A を 0.3、曲 B を 1.0 にしたとき、B の頭で戻さないと
        // A の音量が最後まで効き続ける）。曲どうしは重ならないので、開始時刻に
        // 打つだけで足りる。
        // **フェードイン／アウト（E2-2）はここで曲ごとの音量ランプへ変換する。**
        // `item.fadeInDuration` / `fadeOutDuration` は `AudioItem` 側で既に
        // `duration / 2` 以下へクランプ済み（`AudioItem.clampFades` の doc）なので、
        // ここでは値をそのまま使ってよい。フェードが 0 秒の項目は従来どおり
        // `setVolume(_:at:)` 1 点だけ（無フェード時の挙動を変えない）。
        var backgroundParams: AVMutableAudioMixInputParameters?
        if let backgroundTrack {
            let params = AVMutableAudioMixInputParameters(track: backgroundTrack)
            for item in backgroundItems.sorted(by: { $0.compositionStart < $1.compositionStart }) {
                let volume = clampedVolume(item.volume)
                if item.fadeInDuration > 0 {
                    params.setVolumeRamp(
                        fromStartVolume: 0, toEndVolume: volume,
                        timeRange: CMTimeRange(start: time(item.compositionStart),
                                               end: time(item.compositionStart + item.fadeInDuration)))
                } else {
                    params.setVolume(volume, at: time(item.compositionStart))
                }
                if item.fadeOutDuration > 0 {
                    params.setVolumeRamp(
                        fromStartVolume: volume, toEndVolume: 0,
                        timeRange: CMTimeRange(start: time(item.compositionEnd - item.fadeOutDuration),
                                               end: time(item.compositionEnd)))
                }
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

    private static func range(of overlap: TimelineMapping.Overlap) -> CMTimeRange {
        CMTimeRange(start: time(overlap.start), end: time(overlap.end))
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
