import XCTest
import AVFoundation
import MosaicCore
import UIKit
@testable import MaskMe

#if canImport(Metal)
import Metal

/// テスト用の単色 RGB（`large_tuple` を避けるための型）。
private struct RGBColor {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

/// フリーズフレーム挿入（アプリ層: `FreezeFrameFactory` / `MosaicEditorModel+Freeze`）のテスト。
///
/// Core 層（`TimelineStateFreeze` / `ObjectMaskEditOperations.masks(freezingClip:...)`）の
/// 数値仕様は Core 側のテストが担う。ここでは
///
/// - コマ抽出が「画面に見えているのと同じコマ」を取り出せているか（tolerance 0 / 向き）
/// - **4 つの引き継ぎ**のうち検出キャッシュ側の受け入れ不変条件
///   （「フリーズ直前の時刻でモザイクが乗る顔は、フリーズクリップの全区間でも乗る」）
/// - 出力尺・音声トラック 0 本
/// - undo 1 回で完全に元へ戻ること
///
/// を実測で固定する。
@MainActor
final class FreezeFrameTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let fps: Int32 = 30

    // MARK: - テスト素材生成（外部ファイルに依存しない）

    /// `colors` を 1 色 1 秒ずつ並べた単色 mp4 を作る（フレームごとに色が違う動画）。
    /// `transform` を渡すと `AVAssetWriterInput.transform`（= 素材の `preferredTransform`）
    /// を持つ「回転済み素材」を再現できる（縦動画の二重適用検出用）。
    private func makeColorSequenceVideo(
        colors: [RGBColor],
        transform: CGAffineTransform = .identity
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameIndex = 0
        for color in colors {
            for _ in 0..<Int(fps) {
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                guard let buffer = makeSolidBuffer(color: color) else { continue }
                adaptor.append(buffer, withPresentationTime:
                                CMTime(value: CMTimeValue(frameIndex), timescale: fps))
                frameIndex += 1
            }
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func makeSolidBuffer(color: RGBColor) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                base[offset] = color.b
                base[offset + 1] = color.g
                base[offset + 2] = color.r
                base[offset + 3] = 255       // A
            }
        }
        return buffer
    }

    /// 画像全体の平均 RGB（単色 mp4 のコマ判定に使う）。`nil` は取得失敗。
    private func averageColor(of image: UIImage) -> RGBColor? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rSum = 0, gSum = 0, bSum = 0
        let count = w * h
        for i in stride(from: 0, to: data.count, by: 4) {
            rSum += Int(data[i]); gSum += Int(data[i + 1]); bSum += Int(data[i + 2])
        }
        return RGBColor(r: UInt8(clamping: rSum / count), g: UInt8(clamping: gSum / count),
                        b: UInt8(clamping: bSum / count))
    }

    private func fakeFace(cx: Double = 0.5, cy: Double = 0.4, size: Double = 0.2) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.faceMosaicOn = true
        return model
    }

    // MARK: - 1. コマ抽出そのもの（`FreezeFrameFactory`）

    /// tolerance 0 で「画面に見えているのと同じコマ」が取れること。
    func test_extractFrame_picksColorAtRequestedTime() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        let asset = AVURLAsset(url: url)

        let red = try averageColor(of: FreezeFrameFactory.extractFrame(from: asset, atSourceTime: 0.5))
        let blue = try averageColor(of: FreezeFrameFactory.extractFrame(from: asset, atSourceTime: 1.5))

        let redColor = try XCTUnwrap(red)
        let blueColor = try XCTUnwrap(blue)
        XCTAssertGreaterThan(redColor.r, 200)
        XCTAssertLessThan(redColor.b, 60)
        XCTAssertGreaterThan(blueColor.b, 200)
        XCTAssertLessThan(blueColor.r, 60)
    }

    /// 取り出した `UIImage.imageOrientation` は常に `.up`（崩れると顔座標が横倒しになる）。
    func test_extractFrame_imageOrientationIsUp() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 255, g: 0, b: 0)])
        let frame = try FreezeFrameFactory.extractFrame(from: AVURLAsset(url: url), atSourceTime: 0)
        XCTAssertEqual(frame.imageOrientation, .up)
    }

    // MARK: - 2. フリーズ結果そのもの（`MosaicEditorModel.freezeFrame`）

    /// フリーズ結果の 1 フレーム目が、凍らせた時刻の色と一致すること。
    /// 出力尺は `PhotoClipEncoder.defaultClipSeconds`、音声トラックは 0 本であること。
    func test_freezeFrame_firstFrameMatchesTargetTime_durationAndNoAudio() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        let model = makeModel()
        let sourceID = UUID()
        model.sources[sourceID] = AVURLAsset(url: url)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        model.setClipsForTesting([clip])
        model.commitEdit()   // 履歴基準（undo テストと同じ流儀）

        await model.freezeFrame(clipID: clip.id, atDisplayTime: 1.5)   // 青の区間

        let freezeClip = try XCTUnwrap(model.clips.first(where: { $0.sourceID != sourceID }))
        XCTAssertEqual(freezeClip.sourceEnd - freezeClip.sourceStart,
                       PhotoClipEncoder.defaultClipSeconds, accuracy: 1e-6)

        let freezeAsset = try XCTUnwrap(model.sources[freezeClip.sourceID])
        let firstFrame = try FreezeFrameFactory.extractFrame(from: freezeAsset, atSourceTime: 0)
        let color = try XCTUnwrap(averageColor(of: firstFrame))
        XCTAssertGreaterThan(color.b, 200, "凍らせた瞬間（青の区間）と違う色が入っている")
        XCTAssertLessThan(color.r, 60)

        let audioTracks = try await freezeAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 0, "写真クリップに音声トラックがあってはならない")
    }

    /// 縦素材（`preferredTransform` が 90 度）で、出力の縦横比が表示比と一致すること
    /// （二重適用でも未適用でもないことの検証）。
    func test_freezeFrame_verticalSource_outputAspectMatchesDisplay() async throws {
        let transform = CGAffineTransform(rotationAngle: .pi / 2)
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 0, g: 255, b: 0)], transform: transform)
        let model = makeModel()
        let sourceID = UUID()
        model.sources[sourceID] = AVURLAsset(url: url)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        model.setClipsForTesting([clip])
        model.commitEdit()

        await model.freezeFrame(clipID: clip.id, atDisplayTime: 0.5)

        let freezeClip = try XCTUnwrap(model.clips.first(where: { $0.sourceID != sourceID }))
        let freezeAsset = try XCTUnwrap(model.sources[freezeClip.sourceID])
        let videoTrack = try await freezeAsset.loadTracks(withMediaType: .video).first
        let naturalSize = try await XCTUnwrap(videoTrack).load(.naturalSize)
        // 元素材は width=320 (横) / height=240（縦）で撮影され、90度回転で表示は縦長になる。
        // `PhotoClipEncoder` はピクセルへ焼き込んでエンコードするので、出力トラックの
        // naturalSize（transform なし）自体が縦長になっているはず。
        XCTAssertGreaterThan(naturalSize.height, naturalSize.width,
                             "appliesPreferredTrackTransform の二重適用/未適用でアスペクトが崩れている")
    }

    // MARK: - 3. 受け入れ不変条件（検出キャッシュの引き継ぎ）

    /// 「フリーズ直前の時刻でモザイクが乗る顔は、フリーズクリップの全区間でも乗る」。
    /// 静止画そのもの（単色フレーム）には顔が無いので実検出は空になるが、元クリップの
    /// キャッシュ（＝書き出し経路が使う顔）に仕込んだ顔は、フリーズ素材の t=0 に
    /// 引き継がれていなければならない。
    func test_freezeFrame_inheritsFaceFromOriginalCache_whenStillDetectionIsEmpty() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 128, g: 128, b: 128)])
        let model = makeModel()
        let sourceID = UUID()
        model.sources[sourceID] = AVURLAsset(url: url)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        model.setClipsForTesting([clip])
        model.commitEdit()

        // 書き出し経路（`DetectionBridge(interpolates: true)`）が拾えるよう、
        // 凍らせる時刻（0.5）の前後にブリッジ窓内で同じ顔を仕込む。
        let face = fakeFace()
        model.cacheStore.store([face], sourceID: sourceID, time: 0.4)
        model.cacheStore.store([face], sourceID: sourceID, time: 0.6)

        await model.freezeFrame(clipID: clip.id, atDisplayTime: 0.5)

        let freezeClip = try XCTUnwrap(model.clips.first(where: { $0.sourceID != sourceID }))
        let inherited = model.cacheStore.faces(sourceID: freezeClip.sourceID, time: 0)
        XCTAssertEqual(inherited?.count, 1,
                       "静止画検出が空でも、元クリップのキャッシュ由来の顔が t=0 に入っていない"
                       + "（＝凍らせた瞬間は書き出しで隠れていた顔が、フリーズフレームでは素通しになる）")
    }

    /// **本機能の合否そのもの: 凍らせた瞬間にモザイクが効いていたなら、
    /// フリーズクリップの全区間でも効くこと。**
    ///
    /// 適用区間（`applyRanges`）が空 = 適用なし（S11 で意味が反転済み）なので、
    /// フリーズクリップの区間を作り忘れる／条件を取り違えて外すと、**顔が写った
    /// 3 秒がノーモザイクで挟まる**。判定は書き出しと同じ `MosaicApplyGate.isActive`
    /// を通す（プレビュー側の述語を根拠にしない、というこの案件の規約）。
    ///
    /// 区間を外す側（モザイクが効いていなかったとき）のテストと**対**にしてある。
    /// 片方だけだと、条件を反転させる変異が素通りする。
    func test_freezeFrame_モザイクが効いていた時刻なら凍らせた区間も覆われる() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 128, g: 128, b: 128)])
        let model = makeModel()
        let sourceID = UUID()
        model.sources[sourceID] = AVURLAsset(url: url)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        // 元クリップ全体を覆う適用区間を置く（＝モザイクが効いている状態）。
        model.setTimelineForTesting(TimelineState(
            clips: [clip],
            applyRanges: [MosaicApplyRange(clipID: clip.id, sourceID: sourceID,
                                           sourceStart: 0, sourceEnd: 1)],
            sources: [sourceID: TimelineSource(id: sourceID, kind: .video)]))
        model.commitEdit()
        XCTAssertTrue(model.isMosaicActive(atComposition: 0.5),
                      "テスト前提: 凍らせる時刻でモザイクが効いていること")

        await model.freezeFrame(clipID: clip.id, atDisplayTime: 0.5)

        let freezeClip = try XCTUnwrap(model.clips.first(where: { $0.sourceID != sourceID }))
        XCTAssertTrue(model.timeline.applyRanges.contains { $0.sourceID == freezeClip.sourceID },
                      "凍らせた区間に適用区間が無い（顔が写っていればノーモザイクで挟まる）")
        // 書き出しと同じ判定で、フリーズクリップの区間**全体**が覆われていること。
        let span = try XCTUnwrap(model.mapping.clipSpans.first { $0.clip.id == freezeClip.id })
        for ratio in [0.01, 0.25, 0.5, 0.75, 0.99] {
            let t = span.start + (span.end - span.start) * ratio
            XCTAssertTrue(model.isMosaicActive(atComposition: t),
                          "フリーズクリップの \(Int(ratio * 100))% 地点が書き出し経路で覆われていない")
        }
    }

    // MARK: - 4. undo

    /// undo 1 回でタイムライン・手描き矩形が完全に元へ戻ること。
    func test_freezeFrame_undoRestoresOriginalTimeline() async throws {
        let url = try await makeColorSequenceVideo(colors: [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        let model = makeModel()
        let sourceID = UUID()
        model.sources[sourceID] = AVURLAsset(url: url)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        model.setClipsForTesting([clip])
        model.commitEdit()   // 履歴基準（`TimelineEditingModelTests` と同じ流儀）
        let timelineBefore = model.timeline

        await model.freezeFrame(clipID: clip.id, atDisplayTime: 1.0)
        XCTAssertNotEqual(model.timeline, timelineBefore, "フリーズが timeline へ反映されていない")

        model.undo()

        XCTAssertEqual(model.timeline, timelineBefore, "undo 1 回でタイムラインが完全に元へ戻っていない")
    }
}

#endif
