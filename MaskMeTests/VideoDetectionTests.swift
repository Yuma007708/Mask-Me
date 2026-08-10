import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// Runs the real MediaPipe landmarker over a short fixture clip frame-by-frame,
/// measuring the per-video detection rate and confirming tracking locks on.
/// Requires the pod + model + `Fixtures/sample_face.mov`; otherwise `XCTSkip`.
final class VideoDetectionTests: XCTestCase {
    /// faces in the clip should be detected across most frames.
    private let minVideoDetectionRate = 80.0
    /// Sample at ~5 fps; enough to exercise tracking without long test runs.
    private let frameInterval = 0.2

    func testDetectionRateAndTrackingOverVideo() throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let url = FixtureLoader.videoURL(named: "sample_face") else {
            throw XCTSkip("Fixtures/sample_face.mov がありません")
        }

        let adapter = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)
        let frames = try Self.extractFrames(from: url, interval: frameInterval)
        try XCTSkipIf(frames.isEmpty, "動画からフレームを抽出できませんでした")

        var meter = DetectionRateMeter()
        var evaluator = TrackingEvaluator()
        var didLock = false

        for (index, frame) in frames.enumerated() {
            let timestampMs = Int(Double(index) * frameInterval * 1000)
            let set = adapter.landmarks(in: frame, timestampMs: timestampMs)
            meter.record(set)
            let status = evaluator.update(confidence: set?.confidence)
            if status.state == .tracking { didLock = true }
        }

        XCTAssertGreaterThanOrEqual(
            meter.detectionRate,
            minVideoDetectionRate,
            "動画の検出率 \(meter.detectionRate)% が目標 \(minVideoDetectionRate)% 未満 "
                + "(\(meter.detectedCount)/\(meter.total))"
        )
        XCTAssertTrue(didLock, "追従が一度も .tracking にロックしませんでした")
    }

    /// 検出率が高くても、**1 フレームだけ検出が抜ける**とモザイクが一瞬外れて見える
    /// （実機で確認。全候補 crop 再検証を入れた直後に発生し、`verifiedMemory` の猶予で対処）。
    /// 平均検出率のテストはこの穴を検出できない（80% 以上なら 1 フレーム抜けは通る）ので、
    /// 「検出あり → 抜け → 検出あり」で挟まれた孤立した抜けの数を直接数える。
    /// 実運用と同じ 15fps バケットで走査する。
    /// **現状このテストに検出力はない。** 実機で報告されたちらつきは、手元の
    /// `sample_face` / `profile` では猶予（`verifiedMemory`）の有無にかかわらず 0 件で
    /// 再現しなかった（計測済み）。再現する素材が手に入るまでは「将来の退行を止める枠」
    /// にすぎないので、このテストが green であることをちらつき解消の根拠にしないこと。
    func testNoIsolatedDetectionGaps() throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        let urls = ["sample_face", "profile"].compactMap { name in
            FixtureLoader.videoURL(named: name).map { (name, $0) }
        }
        try XCTSkipIf(urls.isEmpty, "Fixtures に検証用の動画がありません")

        var failures: [String] = []
        for (name, url) in urls {
            let adapter = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath,
                                                            runningMode: .video)
            let interval = 1.0 / 15.0
            let frames = try Self.extractFrames(from: url, interval: interval)
            if frames.count < 3 { continue }

            let detected: [Bool] = frames.enumerated().map { index, frame in
                adapter.landmarks(in: frame,
                                  timestampMs: Int(Double(index) * interval * 1000)) != nil
            }
            let isolatedGaps = (1..<(detected.count - 1)).filter {
                !detected[$0] && detected[$0 - 1] && detected[$0 + 1]
            }
            if !isolatedGaps.isEmpty {
                failures.append("\(name): index=\(isolatedGaps) 全 \(detected.count) フレーム")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "検出が 1 フレームだけ抜けている（モザイクが一瞬外れる）:\n"
                + failures.joined(separator: "\n")
        )
    }

    /// 第2段（範囲指定シードの前後走査）の回帰テスト。矩形サーチはシード時刻の
    /// バケットしか埋めないため、そこから離れた時刻では顔が出ず素通しになっていた
    /// （`MosaicEditorModel+RegionSeeding.swift` の doc 参照）。ここでは矩形サーチの
    /// 代わりに動画中央のフレームを直接検出して `RegionSeed` を作り、
    /// `enqueueRegionSeed` → `awaitRegionSeeding()` を実際の `MosaicEditorModel` へ
    /// 通したあと、**シード時刻より前**のバケットにも検出が増えていることを確認する。
    @MainActor
    func testRegionSeedBackfillsBucketsBeforeSeedTime() async throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let url = FixtureLoader.videoURL(named: "sample_face") else {
            throw XCTSkip("Fixtures/sample_face.mov がありません")
        }

        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        try XCTSkipIf(duration < 2.0, "動画が短すぎます（2秒未満）")

        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        let sourceID = UUID()
        model.sources[sourceID] = asset

        // シード時刻より 1 秒前のバケットは、まだ何も検出していない。
        let seedTime = duration / 2
        let earlyTime = model.liveBucket(max(0, seedTime - 1.0))
        XCTAssertTrue(model.lookupFaces(sourceID: sourceID, sourceTime: earlyTime).isEmpty,
                     "前提が崩れている: シード前のバケットが最初から空でない")

        // 矩形サーチの代わりに、シード時刻のフレームを直接検出する。
        let scanner = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .image)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var actualTime = CMTime.zero
        guard let cg = try? generator.copyCGImage(
            at: CMTime(seconds: seedTime, preferredTimescale: 600), actualTime: &actualTime
        ) else {
            throw XCTSkip("シード時刻のフレームを取り出せませんでした")
        }
        let faces = scanner.allLandmarks(in: UIImage(cgImage: cg))
        try XCTSkipIf(faces.isEmpty, "シード時刻で顔を検出できませんでした")

        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: sourceID, asset: asset, sourceRange: 0...duration, clipID: UUID(),
            seedTime: actualTime.seconds, seedLandmarks: faces[0],
            targetID: UUID(), personID: nil))
        await model.awaitRegionSeeding()

        XCTAssertFalse(
            model.lookupFaces(sourceID: sourceID, sourceTime: earlyTime).isEmpty,
            "双方向走査後もシード時刻より前のバケットに検出が増えていない（冒頭が素通しのまま）"
        )
    }

    /// Decodes frames at a fixed interval into `UIImage`s.
    private static func extractFrames(from url: URL, interval: Double) throws -> [UIImage] {
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var images: [UIImage] = []
        var time = 0.0
        while time < duration {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                images.append(UIImage(cgImage: cgImage))
            }
            time += interval
        }
        return images
    }
}
#endif
