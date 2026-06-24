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
