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

/// フレームの顔をどの検出経路が最初に拾ったか。精度計測（DValid）で
/// 「どのレバーが何フレーム救ったか」を1ランで帰属するための統計に使う。
public enum FaceDetectionSource: String {
    case mp          // MediaPipe FaceLandmarker 本検出（enhance なし）
    case enhance = "enh"  // enhance（moderate/aggressive/backlight）後に検出
    case bbox        // 補助検出器 bbox → ROI 再検出のみが拾った
    case roi         // テンポラル ROI 再検出（前フレーム bbox）
    case lowConf = "low"  // 低 confidence 最終フォールバック
    case none = ""   // 未検出
}

/// 検出ソース別の「そのソースが最初の顔を提供したフレーム数」。
public struct FaceDetectionSourceStats {
    public var mpFrames = 0
    public var enhanceFrames = 0
    public var bboxFrames = 0
    public var roiFrames = 0
    public var lowConfFrames = 0
}

/// Thin wrapper around MediaPipe's `FaceLandmarker` that produces the
/// framework-agnostic `FaceLandmarkSet` consumed by `MosaicRenderer`.
public final class MediaPipeFaceLandmarkerAdapter: FaceLandmarking {
    private let landmarker: FaceLandmarker
    /// VID モードのとき、bbox を ROI として食わせる専用の IMG モード landmarker。
    /// VID は1ストリームに専用なので別インスタンスが要る。用途は2つ:
    /// (1) 補助検出器が見つけた新規 bbox の再検出、(2) テンポラル ROI 再検出
    /// （前フレームで検出した顔の周辺の再走査）。runningMode == .video なら常時生成。
    private let landmarkerForCrop: FaceLandmarker?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let plausibilityMinSpan: CGFloat
    private let plausibilityEyeRatioRange: ClosedRange<CGFloat>
    /// 補助 bbox 検出器（Vision / Core ML / 並走など）。nil なら MP 単独。
    private let bboxDetector: FaceBBoxDetecting?

    // MARK: - テンポラル追跡（video モード専用）
    //
    // 全画面パイプライン（MP → enhance → 補助検出器）が全滅したフレームで、
    // 「前フレームで顔があった場所の周辺」だけを切り出して IMG モードで再走査する。
    // 顔は 1/15 秒で大きく動かないので、全画面では小さすぎ/暗すぎて拾えない顔も
    // 拡大された ROI 内でなら検出できることが多い。
    //
    // invariant: video モードの adapter インスタンスは「単一動画ストリームを時刻順に
    // 直列処理する」用途専用（DValid テストはメソッドごとに独立インスタンス、
    // アプリはプリスキャン Task / export キューが直列に使う）。並行呼び出しは想定しない。
    private struct TrackedFace {
        var box: CGRect
        var missCount: Int
    }
    private var trackedFaces: [TrackedFace] = []
    private var lastVideoTimestampMs: Int = .min
    /// ROI は前フレーム bbox を中心固定で何倍に広げるか。
    private let roiExpansion: CGFloat = 2.0
    /// 何フレーム連続で ROI 再検出に失敗したら track を破棄するか
    /// （15fps サンプリングで 8 フレーム ≒ 0.53 秒）。誤検出 track の自己増殖を防ぐ上限。
    private let maxTrackMisses = 8

    /// 直近フレームで最初の顔を提供した検出ソース（未検出なら `.none`）。
    /// インスタンスは単一ストリーム直列使用が前提（テスト・アプリとも直列）。
    public private(set) var lastSource: FaceDetectionSource = .none
    /// ソース別の累計フレーム数。精度計測でのレバー帰属用。
    public private(set) var sourceStats = FaceDetectionSourceStats()

    private func recordSource(_ source: FaceDetectionSource) {
        lastSource = source
        switch source {
        case .mp:       sourceStats.mpFrames += 1
        case .enhance:  sourceStats.enhanceFrames += 1
        case .bbox:     sourceStats.bboxFrames += 1
        case .roi:      sourceStats.roiFrames += 1
        case .lowConf:  sourceStats.lowConfFrames += 1
        case .none:     break
        }
    }

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
        // 目の間隔／顔幅の比。下限 0.40 は、補助検出器が体（胸・首・手）を bbox 化して
        // MP IMG モードで再検出させたときの誤フィットを弾くため。実測では乳首は 0.25〜0.31、
        // 正当な横顔は 0.41、正面顔は 0.55+。0.40 は 0.35→0.40 引き上げで「体の一部に顔メッシュ
        // をフィットしたが 0.35 を僅かに上回って通過」していたケースを排除する。
        self.plausibilityEyeRatioRange = 0.40...1.0
        self.landmarker = try FaceLandmarker(options: options)
        // useVision / useFaceDetector / useYunet の組み合わせから補助検出器を構築する。
        self.bboxDetector = Self.makeBBoxDetector(
            useVision: settings.useVision,
            useFaceDetector: settings.useFaceDetector,
            useYunet: settings.useYunet
        )
        // VID モードなら ROI 再検出用に IMG モードの landmarker を常時持つ
        // （補助検出器の新規 bbox 再検出と、テンポラル ROI 再検出の両方で使う。
        // 補助検出器なしの構成でもテンポラル追跡は動かしたい）。
        // IMG モード本体では同じ landmarker をそのまま使えるので追加不要。
        if runningMode == .video {
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

    private static func makeBBoxDetector(
        useVision: Bool,
        useFaceDetector: Bool,
        useYunet: Bool
    ) -> FaceBBoxDetecting? {
        var detectors: [FaceBBoxDetecting] = []
        if useVision         { detectors.append(AppleVisionFaceDetector()) }
        if useFaceDetector   { detectors.append(MediaPipeFaceBBoxDetector()) }
        if useYunet          { detectors.append(YuNetFaceDetector()) }
        switch detectors.count {
        case 0:  return nil
        case 1:  return detectors[0]
        default: return CompositeBBoxDetector(detectors)
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
        let (mp, mpSource) = mpDetectImageWithEnhance(image)
        guard bboxDetector != nil else {
            // MP が生検出しても妥当性フィルタで全棄却されると空になるため、
            // 「最初の顔を提供した」ソースは空でないときだけ記録する。
            recordSource(mp.isEmpty ? .none : mpSource)
            return mp
        }
        let result = augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: true)
        recordSource(mp.isEmpty ? (result.isEmpty ? .none : .bbox) : mpSource)
        return result
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        resetTracksIfNeeded(timestampMs: timestampMs)
        let (mp, mpSource) = mpDetectVideoWithEnhance(image, timestampMs: timestampMs)
        var result: [FaceLandmarkSet]
        var source: FaceDetectionSource
        if bboxDetector != nil {
            result = augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: false)
            source = mp.isEmpty ? (result.isEmpty ? .none : .bbox) : mpSource
        } else {
            result = mp
            source = mp.isEmpty ? .none : mpSource
        }
        if result.isEmpty {
            // 全画面パイプライン全滅 → 前フレームの顔位置周辺だけを再走査する最終手段。
            result = redetectFromTrackedBoxes(image: image)
            source = result.isEmpty ? .none : .roi
        } else {
            trackedFaces = result.map { TrackedFace(box: $0.boundingBox, missCount: 0) }
        }
        recordSource(source)
        return result
    }

    // MARK: - テンポラル ROI 再検出

    /// タイムスタンプが巻き戻った（新ストリーム/リスタート）か 1 秒を超えて飛んだ
    /// （シーク）場合は、前フレームの顔位置がもう意味を持たないので track を捨てる。
    private func resetTracksIfNeeded(timestampMs: Int) {
        if lastVideoTimestampMs != .min,
           timestampMs <= lastVideoTimestampMs || timestampMs - lastVideoTimestampMs > 1000 {
            trackedFaces.removeAll()
        }
        lastVideoTimestampMs = timestampMs
    }

    /// 前フレームで検出した顔の bbox を広げた ROI を IMG モードで再走査する。
    /// 採用条件は「妥当な顔であること」に加えて「前フレームと同じ顔とみなせる連続性」
    /// （IoU > 0.1 かつ面積比 0.3〜3.0）。誤検出が track を乗っ取って居座るのを防ぐ。
    private func redetectFromTrackedBoxes(image: UIImage) -> [FaceLandmarkSet] {
        guard let cropLandmarker = landmarkerForCrop, !trackedFaces.isEmpty else { return [] }
        var results: [FaceLandmarkSet] = []
        for index in trackedFaces.indices {
            let oldBox = trackedFaces[index].box
            let roi = expandedClamped(oldBox, factor: roiExpansion)
            guard roi.width > 0, roi.height > 0,
                  let cropped = cropImage(image, normalizedRect: roi),
                  let mpImage = try? MPImage(uiImage: upscaledIfSmall(cropped)),
                  let result = try? cropLandmarker.detect(image: mpImage),
                  let face = result.faceLandmarks.first else {
                trackedFaces[index].missCount += 1
                continue
            }
            let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            let confidence: Float = points.count >= FaceLandmarkSet.fullMeshCount ? 1.0 : 0.6
            let remapped = FaceLandmarkSet(points: points, confidence: confidence)
                .remapped(into: roi)
            let newBox = remapped.boundingBox
            let areaRatio = oldBox.width * oldBox.height > 0
                ? (newBox.width * newBox.height) / (oldBox.width * oldBox.height)
                : 0
            guard remapped.isPlausibleFace(
                      minSpan: plausibilityMinSpan,
                      eyeRatioRange: plausibilityEyeRatioRange
                  ),
                  iou(newBox, oldBox) > 0.1,
                  (0.3...3.0).contains(areaRatio) else {
                trackedFaces[index].missCount += 1
                continue
            }
            trackedFaces[index] = TrackedFace(box: newBox, missCount: 0)
            results.append(remapped)
        }
        trackedFaces.removeAll { $0.missCount >= maxTrackMisses }
        return results
    }

    /// `rect` を中心固定で `factor` 倍に広げ、[0, 1] にクランプした矩形を返す。
    /// クランプ後の矩形を crop と remap の両方に使うことで座標系のズレを避ける。
    private func expandedClamped(_ rect: CGRect, factor: CGFloat) -> CGRect {
        let cx = rect.midX, cy = rect.midY
        let w = rect.width * factor, h = rect.height * factor
        let x0 = max(0, cx - w / 2), y0 = max(0, cy - h / 2)
        let x1 = min(1, cx + w / 2), y1 = min(1, cy + h / 2)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 小さい ROI crop は MediaPipe の検出下限を割りやすいので、短辺が `minSide` px
    /// 未満なら拡大してから検出させる（小顔対策）。
    private func upscaledIfSmall(_ image: UIImage, minSide: CGFloat = 256) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(w, h)
        guard side > 0, side < minSide else { return image }
        let scale = minSide / side
        let newSize = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - MediaPipe (既存ロジックを切り出し)

    private func mpDetectImageWithEnhance(_ image: UIImage) -> ([FaceLandmarkSet], FaceDetectionSource) {
        if let result = detectAllImage(image) { return (result, .mp) }
        if let e1 = enhance(image, level: .moderate), let result = detectAllImage(e1) { return (result, .enhance) }
        if let e2 = enhance(image, level: .aggressive), let result = detectAllImage(e2) { return (result, .enhance) }
        if let e3 = enhance(image, level: .backlight), let result = detectAllImage(e3) { return (result, .enhance) }
        return ([], .none)
    }

    private func mpDetectVideoWithEnhance(_ image: UIImage, timestampMs: Int) -> ([FaceLandmarkSet], FaceDetectionSource) {
        if let result = detectAllVideoFrame(image, timestampMs: timestampMs) { return (result, .mp) }
        // enhance の各パスは +1ms ずつ進める（video モードは単調増加が必須）
        if let e1 = enhance(image, level: .moderate),
           let result = detectAllVideoFrame(e1, timestampMs: timestampMs + 1) { return (result, .enhance) }
        if let e2 = enhance(image, level: .aggressive),
           let result = detectAllVideoFrame(e2, timestampMs: timestampMs + 2) { return (result, .enhance) }
        if let e3 = enhance(image, level: .backlight),
           let result = detectAllVideoFrame(e3, timestampMs: timestampMs + 3) { return (result, .enhance) }
        return ([], .none)
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
        let rawBoxes = bboxDetector.detectFaceBoundingBoxes(in: image)
        if rawBoxes.isEmpty { return mpResults }
        // 補助検出器の生 bbox を「明らかに顔ではない形状」で前段ガードする。
        // (画面の 4% 未満 or アスペクト比が顔から大きく外れる) を捨てて、ROI 再検出のコストも節約する。
        let visionBoxes = rawBoxes.filter { box in
            guard box.width >= 0.04, box.height >= 0.04 else { return false }
            let ratio = box.width / box.height
            return ratio >= 0.5 && ratio <= 1.5
        }
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
