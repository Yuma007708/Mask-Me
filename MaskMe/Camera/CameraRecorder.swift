import AVFoundation
import CoreVideo

/// リアルタイム焼き込み録画。モザイク描画済みの CVPixelBuffer とマイクの
/// CMSampleBuffer を受け取り mp4 へ書く。原本フレームは一切受け取らない
/// （モザイク前の映像がディスクに残らないことをレコーダー層でも保証する）。
///
/// スレッド規約: `appendVideo` は映像キャプチャキュー、`appendAudio` は音声
/// キャプチャキューから呼ばれるため、writer への操作は内部ロックで直列化する。
final class CameraRecorder {
    enum RecorderError: Error {
        case setupFailed
        case finishFailed
    }

    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var sessionStarted = false
    private var finished = false
    private(set) var firstVideoSeconds: Double?
    private(set) var lastVideoSeconds: Double = 0

    /// - Parameters:
    ///   - size: 出力ピクセルサイズ（ポートレートの実バッファ寸法）。
    ///   - fps: ビットレート概算に使うフレームレート。
    ///   - includeAudio: マイク権限が拒否されたときは false（映像のみ）。
    init(size: CGSize, fps: Int, includeAudio: Bool) throws {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-\(UUID().uuidString).mp4")
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // VideoMosaicExporter と同じ方針: HEVC 優先、不可なら H.264。
        // ビットレートは約 0.15bpp × fps の概算。
        let bitrate = Int(size.width * size.height * 0.15 * Double(fps))
        func makeInput(codec: AVVideoCodecType) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        var input = makeInput(codec: .hevc)
        if !writer.canAdd(input) {
            input = makeInput(codec: .h264)
        }
        guard writer.canAdd(input) else { throw RecorderError.setupFailed }
        writer.add(input)
        videoInput = input

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        if includeAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw RecorderError.setupFailed }
    }

    /// 描画先バッファの供給元。ここから取ったバッファへモザイク済みフレームを
    /// 描いて `appendVideo` に渡す。
    var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    /// モザイク描画済みフレームを追記する。最初のフレームでセッションを開始する。
    /// - Returns: 追記できたか（writer 側が追いつかず落としたフレームは false）。
    @discardableResult
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return false }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstVideoSeconds = pts.seconds
        }
        guard videoInput.isReadyForMoreMediaData else { return false }
        let ok = adaptor.append(pixelBuffer, withPresentationTime: pts)
        if ok { lastVideoSeconds = pts.seconds }
        return ok
    }

    /// マイク音声を追記する。映像セッションが始まるまでのサンプルは捨てる
    /// （startSession 前の append は writer エラーになるため）。
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, sessionStarted,
              let audioInput, writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    /// 録画を確定してファイル URL を返す。
    func finish() async throws -> URL {
        lock.lock()
        finished = true
        let started = sessionStarted
        lock.unlock()

        guard started, writer.status == .writing else {
            writer.cancelWriting()
            throw RecorderError.finishFailed
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.finishFailed
        }
        return outputURL
    }

    /// 破棄（保存せず終了）。一時ファイルも消す。
    func cancel() {
        lock.lock()
        finished = true
        lock.unlock()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }
}
