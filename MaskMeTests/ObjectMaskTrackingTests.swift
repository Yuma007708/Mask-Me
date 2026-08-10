import AVFoundation
import MosaicCore
import UIKit
import XCTest
@testable import MaskMe

/// 物体マスクの自動追跡（O2）を**実際の動画で**検証する。
///
/// `ObjectTrackBuilderTests`（`swift test`）は合成した変換を流し込んでロジックだけを見る。
/// こちらは「OpenCV に本物のフレームを渡して、本当に対象へ貼り付くのか」を見る。
/// 追跡率と追従誤差を**数字で**出すのが目的で、閾値を緩めて通すためのテストではない。
final class ObjectMaskTrackingTests: XCTestCase {
    private let width = 480
    private let height = 270
    private let fps = 30
    private let seconds = 3.0
    /// 動く対象の一辺（px）。
    private let boxSide = 96

    private let clipID = UUID()
    private let sourceID = UUID()

    /// 時刻 t での対象の左上 x（px）。左から右へ等速 100px/秒。
    private func objectX(at time: Double) -> Double { 40 + 100 * time }
    private var objectY: Double { Double((height - boxSide) / 2) }

    private func trueRect(at time: Double) -> CGRect {
        CGRect(x: objectX(at: time) / Double(width), y: objectY / Double(height),
               width: Double(boxSide) / Double(width), height: Double(boxSide) / Double(height))
    }

    // MARK: - 追従

    /// **キーフレーム 1 個だけで、動く対象に最後まで貼り付く。**
    ///
    /// 追跡が無ければモザイクは最初の位置に留まり、1.5 秒後には対象から
    /// 矩形 1.5 個ぶん離れる（＝隠したいものが完全に露出する）。
    func test_キーフレーム1個で動く対象を最後まで追う() async throws {
        let url = try await makeMovingBoxVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let mask = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           sourceTime: 0, rect: trueRect(at: 0))
        else { return XCTFail("マスクの生成に失敗") }

        let tracks = await ObjectMaskTracker.track(
            [.init(mask: mask, clipID: clipID, sourceID: sourceID)],
            asset: asset, sourceRange: 0...seconds,
            shouldYield: { false }, onProgress: { _ in })

        guard let track = tracks[mask.id] else {
            return XCTFail("軌跡が 1 本も作れなかった（追跡が全滅している）")
        }
        // 追跡率: 素材尺のうち軌跡が埋めた割合。
        let coverage = track.coveredDuration / seconds
        XCTAssertGreaterThan(coverage, 0.95, "追跡率 \(Int(coverage * 100))%")

        // 追従誤差を全区間で測る（中心の正規化距離）。
        var worst = 0.0
        var baselineWorst = 0.0
        for step in 0...30 {
            let time = seconds * Double(step) / 30
            let truth = trueRect(at: time)
            guard let tracked = track.rect(atSourceTime: time) else {
                return XCTFail("t=\(time) で軌跡が途切れている")
            }
            worst = max(worst, hypot(tracked.midX - truth.midX, tracked.midY - truth.midY))
            let baseline = mask.rect(atSourceTime: time)
            baselineWorst = max(baselineWorst,
                                hypot(baseline.midX - truth.midX, baseline.midY - truth.midY))
        }
        // 実測（この素材・iPhone 17 Pro Simulator）: 追跡率 98.9%・最大中心誤差 0.0083。
        // 矩形の幅は 0.2 なので、誤差は幅の 4% で対象は十分収まっている。
        // 閾値 0.02 は実測の 2.4 倍——退行は捕まえるが、H.264 の量子化揺れでは落ちない幅。
        XCTAssertLessThan(worst, 0.02, "最大追従誤差 \(worst)（追跡なしなら \(baselineWorst)）")
        XCTAssertGreaterThan(baselineWorst, 0.3, "対照条件（追跡なし）が外れていない＝計測が壊れている")
    }

    /// **キーフレームには誤差ゼロで着地する。** 2 個目のキーフレームを真の位置に置き、
    /// その時刻で軌跡がキーフレームと一致することを見る（ドリフト補正の実地確認）。
    func test_軌跡はキーフレームを必ず通る() async throws {
        let url = try await makeMovingBoxVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        // 2 個目は**わざと真の位置から 0.05 ずらす**（ユーザーが手で直した状況）。
        var shifted = trueRect(at: 2.0)
        shifted.origin.x += 0.05
        guard let base = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           sourceTime: 0, rect: trueRect(at: 0))
        else { return XCTFail("マスクの生成に失敗") }
        let mask = base.settingKeyframe(atSourceTime: 2.0, rect: shifted, angle: 0)

        let tracks = await ObjectMaskTracker.track(
            [.init(mask: mask, clipID: clipID, sourceID: sourceID)],
            asset: asset, sourceRange: 0...seconds,
            shouldYield: { false }, onProgress: { _ in })
        guard let track = tracks[mask.id] else { return XCTFail("軌跡が作れなかった") }

        guard let atKeyframe = track.rect(atSourceTime: 2.0) else {
            return XCTFail("キーフレーム時刻に軌跡が無い")
        }
        XCTAssertEqual(atKeyframe.origin.x, shifted.origin.x, accuracy: 1e-9,
                       "ユーザーのキーフレームに着地していない")
    }

    /// **2 個のキーフレームの間で、直線補間より実際の動きに近い。**
    /// 対象は前半で一気に動いて後半は止まる。直線補間では中点が真値から大きく外れる。
    func test_キーフレーム間は直線補間より正確() async throws {
        let url = try await makeStopAndGoVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        // 対象: 0〜1 秒で 40→340px へ移動し、以降 340px で静止。
        let startRect = CGRect(x: 40.0 / Double(width), y: objectY / Double(height),
                               width: Double(boxSide) / Double(width),
                               height: Double(boxSide) / Double(height))
        var endRect = startRect
        endRect.origin.x = 340.0 / Double(width)
        guard let base = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           sourceTime: 0, rect: startRect)
        else { return XCTFail("マスクの生成に失敗") }
        let mask = base.settingKeyframe(atSourceTime: 2.0, rect: endRect, angle: 0)

        let tracks = await ObjectMaskTracker.track(
            [.init(mask: mask, clipID: clipID, sourceID: sourceID)],
            asset: asset, sourceRange: 0...seconds,
            shouldYield: { false }, onProgress: { _ in })
        guard let track = tracks[mask.id], let tracked = track.rect(atSourceTime: 1.0) else {
            return XCTFail("t=1.0 の軌跡が無い")
        }
        let truthX = endRect.origin.x                       // t=1.0 には既に止まっている
        let interpolatedX = mask.rect(atSourceTime: 1.0).origin.x   // 直線補間なら中点
        XCTAssertLessThan(abs(tracked.origin.x - truthX), abs(interpolatedX - truthX) / 2,
                          "追跡 \(tracked.origin.x) / 直線補間 \(interpolatedX) / 真値 \(truthX)")
    }

    // MARK: - 素材の生成

    /// 静止した背景の上を、模様つきの四角が等速で横切る動画。
    ///
    /// 背景にも模様を入れてあるのが要点。無地だと「背景に貼り付いた失敗」でも
    /// 特徴点が立たず、たまたま追跡できているように見えてしまう。
    private func makeMovingBoxVideo() async throws -> URL {
        try await makeVideo { time in self.objectX(at: time) }
    }

    /// 前半で一気に動き、後半は静止する動画（直線補間との差が出る動き）。
    private func makeStopAndGoVideo() async throws -> URL {
        try await makeVideo { time in min(340, 40 + 300 * time) }
    }

    private func makeVideo(objectX: @escaping (Double) -> Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // 追跡はテクスチャを見るので、圧縮で模様が潰れないよう十分なビットレートを与える。
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
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

        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let time = Double(index) / Double(fps)
            guard let buffer = makeFrame(objectLeft: Int(objectX(time).rounded())) else { continue }
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func makeFrame(objectLeft: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let top = Int(objectY)
        for y in 0..<height {
            for x in 0..<width {
                let inObject = x >= objectLeft && x < objectLeft + boxSide
                    && y >= top && y < top + boxSide
                // 対象は「対象内の座標」で模様を作る（＝模様ごと動く）。
                // 背景は絶対座標の粗いチェッカーで静止させる。
                let value: UInt8 = inObject
                    ? noise(x - objectLeft, y - top)
                    : (((x / 16) + (y / 16)) % 2 == 0 ? 70 : 120)
                let offset = y * bytesPerRow + x * 4
                base[offset] = value
                base[offset + 1] = value
                base[offset + 2] = value
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    /// 決定的な擬似ランダム模様（4px ブロック。H.264 で潰れない粒度にしてある）。
    private func noise(_ x: Int, _ y: Int) -> UInt8 {
        var hash = UInt32(truncatingIfNeeded: (x / 4) &* 73_856_093 ^ (y / 4) &* 19_349_663)
        hash ^= hash >> 13
        hash = hash &* 1_274_126_177
        hash ^= hash >> 16
        return UInt8(truncatingIfNeeded: hash) | 0x20
    }
}
