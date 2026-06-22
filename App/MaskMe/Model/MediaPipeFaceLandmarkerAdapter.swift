//  MediaPipeFaceLandmarkerAdapter.swift
//
//  App-target glue between MediaPipe and the MediaPipe-free `MosaicCore`.
//  MediaPipe ships only as a CocoaPods pod / binary xcframework, so it is
//  linked here in the app target — never in `MosaicCore`, which stays pure so
//  CI can `swift build` it.
//
//  Everything that touches MediaPipe is gated on `canImport(MediaPipeTasksVision)`
//  so the package keeps compiling anywhere the pod is absent.

import UIKit
import MosaicCore

/// Returns the best available landmarker: the MediaPipe-backed one when the pod
/// and model are present, otherwise a ``NullFaceLandmarker``.
public func makeFaceLandmarker(modelName: String = "face_landmarker") -> FaceLandmarking {
    #if canImport(MediaPipeTasksVision)
    if let path = Bundle.main.path(forResource: modelName, ofType: "task"),
       let adapter = try? MediaPipeFaceLandmarkerAdapter(modelPath: path) {
        return adapter
    }
    #endif
    return NullFaceLandmarker()
}

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// Thin wrapper around MediaPipe's `FaceLandmarker` that produces the
/// framework-agnostic `FaceLandmarkSet` consumed by `MosaicRenderer`.
public final class MediaPipeFaceLandmarkerAdapter: FaceLandmarking {
    private let landmarker: FaceLandmarker

    /// - Parameter modelPath: path to the bundled `face_landmarker.task` model.
    public init(modelPath: String, runningMode: RunningMode = .video) throws {
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numFaces = 1
        options.minFacePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        self.landmarker = try FaceLandmarker(options: options)
    }

    public func landmarks(in image: UIImage) -> FaceLandmarkSet? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(image: mpImage) else {
            return nil
        }
        return Self.convert(result)
    }

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
        // MediaPipe does not expose a single scalar score, so we derive a coarse
        // presence confidence from mesh completeness.
        let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
        return FaceLandmarkSet(points: points, confidence: confidence)
    }
}
#endif
