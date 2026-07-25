import AVFoundation
import UIKit

/// 写真（UIImage）を指定秒数の静止 mp4 へ事前エンコードする（S6・アーキテクチャ決定 3）。
///
/// 写真クリップを「動画素材の一種」にすることで、composition / プレビュー /
/// エクスポート / サムネ / 下書きの全既存経路が無分岐で動く。
///
/// 仕様:
/// - 15fps・音声トラックなし
/// - 尺は指定秒数（**上限 60s** でクランプ。下限は 1 フレーム分）
/// - 長辺 1920px 上限（超える場合のみ縮小。アスペクト維持・偶数ピクセルへ丸め）
/// - **EXIF 向きの正規化をエンコードより先に行う**（`UIImage.draw` が orientation を
///   適用した .up のピクセルを書き出す。正規化前の cgImage を直接書くと横向き撮影の
///   写真が寝たままエンコードされる — S6 の最重要レビュー項目）
struct PhotoClipEncoder {
    enum EncodeError: Error {
        case invalidImage
        case writerSetupFailed
        case pixelBufferCreationFailed
        case appendFailed
    }

    /// エンコード結果。`normalizedImage` は書き出したフレームと同一ピクセル
    /// （向き正規化・縮小済み）で、検出 seed の入力に使う。
    struct EncodedPhotoClip {
        let url: URL
        /// クランプ後の実尺（秒）。クリップの `sourceEnd` に使う。
        let duration: Double
        let normalizedImage: UIImage
    }

    static let frameRate: Double = 15
    static let maxDuration: Double = 60
    static let maxLongSidePixels: CGFloat = 1920

    /// 写真を静止 mp4 へエンコードして一時ファイル URL を返す。
    ///
    /// - Parameter seconds: クリップの尺（秒）。[1 フレーム, 60s] にクランプされる。
    func encode(image: UIImage, seconds: Double) async throws -> EncodedPhotoClip {
        // 1) 向き正規化 + 長辺 1920px 縮小（必ずエンコードより先）。
        let normalized = Self.normalizedForEncoding(image)
        guard let cgImage = normalized.cgImage else { throw EncodeError.invalidImage }

        // 2) クランプ済みの尺とフレーム数。NaN は既定尺（1s）に落として写像を汚染しない。
        let safeSeconds = seconds.isNaN ? 1.0 : seconds
        let clampedSeconds = min(max(safeSeconds, 1.0 / Self.frameRate), Self.maxDuration)
        let frameCount = max(1, Int((clampedSeconds * Self.frameRate).rounded()))

        // 3) 静止フレームを 1 枚だけ描き、同じバッファを全フレームに使い回す。
        let width = cgImage.width
        let height = cgImage.height
        let buffer = try Self.makePixelBuffer(from: cgImage, width: width, height: height)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoclip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EncodeError.writerSetupFailed }
        writer.add(input)
        // adaptor は startWriting() より**前**に作ること（開始後の生成は
        // NSInvalidArgumentException で即クラッシュする）。
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard writer.startWriting() else { throw writer.error ?? EncodeError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        // 15fps を整数で表せる timescale（1 フレーム = 100/1500s = 1/15s）。
        let timescale = CMTimeScale(Self.frameRate * 100)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pts = CMTime(value: CMTimeValue(index * 100), timescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                writer.cancelWriting()
                throw writer.error ?? EncodeError.appendFailed
            }
        }
        input.markAsFinished()
        // 最終フレームにも 1/15s の表示時間を与え、出力尺を frameCount/15 に確定させる
        // （endSession が無いと最終フレームの尺が不定になり、クリップ尺と実尺がずれる）。
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount * 100),
                                               timescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EncodeError.writerSetupFailed
        }
        return EncodedPhotoClip(url: url,
                                duration: Double(frameCount) / Self.frameRate,
                                normalizedImage: normalized)
    }

    // MARK: - 正規化（EXIF 向き + 長辺 1920px + 偶数ピクセル）

    /// EXIF 向きを適用した .up のピクセルへ再描画し、長辺を 1920px 以下へ縮小する。
    ///
    /// `UIImage.size` は orientation 適用後の寸法（point）なので、`size × scale` が
    /// 表示どおりのピクセル寸法になる。H.264 は奇数ピクセルで色差が壊れる
    /// エンコーダがあるため、幅・高さとも偶数へ切り下げる。
    static func normalizedForEncoding(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return image }
        let downScale = min(1.0, maxLongSidePixels / max(pixelWidth, pixelHeight))
        let targetWidth = max(2, floor(pixelWidth * downScale / 2) * 2)
        let targetHeight = max(2, floor(pixelHeight * downScale / 2) * 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // 出力ピクセル = 指定サイズ（Retina 倍率を掛けない）
        format.opaque = true   // 動画フレームにアルファは不要（JPEG 写真は不透明）
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetWidth, height: targetHeight), format: format)
        return renderer.image { _ in
            // draw(in:) が imageOrientation を適用して .up のピクセルを生成する。
            image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
    }

    /// 正規化済み CGImage を BGRA の CVPixelBuffer へ描く（全フレーム共用の 1 枚）。
    private static func makePixelBuffer(from cgImage: CGImage,
                                        width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw EncodeError.pixelBufferCreationFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw EncodeError.pixelBufferCreationFailed }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
