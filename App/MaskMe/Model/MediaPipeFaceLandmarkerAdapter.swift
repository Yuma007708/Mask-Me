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
public func makeFaceLandmarker(
    forVideo: Bool = false,
    settings: DetectionSettings = DetectionSettings(),
    modelName: String = "face_landmarker"
) -> FaceLandmarking {
    #if canImport(MediaPipeTasksVision)
    if let path = Bundle.main.path(forResource: modelName, ofType: "task"),
       let adapter = try? MediaPipeFaceLandmarkerAdapter(
           modelPath: path,
           runningMode: forVideo ? .video : .image,
           settings: settings
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
    /// VID モードのとき、補助検出器で見つけた追加 bbox を ROI として食わせる
    /// 専用の IMG モード landmarker。VID は1ストリームに専用なので別インスタンスが要る。
    /// bboxDetector == nil、または runningMode が .image のときは nil。
    private let landmarkerForCrop: FaceLandmarker?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let plausibilityMinSpan: CGFloat
    private let plausibilityEyeRatioRange: ClosedRange<CGFloat>
    /// 補助 bbox 検出器（Vision / Core ML / 並走など）。nil なら MP 単独。
    private let bboxDetector: FaceBBoxDetecting?

    /// - Parameter modelPath: path to the bundled `face_landmarker.task` model.
    public init(modelPath: String, runningMode: RunningMode = .video,
                settings: DetectionSettings = DetectionSettings()) throws {
        // confidence は (0, 1] が有効。0 や永続化された不正値を渡すと MediaPipe の
        // 初期化が失敗し、呼び出し側が NullFaceLandmarker（無検出）に落ちてしまうため、
        // 安全範囲にクランプして「設定値が原因で一切検出されない」回帰を防ぐ。
        func clampConfidence(_ value: Float) -> Float { min(max(value, 0.01), 1.0) }

        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numFaces = max(settings.numFaces, 1)
        options.minFaceDetectionConfidence = clampConfidence(settings.minFaceDetectionConfidence)
        options.minFacePresenceConfidence  = clampConfidence(settings.minFacePresenceConfidence)
        options.minTrackingConfidence      = clampConfidence(settings.minTrackingConfidence)
        self.plausibilityMinSpan = CGFloat(settings.minSpan)
        // 目の間隔／顔幅の比。下限 0.35 で、裸の体（乳首・胸を顔メッシュに誤フィット）を
        // 棄却する。裸動画の全フレーム実測では乳首誤検出が eyeRatio 0.25〜0.31、正当な
        // 横顔は 0.41、正面顔は 0.55 以上で、0.35 が乳首と顔を分ける閾値。
        self.plausibilityEyeRatioRange = 0.35...1.0
        self.landmarker = try FaceLandmarker(options: options)
        // 設定の faceDetectorBackend に応じて補助検出器を構築する。
        self.bboxDetector = Self.makeBBoxDetector(for: settings.faceDetectorBackend)
        // VID モードかつ補助検出器があるなら、ROI 再検出用に IMG モードの landmarker を追加で持つ。
        // IMG モード本体では同じ landmarker をそのまま使えるので追加不要。
        if bboxDetector != nil && runningMode == .video {
            let imgOptions = FaceLandmarkerOptions()
            imgOptions.baseOptions.modelAssetPath = modelPath
            imgOptions.runningMode = .image
            imgOptions.numFaces = 1  // ROI 内には基本 1 顔
            imgOptions.minFaceDetectionConfidence = clampConfidence(settings.minFaceDetectionConfidence)
            imgOptions.minFacePresenceConfidence  = clampConfidence(settings.minFacePresenceConfidence)
            imgOptions.minTrackingConfidence      = clampConfidence(settings.minTrackingConfidence)
            self.landmarkerForCrop = try? FaceLandmarker(options: imgOptions)
        } else {
            self.landmarkerForCrop = nil
        }
    }

    private static func makeBBoxDetector(for backend: FaceDetectorBackend) -> FaceBBoxDetecting? {
        switch backend {
        case .off:
            return nil
        case .vision:
            return AppleVisionFaceDetector()
        case .faceDetector:
            return MediaPipeFaceBBoxDetector()
        case .both:
            return CompositeBBoxDetector([AppleVisionFaceDetector(), MediaPipeFaceBBoxDetector()])
        }
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
        let mp = mpDetectImageWithEnhance(image)
        guard bboxDetector != nil else { return mp }
        return augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: true)
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        let mp = mpDetectVideoWithEnhance(image, timestampMs: timestampMs)
        guard bboxDetector != nil else { return mp }
        return augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: false)
    }

    // MARK: - MediaPipe (既存ロジックを切り出し)

    private func mpDetectImageWithEnhance(_ image: UIImage) -> [FaceLandmarkSet] {
        if let result = detectAllImage(image) { return result }
        if let e1 = enhance(image, level: .moderate), let result = detectAllImage(e1) { return result }
        if let e2 = enhance(image, level: .aggressive), let result = detectAllImage(e2) { return result }
        if let e3 = enhance(image, level: .backlight), let result = detectAllImage(e3) { return result }
        return []
    }

    private func mpDetectVideoWithEnhance(_ image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        if let result = detectAllVideoFrame(image, timestampMs: timestampMs) { return result }
        // enhance の各パスは +1ms ずつ進める（video モードは単調増加が必須）
        if let e1 = enhance(image, level: .moderate),
           let result = detectAllVideoFrame(e1, timestampMs: timestampMs + 1) { return result }
        if let e2 = enhance(image, level: .aggressive),
           let result = detectAllVideoFrame(e2, timestampMs: timestampMs + 2) { return result }
        if let e3 = enhance(image, level: .backlight),
           let result = detectAllVideoFrame(e3, timestampMs: timestampMs + 3) { return result }
        return []
    }

    // MARK: - 補助 bbox 検出器による補完

    /// MP の検出結果に対し、補助検出器（Apple Vision / Core ML / 並走）で見つかった bbox のうち
    /// MP と重ならないものを ROI として MP IMG モードに再検出させ、得られた 478 ランドマークを
    /// 元画像座標に逆変換して追加する。取れなかった bbox は捨てる（合成メッシュは作らない＝品質第一）。
    private func augmentWithBBoxDetector(
        image: UIImage,
        mpResults: [FaceLandmarkSet],
        useImageMode: Bool
    ) -> [FaceLandmarkSet] {
        guard let bboxDetector else { return mpResults }
        let visionBoxes = bboxDetector.detectFaceBoundingBoxes(in: image)
        if visionBoxes.isEmpty { return mpResults }
        let mpBoxes = mpResults.map { $0.boundingBox }
        let novelBoxes = visionBoxes.filter { vb in
            !mpBoxes.contains { iou($0, vb) > 0.3 }
        }
        if novelBoxes.isEmpty { return mpResults }

        // IMG モード自身は本体 landmarker を流用、VID は IMG 専用の追加 landmarker を使う。
        let cropLandmarker = useImageMode ? landmarker : landmarkerForCrop
        guard let cropLandmarker else { return mpResults }

        var extras: [FaceLandmarkSet] = []
        for box in novelBoxes {
            guard let cropped = cropImage(image, normalizedRect: box),
                  let mpImage = try? MPImage(uiImage: cropped),
                  let result = try? cropLandmarker.detect(image: mpImage),
                  let face = result.faceLandmarks.first else { continue }
            let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
            let raw = FaceLandmarkSet(points: points, confidence: confidence)
            let remapped = raw.remapped(into: box)
            // 妥当性フィルタを通す（裸の体などを誤検出しても排除されるよう、本体と同じ条件で判定）。
            if remapped.isPlausibleFace(
                minSpan: plausibilityMinSpan,
                eyeRatioRange: plausibilityEyeRatioRange
            ) {
                extras.append(remapped)
            }
        }
        return mpResults + extras
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// 画像を正規化 rect (左上原点・[0, 1]) で切り抜く。`cropping(to:)` のために
    /// ピクセル座標へ変換し、画像範囲内にクランプする。
    private func cropImage(_ image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let x = max(0, normalizedRect.minX * w)
        let y = max(0, normalizedRect.minY * h)
        let pxRect = CGRect(
            x: x, y: y,
            width: min(w - x, normalizedRect.width * w),
            height: min(h - y, normalizedRect.height * h)
        ).integral
        guard pxRect.width > 0, pxRect.height > 0,
              let cropped = cg.cropping(to: pxRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Detection helpers

    private func detectAllImage(_ image: UIImage) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(image: mpImage),
              !result.faceLandmarks.isEmpty else { return nil }
        return convertAll(result)
    }

    private func detectAllVideoFrame(_ image: UIImage, timestampMs: Int) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(
                  videoFrame: mpImage,
                  timestampInMilliseconds: timestampMs
              ),
              !result.faceLandmarks.isEmpty else { return nil }
        return convertAll(result)
    }

    private enum EnhanceLevel { case moderate, aggressive, backlight }

    /// 暗所・ぼやけ・逆光補正。
    /// moderate: 軽微な暗さ・白飛びを改善。
    /// aggressive: 暗い動画・夜間シーンで顔を検出できるよう全体を大幅増光。
    /// backlight: 逆光・人物のシルエットだけ暗いシーン向け。明部を強く抑え暗部を最大に持ち上げる。
    private func enhance(_ image: UIImage, level: EnhanceLevel) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cgImage)
        switch level {
        case .moderate:
            ci = ci
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.6,
                    "inputShadowAmount":    0.5,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.5,
                    "inputRadius":    1.5,
                ])
        case .aggressive:
            ci = ci
                .applyingFilter("CIExposureAdjust", parameters: [
                    "inputEV": 1.5,           // +1.5段分（約2.8倍）明るく
                ])
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.8,
                    "inputShadowAmount":    0.9,
                ])
                .applyingFilter("CIColorControls", parameters: [
                    "inputContrast":   1.1,
                    "inputBrightness": 0.05,
                    "inputSaturation": 1.0,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.7,
                    "inputRadius":    1.5,
                ])
        case .backlight:
            // 逆光対策: 明部を抑え、暗部を最大に持ち上げ、ガンマでさらに暗部ディテールを引き出す。
            ci = ci
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.3,
                    "inputShadowAmount":    1.0,
                ])
                .applyingFilter("CIGammaAdjust", parameters: [
                    "inputPower": 0.65,    // < 1.0 で暗部側を強く持ち上げる
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.6,
                    "inputRadius":    1.2,
                ])
        }
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    /// MediaPipe 結果の全顔を `[FaceLandmarkSet]` に変換する。
    /// 低いしきい値（暗所・ブレでも検出するため）で拾った誤検出を、幾何学的妥当性
    /// チェックで棄却する（例: 薄暗い場面で体や乳首を顔として検出するケース）。
    /// 全件棄却したらそのまま 0 件を返す（生検出を信頼するフォールバックは入れない。
    /// 唯一の検出が誤検出だった場合に乳首などを復活させてしまうため）。
    private func convertAll(_ result: FaceLandmarkerResult) -> [FaceLandmarkSet] {
        result.faceLandmarks.compactMap { face in
            let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
            let set = FaceLandmarkSet(points: points, confidence: confidence)
            return set.isPlausibleFace(minSpan: plausibilityMinSpan,
                                       eyeRatioRange: plausibilityEyeRatioRange) ? set : nil
        }
    }
}
#endif
