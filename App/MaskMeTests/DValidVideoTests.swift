import XCTest
import AVFoundation
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// 5 本サンプル動画 × 3 backend の検出精度を XCTest として走らせる。
/// 動画は環境変数 `SAMPLE_VIDEO_DIR` が指すディレクトリから `s1.mov`〜`s5.mov` として読む。
/// 環境変数が未設定 or ファイルが見つからない場合は `XCTSkip`（ローカル開発時は走らない）。
///
/// 想定運用は GitHub Actions の workflow で動画を Drive から落としてくる構成
/// （`.github/workflows/dvalid.yml`）。`-only-testing:MaskMeTests/DValidVideoTests/test_S1_off`
/// のように matrix で並列ジョブを切り、各ジョブが 1 テストメソッドを走らせる。
///
/// 前回 baseline（MP 単独 = `.off`）:
///   S1=16% / S2=58% / S3=3%(全誤検出) / S4=10% / S5=49%
final class DValidVideoTests: XCTestCase {
    private var videoDir: String { ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"] ?? "" }

    // MARK: - .off (MP 単独)
    // baseline は前回ローカル DValid の値。s3 は CI Drive 新動画（初回 13.2%）。
    func test_S1_off()      async throws { try await run("s1", .off,          baseline: 0.16) }
    func test_S2_off()      async throws { try await run("s2", .off,          baseline: 0.58) }
    func test_S3_off()      async throws { try await run("s3", .off,          baseline: 0.13) }
    func test_S4_off()      async throws { try await run("s4", .off,          baseline: 0.10) }
    func test_S5_off()      async throws { try await run("s5", .off,          baseline: 0.49) }

    // MARK: - .faceDetector (MediaPipe Face Detector / BlazeFace)
    func test_S1_faceDet()  async throws { try await run("s1", .faceDetector, baseline: 0.16) }
    func test_S2_faceDet()  async throws { try await run("s2", .faceDetector, baseline: 0.58) }
    func test_S3_faceDet()  async throws { try await run("s3", .faceDetector, baseline: 0.13) }
    func test_S4_faceDet()  async throws { try await run("s4", .faceDetector, baseline: 0.10) }
    func test_S5_faceDet()  async throws { try await run("s5", .faceDetector, baseline: 0.49) }

    // MARK: - .yunet (Core ML)
    func test_S1_yunet()    async throws { try await run("s1", .yunet,        baseline: 0.16) }
    func test_S2_yunet()    async throws { try await run("s2", .yunet,        baseline: 0.58) }
    func test_S3_yunet()    async throws { try await run("s3", .yunet,        baseline: 0.13) }
    func test_S4_yunet()    async throws { try await run("s4", .yunet,        baseline: 0.10) }
    func test_S5_yunet()    async throws { try await run("s5", .yunet,        baseline: 0.49) }

    // MARK: - Implementation

    private func run(_ name: String, _ backend: FaceDetectorBackend, baseline: Double) async throws {
        try XCTSkipIf(videoDir.isEmpty, "SAMPLE_VIDEO_DIR 未設定（ローカルでは XCTSkip）")
        let url = URL(fileURLWithPath: "\(videoDir)/\(name).mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path),
                      "\(url.path) が存在しません")

        var settings = DetectionSettings()
        settings.faceDetectorBackend = backend
        let scanner = makeFaceLandmarker(forVideo: true, settings: settings)

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.067, preferredTimescale: 600)

        var total = 0, hit = 0, lowCy = 0
        // 連続検出フレーム間の centroid 距離を蓄積して、ちらつき/追従の代理指標とする。
        // - avgJump: 連続する検出フレーム間の平均移動量（顔がゆっくり動く前提で、大きいほど不安定）
        // - jumpBig: 0.05 (画面 5%) を超えるジャンプ数 = ちらつき/位置ズレ疑い件数
        var lastCentroid: CGPoint? = nil
        var sumJump: Double = 0
        var pairCount = 0
        var jumpBig = 0
        let bigJumpThreshold: Double = 0.05
        let interval = 1.0 / 15.0   // MosaicEditorModel と同じ刻み
        var t = 0.0
        while t <= duration {
            autoreleasepool {
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    total += 1
                    let img = UIImage(cgImage: cg)
                    let faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                    if let first = faces.first {
                        hit += 1
                        let c = centroid(of: first)
                        if c.y > 0.5 { lowCy += 1 }
                        if let prev = lastCentroid {
                            let dx = Double(c.x - prev.x)
                            let dy = Double(c.y - prev.y)
                            let d = (dx * dx + dy * dy).squareRoot()
                            sumJump += d
                            pairCount += 1
                            if d > bigJumpThreshold { jumpBig += 1 }
                        }
                        lastCentroid = c
                    } else {
                        // 検出途切れは pair を切る（次のヒットとの距離を測らない）
                        lastCentroid = nil
                    }
                }
            }
            t += interval
        }

        let rate = total == 0 ? 0.0 : Double(hit) / Double(total)
        let lowRate = total == 0 ? 0.0 : Double(lowCy) / Double(total)
        let avgJump = pairCount == 0 ? 0.0 : sumJump / Double(pairCount)
        let jumpBigRate = pairCount == 0 ? 0.0 : Double(jumpBig) / Double(pairCount)
        // Xcode 26 では print() がシミュレータプロセスの stdout に閉じ込められ
        // xcodebuild の pipe に出てこない。stderr は 2>&1 で捕捉されるので fputs を使う。
        let resultLine = "[DVALRESULT] {\"video\":\"\(name)\",\"backend\":\"\(backend.rawValue)\",\"total\":\(total),\"hit\":\(hit),\"lowCy\":\(lowCy),\"rate\":\(rate),\"lowRate\":\(lowRate),\"baseline\":\(baseline),\"avgJump\":\(avgJump),\"jumpBig\":\(jumpBig),\"jumpBigRate\":\(jumpBigRate),\"pairCount\":\(pairCount)}"
        fputs(resultLine + "\n", stderr)
    }

    private func centroid(of face: FaceLandmarkSet) -> CGPoint {
        guard !face.points.isEmpty else { return .zero }
        let n = Float(face.points.count)
        var sx: Float = 0, sy: Float = 0
        for p in face.points { sx += p.x; sy += p.y }
        return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
    }
}

#endif
