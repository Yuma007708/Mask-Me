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
struct TimelineCompositionBuilder {
    enum BuildError: Error {
        /// クリップが参照する素材が `sources` に無い。
        case missingSource(UUID)
        case noVideoTrack
    }

    /// - Parameters:
    ///   - clips: 並び順どおりに連結される。
    ///   - sources: 素材IDから AVAsset への対応表。
    func build(clips: [TimelineClip], sources: [UUID: AVAsset]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.noVideoTrack
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for clip in clips {
            guard let asset = sources[clip.sourceID] else {
                throw BuildError.missingSource(clip.sourceID)
            }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw BuildError.noVideoTrack
            }

            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600))

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)

            // 先頭クリップの向きを出力の基準にする。
            if cursor == .zero {
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }

            // 音声は無い素材もあるため、あるときだけ差し込む。
            if let audioTrack,
               let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            // CMTime は += を提供しない（+ のみ）ため shorthand_operator を適用できない。
            // swiftlint:disable:next shorthand_operator
            cursor = cursor + range.duration
        }
        return composition
    }
}
