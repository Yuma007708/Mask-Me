import Foundation

/// The lifecycle state of face tracking.
///
/// The renderer drives transitions every frame:
/// `idle → searching → tracking → lost → searching → tracking …`
public enum TrackingState: String, Sendable, Equatable {
    /// No frames processed yet, or processing stopped.
    case idle
    /// Actively looking for a face but none has locked on yet.
    case searching
    /// A face is locked and the mosaic is being applied.
    case tracking
    /// A previously tracked face was dropped this frame.
    case lost
}

/// An immutable snapshot of tracking quality, published to SwiftUI.
public struct TrackingStatus: Sendable, Equatable {
    /// Smoothed tracking rate in `0...100`.
    public let rate: Double
    /// Current lifecycle state.
    public let state: TrackingState
    /// Whether a face was detected in the most recent frame.
    public let faceDetected: Bool
    /// Raw detection confidence for the most recent frame, in `0...1`.
    public let confidence: Float

    public init(rate: Double, state: TrackingState, faceDetected: Bool, confidence: Float) {
        self.rate = rate
        self.state = state
        self.faceDetected = faceDetected
        self.confidence = confidence
    }

    /// The initial, pre-tracking status.
    public static let idle = TrackingStatus(
        rate: 0,
        state: .idle,
        faceDetected: false,
        confidence: 0
    )
}

/// Pure, testable state machine that converts a stream of per-frame detection
/// results into a smoothed ``TrackingStatus``.
///
/// Kept free of Metal / UI dependencies so it can be unit-tested headlessly and
/// reused by both the live preview and offline (video export) pipelines.
public struct TrackingEvaluator: Sendable {
    /// Smoothing factor for the exponential moving average, in `(0, 1]`.
    /// Higher reacts faster; lower is steadier.
    public let smoothing: Double
    /// Per-frame decay applied to the rate while a face is lost.
    public let lostDecay: Double
    /// Confidence at or above which a detection counts as a successful lock.
    public let lockThreshold: Float

    private(set) public var status: TrackingStatus

    public init(
        smoothing: Double = 0.35,
        lostDecay: Double = 0.5,
        lockThreshold: Float = 0.5
    ) {
        self.smoothing = max(0.0001, min(1, smoothing))
        self.lostDecay = max(0, min(1, lostDecay))
        self.lockThreshold = lockThreshold
        self.status = .idle
    }

    /// Folds one frame's detection result into the running status and returns
    /// the new snapshot. Passing `nil` (or a below-threshold confidence) marks
    /// the frame as a miss; the rate decays but tracking resumes instantly the
    /// moment a confident detection returns — no warm-up frames required.
    @discardableResult
    public mutating func update(confidence: Float?) -> TrackingStatus {
        let detected = (confidence ?? 0) >= lockThreshold
        let wasTracking = status.state == .tracking

        let newRate: Double
        let newState: TrackingState

        if detected {
            // EMA toward the live confidence, expressed as a percentage.
            let target = Double(min(max(confidence ?? 0, 0), 1)) * 100
            newRate = status.rate + (target - status.rate) * smoothing
            newState = .tracking
        } else {
            newRate = status.rate * lostDecay
            // A face that was being tracked is "lost" for exactly one frame,
            // then we fall back to "searching" until it returns.
            newState = wasTracking ? .lost : .searching
        }

        status = TrackingStatus(
            rate: newRate,
            state: newState,
            faceDetected: detected,
            confidence: confidence ?? 0
        )
        return status
    }

    /// Resets the evaluator back to ``TrackingStatus/idle``.
    public mutating func reset() {
        status = .idle
    }
}
