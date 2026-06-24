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
public func makeFaceLandmarker(forVideo: Bool = false, modelName: String = "face_landmarker") -> FaceLandmarking {
    #if canImport(MediaPipeTasksVision)
    if let path = Bundle.main.path(forResource: modelName, ofType: "task"),
       let adapter = try? MediaPipeFaceLandmarkerAdapter(
           modelPath: path,
           runningMode: forVideo ? .video : .image
       ) {
        return adapter
    }
    #endif
    return NullFaceLandmarker()
}

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
import CoreImage.CIFilterBuiltins

/// Thin wrapper around MediaPipe's `FaceLandmarker` that produces the
/// framework-agnostic `FaceLandmarkSet` consumed by `MosaicRenderer`.
public final class MediaPipeFaceLandmarkerAdapter: FaceLandmarking {
    private let landmarker: FaceLandmarker
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameter modelPath: path to the bundled `face_landmarker.task` model.
    public init(modelPath: String, runningMode: RunningMode = .video) throws {
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numFaces = 5
        options.minFaceDetectionConfidence = 0.3
        options.minFacePresenceConfidence = 0.3
        options.minTrackingConfidence = 0.3
        self.landmarker = try FaceLandmarker(options: options)
    }

    // MARK: - Single-face API（後方互換）

    public func landmarks(in image: UIImage) -> FaceLandmarkSet? {
        allLandmarks(in: image).first
    }

    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? {
        allLandmarks(in: image, timestampMs: timestampMs).first
    }

    // MARK: - Multi-face API

    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] {
        if let result = detectAllImage(image) { return result }
        if let enhanced = enhance(image), let result = detectAllImage(enhanced) { return result }
        return []
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        if let result = detectAllVideoFrame(image, timestampMs: timestampMs) { return result }
        // enhance の2回目は +1ms でタイムスタンプを進める（video モードは単調増加が必須）
        if let enhanced = enhance(image), let result = detectAllVideoFrame(enhanced, timestampMs: timestampMs + 1) { return result }
        return []
    }

    // MARK: - Detection helpers

    private func detectAllImage(_ image: UIImage) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(image: mpImage),
              !result.faceLandmarks.isEmpty else { return nil }
        return Self.convertAll(result)
    }

    private func detectAllVideoFrame(_ image: UIImage, timestampMs: Int) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(
                  videoFrame: mpImage,
                  timestampInMilliseconds: timestampMs
              ),
              !result.faceLandmarks.isEmpty else { return nil }
        return Self.convertAll(result)
    }

    /// ぼやけ・白飛びに対して CIFilter で補正した画像を返す。
    private func enhance(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cgImage)
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.4,
                "inputShadowAmount":   0.1,
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": 0.6,
                "inputRadius":    1.5,
            ])
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    /// MediaPipe 結果の全顔を `[FaceLandmarkSet]` に変換する。
    /// 低いしきい値（暗所・ブレでも検出するため）で拾った誤検出を、幾何学的妥当性
    /// チェックで棄却する（例: 薄暗い場面で体を顔として検出するケース）。
    static func convertAll(_ result: FaceLandmarkerResult) -> [FaceLandmarkSet] {
        result.faceLandmarks.compactMap { face in
            let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
            let set = FaceLandmarkSet(points: points, confidence: confidence)
            return set.isPlausibleFace ? set : nil
        }
    }
}
#endif
