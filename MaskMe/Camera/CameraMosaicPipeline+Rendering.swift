import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 撮影パイプラインの描画層（Metal レンダリング）とピクセルバッファ変換ヘルパー。
///
/// 状態管理・制御・検出（`CameraMosaicPipeline.swift`）とは変更理由が別なので
/// 切り出してある。ここは `videoQueue`（フレーム処理キュー）からのみ呼ばれ、
/// `stateLock` で守る共有状態には触れない。
extension CameraMosaicPipeline {
    // MARK: - レンダリング

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable function_parameter_count
    /// 録画中: フル解像度でレコーダーのプールへ焼き込み、同じバッファから
    /// プレビュー（と要求があれば写真）を作る。
    func renderRecordingFrame(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        faces: [FaceLandmarkSet],
        options: [MosaicRenderer.FaceRenderOption],
        recorder: CameraRecorder,
        photoCompletion: ((UIImage?) -> Void)?,
        cache: CVMetalTextureCache
    ) {
        guard let inputTexture = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache),
              let pool = recorder.pixelBufferPool,
              let outBuffer = makePixelBuffer(from: pool),
              let outputTexture = MetalTextureUtilities.texture(from: outBuffer, cache: cache)
        else {
            photoCompletion?(nil)
            return
        }
        renderer.render(input: inputTexture, into: outputTexture,
                        landmarkSets: faces, faceOptions: options, waitForCompletion: true)
        recorder.appendVideo(outBuffer, at: pts)
        publishPreview(from: outBuffer)
        if let photoCompletion {
            let image = downscaledCGImage(from: outBuffer, maxWidth: .infinity)
                .map { UIImage(cgImage: $0) }
            photoCompletion(image)
        }
    }
    // swiftlint:enable function_parameter_count

    /// 写真撮影: フル解像度で新規テクスチャへ描画して UIImage 化する。
    func renderPhotoFrame(
        pixelBuffer: CVPixelBuffer,
        faces: [FaceLandmarkSet],
        options: [MosaicRenderer.FaceRenderOption],
        completion: (UIImage?) -> Void,
        cache: CVMetalTextureCache
    ) {
        guard let inputTexture = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache),
              let result = renderer.renderToNewTexture(
                  input: inputTexture, landmarkSets: faces, faceOptions: options),
              let cg = MetalTextureUtilities.cgImage(from: result.texture) else {
            completion(nil)
            return
        }
        completion(UIImage(cgImage: cg))
        onPreviewImage?(UIImage(cgImage: cg))
    }

    /// 待機中: 720px に縮小してから描画する（プレビュー再生と同じ負荷削減）。
    func renderPreviewOnlyFrame(pixelBuffer: CVPixelBuffer,
                                faces: [FaceLandmarkSet],
                                options: [MosaicRenderer.FaceRenderOption]) {
        guard let cg = downscaledCGImage(from: pixelBuffer, maxWidth: Self.previewMaxWidth),
              let inputTexture = try? MetalTextureUtilities.texture(
                  from: cg, device: renderer.device),
              let result = renderer.renderToNewTexture(
                  input: inputTexture, landmarkSets: faces, faceOptions: options),
              let outCG = MetalTextureUtilities.cgImage(from: result.texture) else { return }
        onPreviewImage?(UIImage(cgImage: outCG))
    }

    private func publishPreview(from pixelBuffer: CVPixelBuffer) {
        guard let cg = downscaledCGImage(from: pixelBuffer, maxWidth: Self.previewMaxWidth) else {
            return
        }
        onPreviewImage?(UIImage(cgImage: cg))
    }

    // MARK: - 変換ヘルパー

    /// 横長（センサー素通し）のバッファを 90° 時計回りに回転して縦長へ正規化する。
    /// 縦長で届いたフレーム（コネクション回転が効いている通常ケース）は素通し。
    /// iPhone の前面・背面ともセンサーは同じ横置きで、ポートレート正立は 90° CW
    /// （旧 API の videoOrientation=.portrait と同じ物理回転。ミラーは別概念で、
    /// 本パイプラインは常に非ミラーを前提とする）。
    func normalizedPortraitBuffer(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > height else { return buffer }

        let outSize = CGSize(width: height, height: width)
        if portraitPool == nil || portraitPoolSize != outSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outSize.width),
                kCVPixelBufferHeightKey as String: Int(outSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            portraitPool = pool
            portraitPoolSize = outSize
        }
        guard let pool = portraitPool, let out = makePixelBuffer(from: pool) else {
            return buffer
        }
        let rotated = CIImage(cvPixelBuffer: buffer).oriented(.right)
        ciContext.render(rotated, to: out)
        return out
    }

    func downscaledCGImage(from pixelBuffer: CVPixelBuffer,
                           maxWidth: Double) -> CGImage? {
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let scale = min(maxWidth / width, 1.0)
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if scale < 0.99 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
#endif
