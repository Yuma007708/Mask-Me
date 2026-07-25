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
    enum BuildError: Error, Equatable {
        /// クリップが参照する素材が `sources` に無い。
        case missingSource(UUID)
        case noVideoTrack
        /// クリップ間で解像度または向き（preferredTransform）が混在している。
        ///
        /// S4 時点では videoComposition なしの単一トラック連結のため、混在すると
        /// 2 本目以降が先頭クリップ基準の縮尺・回転のまま描画されて壊れる。
        /// 黙って壊れた動画を作らず明示エラーにする（S8 の AVVideoComposition
        /// 導入で解禁予定）。
        case mixedVideoFormats
    }

    /// - Parameters:
    ///   - clips: 並び順どおりに連結される。`rate ≠ 1` のクリップは挿入後に
    ///     合成尺（素材長 ÷ rate）へ `scaleTimeRange` される（映像・音声とも）。
    ///   - sources: 素材IDから AVAsset への対応表。
    func build(clips: [TimelineClip], sources: [UUID: AVAsset]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.noVideoTrack
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        // 先頭クリップの解像度・向きを基準にし、混在は明示エラーで拒否する。
        var reference: (size: CGSize, transform: CGAffineTransform)?
        // 1 クリップも音声を挿入しなかったら音声トラックごと取り除くための追跡。
        var insertedAudio = false

        var cursor = CMTime.zero
        for clip in clips {
            guard let asset = sources[clip.sourceID] else {
                throw BuildError.missingSource(clip.sourceID)
            }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw BuildError.noVideoTrack
            }

            let size = try await sourceVideo.load(.naturalSize)
            let transform = try await sourceVideo.load(.preferredTransform)
            if let reference {
                guard reference.size == size, reference.transform == transform else {
                    throw BuildError.mixedVideoFormats
                }
            } else {
                reference = (size, transform)
                // 先頭クリップの向きを出力の基準にする。
                videoTrack.preferredTransform = transform
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

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if clip.rate != 1.0 {
                videoTrack.scaleTimeRange(
                    CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDuration)
            }

            // 音声は無い素材もあるため、あるときだけ差し込む。
            // 映像と同じ区間を同じ合成尺へスケールし、トラック間の同期を保つ
            // （ピッチ保持は S7 のプレビュー/エクスポート側で扱う）。
            if let audioTrack,
               let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                if clip.rate != 1.0 {
                    audioTrack.scaleTimeRange(
                        CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDuration)
                }
                insertedAudio = true
            }

            // CMTime は += を提供しない（+ のみ）ため shorthand_operator を適用できない。
            // swiftlint:disable:next shorthand_operator
            cursor = cursor + scaledDuration
        }

        // どの素材にも音声が無いときは空の音声トラックを残さない。
        // セグメントが 1 つも無いトラックが残っていると、`VideoMosaicExporter` が
        // formatDescription の無い音声トラックへ reader/writer を組んでしまい、
        // 書き出しが AVFoundation エラー（-11800）で失敗する。
        if let audioTrack, !insertedAudio {
            composition.removeTrack(audioTrack)
        }
        return composition
    }
}
