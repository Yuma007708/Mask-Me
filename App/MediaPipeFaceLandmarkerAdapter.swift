//  MediaPipeFaceLandmarkerAdapter.swift
//
//  App-target glue between MediaPipe and the MediaPipe-free `MosaicCore`.
//  This file lives OUTSIDE the SwiftPM target on purpose: MediaPipe ships only
//  as a CocoaPods pod / binary xcframework, so it is linked by the iOS app
//  target — never by `MosaicCore` (which stays pure so CI can `swift build` it).
//
//  The whole file is gated on `canImport(MediaPipeTasksVision)` so the package
//  continues to compile anywhere the pod is absent (including CI).

#if canImport(MediaPipeTasksVision) && canImport(UIKit)
import Foundation
import UIKit
import MediaPipeTasksVision
import MosaicCore

/// Thin wrapper around MediaPipe's `FaceLandmarker` that produces the
/// framework-agnostic `FaceLandmarkSet` consumed by `MosaicRenderer`.
public final class MediaPipeFaceLandmarkerAdapter {
    private let landmarker: FaceLandmarker

    /// - Parameter modelPath: path to the bundled `face_landmarker.task` model.
    public init(modelPath: String, runningMode: RunningMode = .video) throws {
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numFaces = 1
        // Surface a usable confidence to the tracking-rate evaluator.
        options.minFacePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        self.landmarker = try FaceLandmarker(options: options)
    }

    /// Detects landmarks in a single still image.
    public func landmarks(in image: UIImage) -> FaceLandmarkSet? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(image: mpImage) else {
            return nil
        }
        return Self.convert(result)
    }

    /// Detects landmarks in a video frame at `timestampMs`.
    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(
                  videoFrame: mpImage,
                  timestampInMilliseconds: timestampMs
              ) else {
            return nil
        }
        return Self.convert(result)
    }

    /// Maps a MediaPipe result onto `FaceLandmarkSet`. Returns `nil` when no
    /// face is present so the renderer can transition into its "lost" state.
    static func convert(_ result: FaceLandmarkerResult) -> FaceLandmarkSet? {
        guard let face = result.faceLandmarks.first else { return nil }
        let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
        // MediaPipe does not expose a single scalar score on the result, so we
        // derive a coarse presence confidence from mesh completeness.
        let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
        return FaceLandmarkSet(points: points, confidence: confidence)
    }
}
#endif
