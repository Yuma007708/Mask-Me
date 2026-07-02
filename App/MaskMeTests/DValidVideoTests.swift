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
/// （`.github/workflows/dvalid.yml`）。`-only-testing:MaskMeTests/DValidVideoTests/test_S1_off_A`
/// のように matrix で並列ジョブを切り、各ジョブが 1 テストメソッド（1 半分の動画）を走らせる。
///
/// 前回 baseline（MP 単独 = `.off`、動画全体での検出率）:
///   S1=16% / S2=58% / S3=3%(全誤検出) / S4=10% / S5=49%
///
/// 92 秒超の長尺動画 + 補助検出器 (.off/.yunet) の組み合わせで、1 プロセスが長時間
/// 連続で detect し続けるとテストプロセスがフレームループ終盤で異常終了する
/// 構造的 flaky（0 tests executed）が確認されている。前半/後半に分けて別プロセスで
/// 走らせることで 1 プロセスあたりの累積処理量・実行時間を半分にし、発生条件に
/// 到達しにくくする。
final class DValidVideoTests: XCTestCase {
    private var videoDir: String { ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"] ?? "" }

    private enum Half: String { case first = "A", second = "B" }

    // MARK: - .off (MP 単独)
    // baseline は前回ローカル DValid の値（動画全体）。s3 は CI Drive 新動画（初回 13.2%）。
    func test_S1_off_A()     async throws { try await run("s1", .off,          baseline: 0.16, half: .first) }
    func test_S1_off_B()     async throws { try await run("s1", .off,          baseline: 0.16, half: .second) }
    func test_S2_off_A()     async throws { try await run("s2", .off,          baseline: 0.58, half: .first) }
    func test_S2_off_B()     async throws { try await run("s2", .off,          baseline: 0.58, half: .second) }
    func test_S3_off_A()     async throws { try await run("s3", .off,          baseline: 0.13, half: .first) }
    func test_S3_off_B()     async throws { try await run("s3", .off,          baseline: 0.13, half: .second) }
    func test_S4_off_A()     async throws { try await run("s4", .off,          baseline: 0.10, half: .first) }
    func test_S4_off_B()     async throws { try await run("s4", .off,          baseline: 0.10, half: .second) }
    func test_S5_off_A()     async throws { try await run("s5", .off,          baseline: 0.49, half: .first) }
    func test_S5_off_B()     async throws { try await run("s5", .off,          baseline: 0.49, half: .second) }

    // MARK: - .faceDetector (MediaPipe Face Detector / BlazeFace)
    func test_S1_faceDet_A() async throws { try await run("s1", .faceDetector, baseline: 0.16, half: .first) }
    func test_S1_faceDet_B() async throws { try await run("s1", .faceDetector, baseline: 0.16, half: .second) }
    func test_S2_faceDet_A() async throws { try await run("s2", .faceDetector, baseline: 0.58, half: .first) }
    func test_S2_faceDet_B() async throws { try await run("s2", .faceDetector, baseline: 0.58, half: .second) }
    func test_S3_faceDet_A() async throws { try await run("s3", .faceDetector, baseline: 0.13, half: .first) }
    func test_S3_faceDet_B() async throws { try await run("s3", .faceDetector, baseline: 0.13, half: .second) }
    func test_S4_faceDet_A() async throws { try await run("s4", .faceDetector, baseline: 0.10, half: .first) }
    func test_S4_faceDet_B() async throws { try await run("s4", .faceDetector, baseline: 0.10, half: .second) }
    func test_S5_faceDet_A() async throws { try await run("s5", .faceDetector, baseline: 0.49, half: .first) }
    func test_S5_faceDet_B() async throws { try await run("s5", .faceDetector, baseline: 0.49, half: .second) }

    // MARK: - .yunet (Core ML)
    func test_S1_yunet_A()   async throws { try await run("s1", .yunet,        baseline: 0.16, half: .first) }
    func test_S1_yunet_B()   async throws { try await run("s1", .yunet,        baseline: 0.16, half: .second) }
    func test_S2_yunet_A()   async throws { try await run("s2", .yunet,        baseline: 0.58, half: .first) }
    func test_S2_yunet_B()   async throws { try await run("s2", .yunet,        baseline: 0.58, half: .second) }
    func test_S3_yunet_A()   async throws { try await run("s3", .yunet,        baseline: 0.13, half: .first) }
    func test_S3_yunet_B()   async throws { try await run("s3", .yunet,        baseline: 0.13, half: .second) }
    func test_S4_yunet_A()   async throws { try await run("s4", .yunet,        baseline: 0.10, half: .first) }
    func test_S4_yunet_B()   async throws { try await run("s4", .yunet,        baseline: 0.10, half: .second) }
    func test_S5_yunet_A()   async throws { try await run("s5", .yunet,        baseline: 0.49, half: .first) }
    func test_S5_yunet_B()   async throws { try await run("s5", .yunet,        baseline: 0.49, half: .second) }

    // MARK: - Implementation

    private func run(_ name: String, _ backend: FaceDetectorBackend, baseline: Double, half: Half) async throws {
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
        // 追従率（アプリ体験の代理指標）計測用: 検出成功フレームのキャッシュと
        // サンプル時刻列を蓄積し、ループ後に DetectionBridge（アプリの補間と同一実装）
        // で「補間で救済されるフレームも含めた率 = bridgedRate」を求める。
        var detectionCache: [Double: [FaceLandmarkSet]] = [:]
        var sampleTimes: [Double] = []
        let interval = 1.0 / 15.0   // MosaicEditorModel と同じ刻み
        // 動画を前半/後半に分け、それぞれ別プロセス（別 XCTest メソッド）で走らせることで
        // 1 プロセスあたりの連続 detect 呼び出し数と実行時間を半分にする。
        let midpoint = duration / 2
        let (tStart, tEnd) = half == .first ? (0.0, midpoint) : (midpoint, duration)
        var t = tStart
        while t <= tEnd {
            autoreleasepool {
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    total += 1
                    sampleTimes.append(t)
                    let img = UIImage(cgImage: cg)
                    let faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                    let src = (scanner as? MediaPipeFaceLandmarkerAdapter)?.lastSource.rawValue ?? ""
                    if let first = faces.first {
                        hit += 1
                        detectionCache[t] = faces
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
                        // フレームタイムライン: 追従層（bridgeWindow/lerp/EMA）のパラメータ探索を
                        // CI 再実行なしのオフライン計算にするための1行/フレーム出力。
                        let bb = first.boundingBox
                        let frameLine = String(
                            format: "[DVALFRAME] {\"t\":%.3f,\"hit\":1,\"cx\":%.4f,\"cy\":%.4f," +
                                    "\"bx\":%.4f,\"by\":%.4f,\"bw\":%.4f,\"bh\":%.4f,\"src\":\"%@\"}",
                            t, c.x, c.y, bb.origin.x, bb.origin.y, bb.width, bb.height, src
                        )
                        fputs(frameLine + "\n", stderr)
                    } else {
                        // 検出途切れは pair を切る（次のヒットとの距離を測らない）
                        lastCentroid = nil
                        fputs(String(format: "[DVALFRAME] {\"t\":%.3f,\"hit\":0}", t) + "\n", stderr)
                    }
                }
            }
            t += interval
        }

        // アプリの両側補間（DetectionBridge）で救済されるフレームも含めた追従率。
        // bridgedRate は現行アプリ挙動（window=5/15）、bridgedRate10 は window 拡大
        // (10/15) の事前評価（検出コストゼロで効果を見積もる）。
        let bridge5 = DetectionBridge()
        let bridge10 = DetectionBridge(bridgeWindow: 10.0 / 15.0)
        var bridgedHit = 0
        var bridgedHit10 = 0
        for st in sampleTimes {
            if !bridge5.faces(in: detectionCache, at: st).isEmpty { bridgedHit += 1 }
            if !bridge10.faces(in: detectionCache, at: st).isEmpty { bridgedHit10 += 1 }
        }

        let stats = (scanner as? MediaPipeFaceLandmarkerAdapter)?.sourceStats
                    ?? FaceDetectionSourceStats()

        let rate = total == 0 ? 0.0 : Double(hit) / Double(total)
        let lowRate = total == 0 ? 0.0 : Double(lowCy) / Double(total)
        let avgJump = pairCount == 0 ? 0.0 : sumJump / Double(pairCount)
        let jumpBigRate = pairCount == 0 ? 0.0 : Double(jumpBig) / Double(pairCount)
        let bridgedRate = total == 0 ? 0.0 : Double(bridgedHit) / Double(total)
        let bridgedRate10 = total == 0 ? 0.0 : Double(bridgedHit10) / Double(total)
        // Xcode 26 では print() がシミュレータプロセスの stdout に閉じ込められ
        // xcodebuild の pipe に出てこない。stderr は 2>&1 で捕捉されるので fputs を使う。
        let resultLine = "[DVALRESULT] {\"video\":\"\(name)\",\"backend\":\"\(backend.rawValue)\",\"half\":\"\(half.rawValue)\",\"total\":\(total),\"hit\":\(hit),\"lowCy\":\(lowCy),\"rate\":\(rate),\"lowRate\":\(lowRate),\"baseline\":\(baseline),\"avgJump\":\(avgJump),\"jumpBig\":\(jumpBig),\"jumpBigRate\":\(jumpBigRate),\"pairCount\":\(pairCount),\"bridgedHit\":\(bridgedHit),\"bridgedRate\":\(bridgedRate),\"bridgedHit10\":\(bridgedHit10),\"bridgedRate10\":\(bridgedRate10),\"srcMp\":\(stats.mpFrames),\"srcEnh\":\(stats.enhanceFrames),\"srcBbox\":\(stats.bboxFrames),\"srcRoi\":\(stats.roiFrames),\"srcLow\":\(stats.lowConfFrames)}"
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
