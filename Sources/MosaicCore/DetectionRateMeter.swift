import Foundation

/// Aggregates per-frame / per-image detection outcomes into a detection rate.
///
/// Pure value type with no Metal / MediaPipe / UI dependencies, so the metric is
/// unit-testable headlessly in CI and reusable from the app's integration tests
/// (which feed it real ``FaceLandmarkSet`` results from MediaPipe).
///
/// "Detection" here means a face was found in a sample (a still image or a video
/// frame). Pair it with ``TrackingEvaluator`` to also reproduce the smoothed
/// tracking-rate trajectory from the same detection sequence.
public struct DetectionRateMeter: Sendable, Equatable {
    /// Number of samples recorded so far.
    public private(set) var total: Int = 0
    /// Number of samples in which a face was detected.
    public private(set) var detectedCount: Int = 0

    public init() {}

    /// Number of samples in which no face was detected.
    public var missedCount: Int { total - detectedCount }

    /// Detection rate as a percentage in `0...100`. Returns `0` when no samples
    /// have been recorded yet (an empty meter has nothing detected).
    public var detectionRate: Double {
        guard total > 0 else { return 0 }
        return Double(detectedCount) / Double(total) * 100
    }

    /// Records one sample outcome.
    public mutating func record(detected: Bool) {
        total += 1
        if detected { detectedCount += 1 }
    }

    /// Convenience that treats a non-`nil` landmark set as a detection.
    ///
    /// - Parameters:
    ///   - set: the landmarker result for one sample, or `nil` if nothing was found.
    ///   - minConfidence: optional floor; a set below it counts as a miss.
    ///   - requireFullMesh: when `true`, a partial mesh (fewer than 478 points)
    ///     counts as a miss even if a set was returned.
    public mutating func record(
        _ set: FaceLandmarkSet?,
        minConfidence: Float = 0,
        requireFullMesh: Bool = false
    ) {
        guard let set else {
            record(detected: false)
            return
        }
        let meetsConfidence = set.confidence >= minConfidence
        let meetsMesh = !requireFullMesh || set.isFullMesh
        record(detected: meetsConfidence && meetsMesh)
    }
}
