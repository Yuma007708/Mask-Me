import CoreGraphics
import Foundation

/// リアルタイム撮影の「毎フレーム前進層」。
///
/// 検出は 10Hz 非同期のため、従来は検出間のフレームが「前回検出位置での凍結描画」
/// になり、顔を速く動かすとモザイクが外れた。本クラスはオプティカルフローの
/// 対応点ペアから顔ごとのフレーム間相似変換を推定し、全ランドマークを毎フレーム
/// 現在位置へ前進させる（TikTok 式の貼り付き追従）。
///
/// さらに検出結果の「古さ」も補正する: 検出は開始フレーム時点の位置を返すため、
/// 完了時には既に 100ms + 検出コスト分古い。`beginDetection` から
/// `completeDetection` までのフレーム間変換を顔ごとに累積し、届いた検出結果へ
/// 適用してから採用する。採用時は前進済み推定との残差を数フレームかけて
/// ブレンドし、検出ジッタによるポップを防ぐ。
///
/// 安全側の規則（原本レス設計 = モザイクが外れる方向の失敗は露出事故）:
/// - フロー失敗時は Kalman 等速度の並進外挿（上限つき）→ 上限超過で前回位置に
///   凍結する。位置を縮める・消すことはしない。「消す」判断（録画中 hold /
///   非録画の猶予消灯）は呼び出し側の責務のまま。
/// - 顔配列の順序・数は `completeDetection` まで不変（`CameraFaceSelection` の
///   添字前提を守る）。
///
/// スレッド規約: 全メソッドを同一ロック内（`CameraMosaicPipeline.stateLock`）で
/// 呼ぶこと。本クラス自身は同期しない。
public final class LiveFacePropagator {
    /// 1 フレームぶんのフロー対応点ペア（フルフレームのピクセル座標）。
    public struct FlowObservation {
        public let from: [CGPoint]
        public let to: [CGPoint]

        public init(from: [CGPoint], to: [CGPoint]) {
            self.from = from
            self.to = to
        }
    }

    private struct TrackedFace {
        var landmarks: FaceLandmarkSet
        var kalman: KalmanBoxTracker
        /// フロー失敗の連続フレーム数（0 = フロー健全）。
        var extrapolatingFrames: Int
        /// `beginDetection` 時点から現フレームまでの累積変換（ピクセル空間）。
        var pendingTransform: SimilarityTransform
        /// 検出合流時の残差ブレンド元（数フレームで landmarks に収束して nil に戻る）。
        var blendSource: FaceLandmarkSet?
        var blendProgress: Int

        init(landmarks: FaceLandmarkSet) {
            self.landmarks = landmarks
            self.kalman = KalmanBoxTracker(initialBox: landmarks.boundingBox)
            self.extrapolatingFrames = 0
            self.pendingTransform = .identity
            self.blendSource = nil
            self.blendProgress = 0
        }
    }

    /// フロー失敗時に Kalman 並進外挿を続ける最大フレーム数（30fps で約 0.3 秒）。
    /// 超過後は前回位置で凍結する（等速度の当てずっぽうを長く走らせない）。
    private let maxExtrapolationFrames: Int
    /// 検出合流時の残差を吸収するフレーム数。
    private let blendFrames: Int
    /// 合流残差がこの正規化距離を超えたらブレンドせず即スナップする
    /// （大きくずれた推定を引きずらない。`LandmarkSmoother` と同じ発想）。
    private let snapDistance: Float
    /// フロー変換の許容スケール範囲。逸脱は誤追跡とみなして外挿へ落とす
    /// （`MediaPipeFaceLandmarkerAdapter` のフロー橋渡しと同じゲート）。
    private let scaleGate: ClosedRange<CGFloat>

    private var tracks: [TrackedFace] = []
    private var pending: (token: Int, snapshot: [FaceLandmarkSet])?
    private var nextToken = 0

    public init(maxExtrapolationFrames: Int = 10,
                blendFrames: Int = 3,
                snapDistance: Float = 0.05,
                scaleGate: ClosedRange<CGFloat> = 0.7...1.4) {
        self.maxExtrapolationFrames = maxExtrapolationFrames
        self.blendFrames = blendFrames
        self.snapDistance = snapDistance
        self.scaleGate = scaleGate
    }

    // MARK: - 参照

    public var count: Int { tracks.count }
    public var isEmpty: Bool { tracks.isEmpty }

    /// 現フレームの前進済み推定（残差ブレンド適用後）。描画・タップ判定はこれを使う。
    public var faces: [FaceLandmarkSet] {
        tracks.map { track in
            guard let source = track.blendSource, blendFrames > 0 else {
                return track.landmarks
            }
            let alpha = min(1, Float(track.blendProgress + 1) / Float(blendFrames + 1))
            return source.interpolated(to: track.landmarks, alpha: alpha)
        }
    }

    /// 現在推定の顔 bbox（正規化）。フロートラッカーの再 seed 用。
    public var boundingBoxes: [CGRect] { tracks.map(\.landmarks.boundingBox) }

    /// 顔 `index` の推定速度（正規化座標 / フレーム）。マージン適応用。
    public func speed(at index: Int) -> CGFloat {
        guard tracks.indices.contains(index) else { return 0 }
        return tracks[index].kalman.speedMagnitude
    }

    /// 顔 `index` がフロー失敗中（外挿または凍結）か。マージン増・凸包降格用。
    public func isExtrapolating(at index: Int) -> Bool {
        guard tracks.indices.contains(index) else { return false }
        return tracks[index].extrapolatingFrames > 0
    }

    // MARK: - 毎フレーム前進

    /// 顔ごとのフロー対応点で全トラックを 1 フレーム前進させる。
    /// `observations[i]` はトラック `i` の対応点ペア（`nil` = フロー失敗 → 外挿）。
    public func advance(observations: [FlowObservation?], imageSize: CGSize) {
        for index in tracks.indices {
            let transform = observations.indices.contains(index)
                ? observations[index].flatMap { estimate($0) }
                : nil
            if let transform {
                apply(transform, toTrackAt: index, imageSize: imageSize)
            } else {
                extrapolate(trackAt: index, imageSize: imageSize)
            }
            if tracks[index].blendSource != nil {
                tracks[index].blendProgress += 1
                if tracks[index].blendProgress >= blendFrames {
                    tracks[index].blendSource = nil
                }
            }
        }
    }

    private func estimate(_ observation: FlowObservation) -> SimilarityTransform? {
        guard let transform = SimilarityTransform.estimate(
            from: observation.from, to: observation.to),
              scaleGate.contains(transform.scale) else { return nil }
        return transform
    }

    private func apply(_ transform: SimilarityTransform,
                       toTrackAt index: Int,
                       imageSize: CGSize) {
        tracks[index].landmarks = transform.apply(
            to: tracks[index].landmarks, imageSize: imageSize)
        tracks[index].blendSource = tracks[index].blendSource.map {
            transform.apply(to: $0, imageSize: imageSize)
        }
        tracks[index].pendingTransform =
            tracks[index].pendingTransform.composed(with: transform)
        tracks[index].extrapolatingFrames = 0
        tracks[index].kalman.predict()
        tracks[index].kalman.update(observation: tracks[index].landmarks.boundingBox)
    }

    private func extrapolate(trackAt index: Int, imageSize: CGSize) {
        tracks[index].extrapolatingFrames += 1
        // 上限超過: 前回位置で凍結（消さない・縮めない。当てずっぽうも続けない）。
        guard tracks[index].extrapolatingFrames <= maxExtrapolationFrames else { return }
        let before = CGPoint(x: tracks[index].kalman.cx, y: tracks[index].kalman.cy)
        tracks[index].kalman.predict()
        let dx = Float(tracks[index].kalman.cx - before.x)
        let dy = Float(tracks[index].kalman.cy - before.y)
        let translation = SimilarityTransform(
            scale: 1, rotation: 0,
            tx: CGFloat(dx) * imageSize.width, ty: CGFloat(dy) * imageSize.height)
        tracks[index].landmarks = translated(tracks[index].landmarks, dx: dx, dy: dy)
        tracks[index].blendSource = tracks[index].blendSource.map {
            translated($0, dx: dx, dy: dy)
        }
        tracks[index].pendingTransform =
            tracks[index].pendingTransform.composed(with: translation)
    }

    private func translated(_ set: FaceLandmarkSet, dx: Float, dy: Float) -> FaceLandmarkSet {
        let moved = set.points.map {
            FaceLandmark(x: $0.x + dx, y: $0.y + dy, z: $0.z)
        }
        return FaceLandmarkSet(points: moved, confidence: set.confidence)
    }

    // MARK: - 検出との合流

    /// 検出を発行する直前に呼ぶ。以降のフレーム間変換が累積され、
    /// `completeDetection` で「古い検出結果」の現フレーム補正に使われる。
    @discardableResult
    public func beginDetection() -> Int {
        nextToken += 1
        pending = (token: nextToken, snapshot: tracks.map(\.landmarks))
        for index in tracks.indices {
            tracks[index].pendingTransform = .identity
        }
        return nextToken
    }

    /// 検出完了時に呼ぶ。`faces` は検出を開始したフレーム時点の全顔。
    /// 発行時スナップショットと IoU 対応した顔は累積変換で現フレームへ補正して
    /// 採用し、対応の無い顔（新顔）はそのまま採用する。トラックの順序は
    /// `faces` の順序に一致する（呼び出し側の添字ベース選択と揃う）。
    /// - Returns: 補正後の顔 bbox（フロートラッカー再 seed 用）。
    @discardableResult
    public func completeDetection(token: Int,
                                  faces detected: [FaceLandmarkSet],
                                  imageSize: CGSize) -> [CGRect] {
        guard let pending, pending.token == token else { return boundingBoxes }
        self.pending = nil
        var usedTracks = Set<Int>()
        var newTracks: [TrackedFace] = []
        for face in detected {
            if let matched = matchIndex(for: face, in: pending.snapshot,
                                        excluding: usedTracks) {
                usedTracks.insert(matched)
                newTracks.append(merged(track: tracks[matched],
                                        detection: face,
                                        imageSize: imageSize))
            } else {
                newTracks.append(TrackedFace(landmarks: face))
            }
        }
        tracks = newTracks
        return boundingBoxes
    }

    /// 検出（開始フレーム時点の位置）を累積変換で現フレームへ補正し、
    /// 前進済み推定との残差をブレンド予約して既存トラックへ合流させる。
    private func merged(track: TrackedFace,
                        detection: FaceLandmarkSet,
                        imageSize: CGSize) -> TrackedFace {
        var track = track
        let corrected = track.pendingTransform.apply(to: detection, imageSize: imageSize)
        let residual = centroidDistance(track.landmarks, corrected)
        if residual <= snapDistance,
           track.landmarks.points.count == corrected.points.count {
            track.blendSource = track.landmarks
            track.blendProgress = 0
        } else {
            track.blendSource = nil
        }
        track.landmarks = corrected
        track.kalman.update(observation: corrected.boundingBox)
        track.pendingTransform = .identity
        track.extrapolatingFrames = 0
        return track
    }

    /// `face` と最も IoU が高いスナップショット顔の添字（IoU > 0.3、1:1）。
    private func matchIndex(for face: FaceLandmarkSet,
                            in snapshot: [FaceLandmarkSet],
                            excluding used: Set<Int>) -> Int? {
        let mine = face.boundingBox
        var best: (iou: CGFloat, index: Int)?
        for (index, candidate) in snapshot.enumerated() where !used.contains(index) {
            let other = candidate.boundingBox
            let inter = mine.intersection(other)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let interArea = inter.width * inter.height
            let unionArea = mine.width * mine.height
                + other.width * other.height - interArea
            guard unionArea > 0 else { continue }
            let iou = interArea / unionArea
            if iou > 0.3, iou > (best?.iou ?? 0) { best = (iou, index) }
        }
        return best?.index
    }

    private func centroidDistance(_ a: FaceLandmarkSet, _ b: FaceLandmarkSet) -> Float {
        func centroid(_ set: FaceLandmarkSet) -> (x: Float, y: Float) {
            guard !set.points.isEmpty else { return (0, 0) }
            var sx: Float = 0, sy: Float = 0
            for p in set.points { sx += p.x; sy += p.y }
            let n = Float(set.points.count)
            return (sx / n, sy / n)
        }
        let ca = centroid(a), cb = centroid(b)
        return (pow(ca.x - cb.x, 2) + pow(ca.y - cb.y, 2)).squareRoot()
    }

    // MARK: - リセット

    /// 全トラックを破棄する（カメラ切替・検出全滅の消灯時）。
    public func reset() {
        tracks = []
        pending = nil
    }
}
