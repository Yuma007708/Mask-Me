import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore
import UIKit

// OpticalFlowTracker / MMGrayFrame / MMFlowTrackerOptions はブリッジングヘッダ
// （MaskMe-Bridging-Header.h → OpticalFlowKit）経由で見える。

/// 物体マスク（`ObjectMask`）の自動追跡を、素材動画のフレームを舐めて実行する。
///
/// ## 役割分担
///
/// このファイルは **「フレームを取り出して OpenCV に渡す」だけ**を担う。
/// 品質ゲート・キーフレームでの再アンカー・見失いの扱い・ドリフト補正という判断は
/// 全て `MosaicCore.ObjectTrackBuilder`（純 Swift・`swift test` で検証済み）にあり、
/// ここには一つも無い。`CameraFlowAdvancer` ↔ `LiveFacePropagator` と同じ分け方である。
///
/// ## なぜ事前計算なのか（描画時に追跡しない理由）
///
/// `ObjectTrack` の doc を参照。オプティカルフローは直前フレームに依存する逐次処理なので、
/// ランダムシークするプレビューと先頭から舐めるエクスポートでは同じ時刻でも別の結果になる。
/// 事前に軌跡を作って両者が読むだけにすれば、この食い違いが原理的に起きない。
///
/// ## 追跡率を上げるためにしていること
///
/// - **毎フレーム特徴点を取り直す**（`seed` → `advance` → `seed` …）。
///   Lucas-Kanade は追跡のたびに点が脱落し、尽きた時点で死ぬ。取り直せば累積しない。
/// - **物体向けの緩いゲート**（`MMFlowTrackerOptions.objectTrackingDefaults`）。
///   顔向けの「15 点以上」では小さい対象で seed すら通らない。
/// - **1 クリップ 1 パスで全マスクを同時に追う**。縮小グレー化はフレームあたり 1 回で、
///   マスクが増えてもデコードコストは増えない。
enum ObjectMaskTracker {
    /// 追跡 1 件ぶんの依頼。
    struct Request {
        let mask: ObjectMask
        let clipID: UUID
        let sourceID: UUID
    }

    /// 追跡に使う縮小長辺（px）。撮影の前進層（`CameraFlowAdvancer.maxLongSide`）と揃える。
    static let maxLongSide = 640.0
    /// 追跡のサンプリング上限 fps。素材の実 fps がこれより低ければそちらに従う。
    /// 高いほど 1 フレームあたりの動きが小さくなり追跡は安定するが、デコード時間に直結する。
    static let maxSampleFPS = 30.0

    /// 1 クリップぶんの追跡を実行する。
    ///
    /// - Parameters:
    ///   - requests: このクリップに属するマスク（`clipID` は全て同じ前提）。
    ///   - asset: 素材。**向きは `appliesPreferredTrackTransform` で表示向きへ正規化する**
    ///     （マスクの矩形は検出パイプラインと同じ表示向きの正規化座標なので、
    ///     生バッファの座標系で追ってはいけない）。
    ///   - sourceRange: 追跡する素材時刻の範囲（クリップの使用区間）。
    ///   - shouldYield: 真を返す間は追跡を中断して待つ。再生中にハードウェアデコーダを
    ///     `AVPlayer` と奪い合うと、実機では数秒後から `copyCGImage` が nil を返し続ける
    ///     （プリスキャンで実測済みの事故。`runPreScan` の同じ待ち合わせを踏襲する）。
    ///   - onProgress: 0...1 の進捗。UI 表示用。
    /// - Returns: マスク id 引きの軌跡。追跡が 1 区間も作れなかったマスクは入らない。
    static func track(_ requests: [Request],
                      asset: AVAsset,
                      sourceRange: ClosedRange<Double>,
                      shouldYield: @escaping @Sendable () async -> Bool,
                      onProgress: @escaping @Sendable (Double) -> Void) async -> [UUID: ObjectTrack] {
        guard !requests.isEmpty, sourceRange.upperBound > sourceRange.lowerBound else { return [:] }
        let interval = await sampleInterval(of: asset)
        guard interval > 0 else { return [:] }

        let states = requests.compactMap { request -> TrackingState? in
            guard let builder = ObjectTrackBuilder(mask: request.mask,
                                                   clipID: request.clipID,
                                                   sourceID: request.sourceID) else { return nil }
            return TrackingState(builder: builder)
        }
        guard !states.isEmpty else { return [:] }
        // 最初のキーフレームより前は追う必要がない（軌跡の先端は最初のキーフレーム）。
        let start = max(sourceRange.lowerBound,
                        states.map(\.builder.startTime).min() ?? sourceRange.lowerBound)
        guard sourceRange.upperBound > start else { return [:] }

        let sampling = Sampling(interval: interval, range: start...sourceRange.upperBound)
        let completed = await pumpFrames(asset: asset, sampling: sampling, states: states,
                                         shouldYield: shouldYield, onProgress: onProgress)
        guard completed else { return [:] }
        onProgress(1)

        var tracks: [UUID: ObjectTrack] = [:]
        for state in states {
            guard let track = state.builder.finish() else { continue }
            tracks[track.maskID] = track
        }
        return tracks
    }

    /// 素材を先頭から舐めて全トラッカーを進める。中断（キャンセル）されたら false。
    private static func pumpFrames(asset: AVAsset, sampling: Sampling,
                                   states: [TrackingState],
                                   shouldYield: @Sendable () async -> Bool,
                                   onProgress: @Sendable (Double) -> Void) async -> Bool {
        let interval = sampling.interval
        let range = sampling.range
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 厳密シークは要らない（追跡はデコードできたフレームの実時刻で組み立てる）。
        // 許容差を入れると AVFoundation がデコード済みフレームを再利用でき、
        // 1 フレームあたりのコストが桁で変わる。
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let span = range.upperBound - range.lowerBound
        var time = range.lowerBound
        var lastActualTime = -Double.infinity
        while time <= range.upperBound {
            if Task.isCancelled { return false }
            // 再生中はハードウェアデコーダを AVPlayer に明け渡す（`runPreScan` と同じ理由）。
            while await shouldYield() {
                if Task.isCancelled { return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // プリスキャンと同じ理由で 1 フレームごとに autorelease を回す。
            // 溜めるとハードウェアデコーダがメモリ圧で失敗し、途中から全滅する。
            autoreleasepool {
                guard let (image, actual) = copyFrame(generator, at: time),
                      actual > lastActualTime else { return }   // 同じフレームを二度使わない
                lastActualTime = actual
                advanceAll(states, image: image, sourceTime: actual)
            }
            onProgress(span > 0 ? min(1, max(0, (time - range.lowerBound) / span)) : 1)
            time += interval
        }
        return true
    }

    /// フレームの舐め方（間隔と範囲）。
    private struct Sampling {
        let interval: Double
        let range: ClosedRange<Double>
    }

    // MARK: - 1 フレームの処理

    /// マスク 1 個ぶんの追跡状態。
    private final class TrackingState {
        let builder: ObjectTrackBuilder
        let tracker = OpticalFlowTracker(options: .objectTrackingDefaults())
        /// seed 済みか（最初のキーフレームに到達したフレームで立つ）。
        var isSeeded = false

        init(builder: ObjectTrackBuilder) { self.builder = builder }
    }

    private static func advanceAll(_ states: [TrackingState],
                                   image: UIImage, sourceTime: Double) {
        // 縮小グレー化はフレームあたり 1 回。全マスクで共有する。
        guard let frame = MMGrayFrame(image: image, maxLongSide: maxLongSide) else { return }
        let imageSize = image.size.width > 0 && image.size.height > 0
            ? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            : .zero
        for state in states {
            guard sourceTime >= state.builder.startTime else { continue }
            guard state.isSeeded else {
                // 最初のキーフレームに届いた最初のフレーム。ここは追跡せず種を蒔くだけ。
                state.isSeeded = true
                reseed(state, frame: frame)
                continue
            }
            let match = state.tracker.advance(grayFrame: frame)
            let transform = match.flatMap {
                SimilarityTransform.estimate(from: $0.previousPoints.map(\.cgPointValue),
                                             to: $0.currentPoints.map(\.cgPointValue))
            }
            state.builder.advance(toSourceTime: sourceTime, transform: transform, imageSize: imageSize)
            reseed(state, frame: frame)
        }
    }

    /// 次フレームのために現在位置で特徴点を取り直す。凍結中は蒔かない。
    private static func reseed(_ state: TrackingState, frame: MMGrayFrame) {
        guard let rect = state.builder.reseedRect else {
            state.tracker.reset()
            return
        }
        _ = state.tracker.seed(grayFrame: frame, faceBox: rect)
    }

    // MARK: - フレーム取り出し

    private static func copyFrame(_ generator: AVAssetImageGenerator,
                                  at time: Double) -> (UIImage, Double)? {
        var actual = CMTime.zero
        guard let cg = try? generator.copyCGImage(
            at: CMTime(seconds: time, preferredTimescale: 600), actualTime: &actual)
        else { return nil }
        let seconds = actual.isNumeric ? actual.seconds : time
        guard seconds.isFinite else { return nil }
        return (UIImage(cgImage: cg), seconds)
    }

    /// サンプリング間隔（秒）。素材の実 fps を上限 `maxSampleFPS` で抑える。
    private static func sampleInterval(of asset: AVAsset) async -> Double {
        let nominal = (try? await asset.loadTracks(withMediaType: .video).first?
            .load(.nominalFrameRate)).flatMap { $0 } ?? 0
        let fps = nominal > 1 ? min(Double(nominal), maxSampleFPS) : maxSampleFPS
        return 1.0 / fps
    }
}
