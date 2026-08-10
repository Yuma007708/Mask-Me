//  PersonSegmenter.swift
//
//  Produces a *background* mask (person foreground inverted) used by the
//  "background only" mosaic. Uses Apple's Vision person-segmentation, which is
//  on-device and needs no bundled model — so `MosaicCore` stays dependency-free
//  (Vision is linked only here in the app target).
//
//  The returned mask is single-channel 8-bit (`0` = subject/foreground,
//  `255` = background). It is sampled in normalized UV by the Metal kernel, so
//  it does not need to match the input resolution.

import CoreVideo
import CoreGraphics
import MosaicCore

#if canImport(Vision)
import Vision

/// A stateless wrapper around `VNGeneratePersonSegmentationRequest`. Safe to call
/// from any thread (a fresh request handler is created per call).
public final class PersonSegmenter: @unchecked Sendable {
    private let quality: VNGeneratePersonSegmentationRequest.QualityLevel

    /// - Parameter quality: `.balanced` trades a little accuracy for speed, which
    ///   suits per-frame video use. Photos can pass `.accurate`.
    public init(quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        self.quality = quality
    }

    /// Vision の人物切り抜きがこの実行環境で実際に動くか。**1 回だけ実測して覚える。**
    ///
    /// Simulator では `VNGeneratePersonSegmentationRequest` が
    /// `E5RT is not supported` で失敗する（実機は通る。arm64 Mac / iPhone 17 Simulator で確認）。
    /// `backgroundMask` は失敗を `nil` で返し、呼び出し元はそれをエラー扱いしないため、
    /// **判定が無いと「背景だけモザイクが黙って効いていない」状態に誰も気づけない。**
    /// テストはこの値を見て `XCTSkip` する（`nil` を正常として通さないため）。
    ///
    /// `canImport(Vision)` はコンパイル時の話で、実行環境で動くかは別問題なので実測する。
    public static let isAvailable: Bool = probeAvailability()

    private static func probeAvailability() -> Bool {
        guard let image = probeImage() else { return false }
        let request = VNGeneratePersonSegmentationRequest()
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return false
        }
        return request.results?.first != nil
    }

    /// 判定専用の無地画像。人が写っている必要はない（人物の有無ではなく、
    /// リクエストが実行できるかだけを見るため）。
    private static func probeImage() -> CGImage? {
        let side = 64
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// 使えない環境で 1 度だけ知らせる。`static let` の遅延初期化を使っているので
    /// 何度踏んでも 1 回しか出ず、ロックも要らない。
    private static let unavailabilityNotice: Void = {
        print("[MMSEG] Vision の人物切り抜きがこの環境では使えないため、"
              + "背景だけモザイクは無効のまま動作します（Simulator では既知）。")
    }()

    /// Background mask for a still image.
    public func backgroundMask(cgImage: CGImage) -> MaskBuffer? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return run(handler)
    }

    /// Background mask for a video frame / camera buffer.
    public func backgroundMask(pixelBuffer: CVPixelBuffer) -> MaskBuffer? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        return run(handler)
    }

    private func run(_ handler: VNImageRequestHandler) -> MaskBuffer? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try handler.perform([request])
        } catch {
            _ = Self.unavailabilityNotice
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return invertedMask(from: observation.pixelBuffer)
    }

    /// Copies the foreground mask out of `buffer`, inverting it so the background
    /// becomes the high (mosaicked) value, and packs it into tightly-rowed bytes.
    private func invertedMask(from buffer: CVPixelBuffer) -> MaskBuffer? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)

        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let srcRow = y * srcRowBytes
                let dstRow = y * width
                for x in 0..<width {
                    dst[dstRow + x] = 255 &- src[srcRow + x]
                }
            }
        }
        return MaskBuffer(bytes: bytes, width: width, height: height)
    }
}
#endif
