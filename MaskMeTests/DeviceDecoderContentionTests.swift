import AVFoundation
import MosaicCore
import UIKit
import XCTest
@testable import MaskMe

#if !targetEnvironment(simulator)

/// **実機専用**: ハードウェアデコーダの奪い合いを検証する（実機テスト観点リスト P0-1）。
///
/// Simulator のデコードはソフトウェア実装で、実機のような枯渇が起きない。
/// この案件は「再生中にフレーム取り出しを続けると、数秒後から `copyCGImage` が
/// nil を返し続けてスキャンが無言で全滅する」という事故を実機で踏んでいる。
/// 対策（再生中はデコーダを明け渡して待つ）が**本当に効いているか**は、
/// 実機でしか確かめられない。
///
/// `#if !targetEnvironment(simulator)` で Simulator では丸ごと消える。
/// 常用の Simulator スイートの件数を動かさないためで、
/// 実行は `-destination 'platform=iOS,id=<UDID>'` のときだけ。
final class DeviceDecoderContentionTests: XCTestCase {
    private let width = 1280
    private let height = 720
    private let fps = 30
    private let seconds = 20.0
    private let boxSide = 200

    private let clipID = UUID()
    private let sourceID = UUID()

    private func objectLeft(at time: Double) -> Double { 100 + 40 * time }

    private func startRect() -> CGRect {
        CGRect(x: objectLeft(at: 0) / Double(width),
               y: Double((height - boxSide) / 2) / Double(height),
               width: Double(boxSide) / Double(width),
               height: Double(boxSide) / Double(height))
    }

    // MARK: - P0-1: 再生と追跡の同時実行

    /// **再生しながら追跡を始めても、再生を止めれば最後まで完走する。**
    ///
    /// 落ちるときの意味: デコーダを明け渡す待ち合わせが効いておらず、
    /// 追跡が途中で死んでいる（＝ユーザーには「追跡バッジが止まったまま」に見える）。
    func test_再生と同時に追跡しても完走する() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let mask = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           sourceTime: 0, rect: startRect())
        else { return XCTFail("マスクの生成に失敗") }

        // 実際のプレビューと同じく AVPlayer でデコーダを掴む。
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let playing = PlaybackFlag()
        await MainActor.run {
            player.play()
            playing.value = true
        }
        // 5 秒だけ再生してから止める（この間、追跡は待っているはず）。
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                player.pause()
                playing.value = false
            }
        }

        let started = Date()
        let tracks = await ObjectMaskTracker.track(
            [.init(mask: mask, clipID: clipID, sourceID: sourceID)],
            asset: asset, sourceRange: 0...seconds,
            shouldYield: { await MainActor.run { playing.value } },
            onProgress: { _ in })
        let elapsed = Date().timeIntervalSince(started)

        guard let track = tracks[mask.id] else {
            return XCTFail("再生と同時に追跡したら軌跡が 1 本も作れなかった（デコーダ枯渇の疑い）")
        }
        let coverage = track.coveredDuration / seconds
        XCTAssertGreaterThan(coverage, 0.9,
                             "追跡率 \(Int(coverage * 100))% / 所要 \(Int(elapsed))s")
        // 待ち合わせが効いていれば「再生 5 秒ぶんは進まない」ので、
        // 素材尺ぶんの追跡に少なくとも 5 秒は上乗せされる。
        XCTAssertGreaterThan(elapsed, 5, "再生中に待っていない（デコーダを明け渡していない）")
    }

    /// **待ち合わせを外すと何が起きるか**を数字で残す（対照条件・assert しない）。
    ///
    /// 実機のデコーダが実際に枯渇するかは iOS のバージョンと機種で変わる。
    /// ここで落とすとテストが環境依存で赤くなるので、**記録だけ**して合否は問わない。
    /// 対策側（上のテスト）が緑であることが合格条件で、こちらは
    /// 「対策に意味があるのか」を人間が判断するための材料。
    func test_計測_待ち合わせを外したときの追跡率() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let mask = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           sourceTime: 0, rect: startRect())
        else { return XCTFail("マスクの生成に失敗") }

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        await MainActor.run { player.play() }
        defer { Task { @MainActor in player.pause() } }

        let tracks = await ObjectMaskTracker.track(
            [.init(mask: mask, clipID: clipID, sourceID: sourceID)],
            asset: asset, sourceRange: 0...seconds,
            shouldYield: { false },          // わざと明け渡さない
            onProgress: { _ in })
        let coverage = (tracks[mask.id]?.coveredDuration ?? 0) / seconds
        print("[MMDEVICE] 待ち合わせなしの追跡率: \(Int(coverage * 100))%")
    }

    // MARK: - 素材の生成

    /// 再生に耐える 720p の動画。**1 フレームずつ画素を書かない**
    /// （実機で 600 フレーム × 92 万画素を Swift のループで回すと分単位で待たされる）。
    /// 背景と対象をあらかじめ `CGImage` にしておき、毎フレームは描画するだけにする。
    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let background = makeNoiseImage(width: width, height: height, block: 16)
        let object = makeNoiseImage(width: boxSide, height: boxSide, block: 4)
        let space = CGColorSpaceCreateDeviceRGB()

        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let time = Double(index) / Double(fps)
            autoreleasepool {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA, nil, &buffer)
                guard let pixels = buffer else { return }
                CVPixelBufferLockBaseAddress(pixels, [])
                defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
                guard let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(pixels),
                    width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
                if let background { context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height)) }
                if let object {
                    context.draw(object, in: CGRect(x: objectLeft(at: time),
                                                    y: Double((height - boxSide) / 2),
                                                    width: Double(boxSide), height: Double(boxSide)))
                }
                adaptor.append(pixels, withPresentationTime:
                                CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 決定的な擬似ランダムのグレー模様。`block` px 単位のブロックで、
    /// H.264 の量子化で潰れない粒度にしてある。
    private func makeNoiseImage(width: Int, height: Int, block: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var hash = UInt32(truncatingIfNeeded: (x / block) &* 73_856_093
                    ^ (y / block) &* 19_349_663)
                hash ^= hash >> 13
                hash = hash &* 1_274_126_177
                hash ^= hash >> 16
                pixels[y * width + x] = UInt8(truncatingIfNeeded: hash) | 0x20
            }
        }
        let space = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: space, bitmapInfo: [],
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// 再生中かどうかを追跡側へ渡すだけの入れ物（`MosaicEditorModel.isPlaying` の代役）。
@MainActor
private final class PlaybackFlag {
    var value = false
}

#endif
