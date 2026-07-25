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

    /// クリップ間の混在判定に使う映像フォーマット（解像度と向き）。
    /// `mixedVideoFormats` の判定基準そのもの: この型の Equatable 比較が唯一の基準で、
    /// `build` のガードと `appendPhotoClip` の事前照合が共有する（二重実装の禁止）。
    struct VideoFormat: Equatable {
        let size: CGSize
        let transform: CGAffineTransform
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
        var reference: VideoFormat?
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

            let format = try await Self.videoFormat(of: sourceVideo)
            if let reference {
                guard reference == format else {
                    throw BuildError.mixedVideoFormats
                }
            } else {
                reference = format
                // 先頭クリップの向きを出力の基準にする。
                videoTrack.preferredTransform = format.transform
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

            if let audioTrack {
                let inserted = try await insertAudio(of: asset, range: range,
                                                     scaledDuration: scaledDuration,
                                                     at: cursor, into: audioTrack)
                insertedAudio = insertedAudio || inserted
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

    /// クリップ 1 本分の音声を合成トラックへ差し込む。音声は無い素材もあるため、
    /// あるときだけ実データを挿入し、映像と同じ区間を同じ合成尺へスケールして
    /// トラック間の同期を保つ。ピッチ保持は再生・書き出し側の
    /// `audioTimePitchAlgorithm`（`.spectral`）で行う
    /// （`MosaicPreviewController.makePlayerItem` / `VideoMosaicExporter` の再エンコード経路）。
    ///
    /// 音声トラックを持たない素材（写真クリップ等）の区間は明示的に empty range で
    /// 埋める（S6）。これで音声トラックのセグメント列が映像と同じ時間軸を保ち、
    /// 後続クリップの音声挿入位置（cursor）がずれない。挿入位置は常にトラック末尾
    /// なので後続セグメントの押し出しは起きない。最終的に 1 クリップも音声が無ければ
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
