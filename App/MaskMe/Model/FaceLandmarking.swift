import UIKit
import MosaicCore

/// Abstraction over a face-landmark detector. The UI / view model depend on
/// this protocol rather than MediaPipe directly, so the app compiles without
/// the pod present and a stub can be injected for previews and tests.
public protocol FaceLandmarking {
    /// Detects landmarks in a single still image.
    func landmarks(in image: UIImage) -> FaceLandmarkSet?

    /// Detects landmarks in a video frame presented at `timestampMs`.
    func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet?
}

/// A no-op detector used when MediaPipe is unavailable (SwiftUI previews,
/// simulator without the model). Always reports "no face", which the renderer
/// handles gracefully by passing the frame through untouched.
public struct NullFaceLandmarker: FaceLandmarking {
    public init() {}

    public func landmarks(in image: UIImage) -> FaceLandmarkSet? { nil }

    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? { nil }
}
