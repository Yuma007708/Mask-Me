import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// サンプルフォルダの全動画/画像をシミュレータで検出パイプラインに通し、
/// (A) 体を顔として拾う誤検知が支配的でないこと、
/// (B) 実機で報告された「再生開始でモザイクが消える／探索中0%」バグが再発していないこと、
/// を自動チェックする。
///
/// `SAMPLE_DIR`（デフォルト `/Users/tatsuki/Downloads/サンプル`）内の
/// `.mov` / `.mp4` / `.m4v` を自動的に列挙して回す。ファイルを追加すれば即カバー範囲に入る。
final class SampleFalsePositiveTests: XCTestCase {
    private var sampleDir: String {
        ProcessInfo.processInfo.environment["SAMPLE_DIR"] ?? "/Users/tatsuki/Downloads/サンプル"
    }

    private var videoURLs: [URL] { videos(in: sampleDir) }

    /// **顔が写っていないと分かっている素材**を置くサブフォルダ（`<SAMPLE_DIR>/nonfaces`）。
    /// ここに入れた動画は「1 フレームでも顔を検出したら誤検出」という強い条件で検証できる
    /// （`test_NonFaceVideos_detectNothing`）。素材の内容が既知でないと検出率そのものを
    /// assert できないので、任意素材を置く直下とは分けている。
    private var nonFaceVideoURLs: [URL] { videos(in: "\(sampleDir)/nonfaces") }

    private func videos(in dir: String) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let exts: Set<String> = ["mov", "mp4", "m4v"]
        return names
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { URL(fileURLWithPath: "\(dir)/\($0)") }
    }

    // MARK: - (A) 体誤検知の総覧テスト

    func test_AllSampleVideos_noBodyFalsePositive() async throws {
        let urls = videoURLs
        try XCTSkipIf(urls.isEmpty, "\(sampleDir) に検証対象の動画がありません")

        var failures: [String] = []
        for url in urls {
            do {
                try await verifyNoBodyFalsePositive(url: url, maxSeconds: 15)
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "体誤検知の疑いあり:\n" + failures.joined(separator: "\n"))
    }

    private func verifyNoBodyFalsePositive(url: URL, maxSeconds: Double) async throws {
        let stats = try await scan(url: url, maxSeconds: maxSeconds)
        XCTAssertLessThan(stats.tallRate, 0.20,
                          "\(url.lastPathComponent): 縦長bboxが多い（体を顔として拾っている疑い）")
        XCTAssertLessThan(stats.largeRate, 0.20,
                          "\(url.lastPathComponent): 面積40%超のbboxが多い（体全体を顔として拾っている疑い）")
    }

    /// 検出パイプラインに 15fps で通したときの集計。
    private struct ScanStats {
        var totalFrames = 0
        var framesWithDetection = 0
        var totalDetections = 0
        var tallCount = 0
        var largeCount = 0
        var multiCount = 0
        /// 「検出あり → 1 フレームだけ抜け → 検出あり」で挟まれた孤立した抜けの数。
        /// モザイクが一瞬外れて見える現象の直接指標（平均検出率では検出できない）。
        var isolatedGaps = 0

        var detectionRate: Double { Double(framesWithDetection) / Double(max(1, totalFrames)) }
        var tallRate: Double { Double(tallCount) / Double(max(1, totalDetections)) }
        var largeRate: Double { Double(largeCount) / Double(max(1, totalDetections)) }
    }

    /// 動画を検出パイプラインに通して集計する。
    /// - Parameter settings: 既定は実機と同一構成（FaceDetector + YuNet 両方 ON）。
    ///   補助検出器はシミュレータでも動くので、augment-bbox パス
    ///   「体bbox → cropLandmarker → 顔ハルシネーション」の誤検知経路もそのまま踏む。
    ///   バックエンドを振ると、どの検出器が誤検出を出しているかを切り分けられる。
    private func scan(url: URL, maxSeconds: Double,
                      settings: DetectionSettings = DetectionSettings(),
                      imageMode: Bool = false,
                      label: String = "SAMPLE-RESULT") async throws -> ScanStats {
        let scanner = makeFaceLandmarker(forVideo: !imageMode, settings: settings)

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.067, preferredTimescale: 600)

        let interval = 1.0 / 15.0
        let endTime = min(duration, maxSeconds)

        var stats = ScanStats()
        var detected: [Bool] = []

        var t = 0.0
        while t <= endTime {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600),
                    actualTime: nil
                ) else { return }
                stats.totalFrames += 1
                // 実機ライブ検出と同じ幅（liveDetectionTargetWidth）に縮小してから検出する。
                // フル解像度で検出するとテストは実機と別条件を測ることになり、
                // 「シミュレータで緑・実機で誤検知」の乖離を再現できない。
                // `MosaicPreviewController.detectionCGImage(from:)` と対応。
                let img = UIImage(cgImage: Self.downscaleForLiveDetection(cg))
                let faces = imageMode
                    ? scanner.allLandmarks(in: img)
                    : scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                if !faces.isEmpty { stats.framesWithDetection += 1 }
                detected.append(!faces.isEmpty)
                if faces.count > 1 { stats.multiCount += 1 }
                stats.totalDetections += faces.count
                for face in faces {
                    let bb = face.boundingBox
                    let area = Double(bb.width * bb.height)
                    // **ピクセル換算で縦長を判定する。** 正規化座標の h/w には素材の
                    // アスペクト比がそのまま混入するので（16:9 横長なら正方形の顔でも
                    // h/w≈1.78）、正規化比に 1.4 を当てると横長素材の正しい顔まで
                    // 「縦長＝体」と数えてしまう。製品コードの判定
                    // （`FaceLandmarkSet.passesAspectGate` / `isBodyLikeShape`）と
                    // 同じ換算・同じ閾値に合わせる。
                    let normalizedAspect = bb.height / max(bb.width, 0.001)
                    let pixelAspect = normalizedAspect * img.size.height / img.size.width
                    if pixelAspect > FaceLandmarkSet.Plausibility.maxPixelAspect {
                        stats.tallCount += 1
                    }
                    if area > 0.4 { stats.largeCount += 1 }
                }
            }
            t += interval
        }

        stats.isolatedGaps = detected.count < 3 ? 0 : (1..<(detected.count - 1)).filter {
            !detected[$0] && detected[$0 - 1] && detected[$0 + 1]
        }.count

        let summary = String(
            format: "[%@] file=%@ backend=%@ frames=%d hits=%d rate=%.2f "
                    + "detections=%d tall=%d(%.2f) large=%d(%.2f) multi=%d gaps=%d",
            label, url.lastPathComponent, "\(settings.faceDetectorBackend)",
            stats.totalFrames, stats.framesWithDetection, stats.detectionRate,
            stats.totalDetections, stats.tallCount, stats.tallRate,
            stats.largeCount, stats.largeRate, stats.multiCount, stats.isolatedGaps
        )
        fputs(summary + "\n", stderr)
        return stats
    }

    // MARK: - (A-2) 顔なし素材の誤検出テスト

    /// `<SAMPLE_DIR>/nonfaces` の素材は顔が写っていないと分かっているので、
    /// **検出そのものが起きたら誤検出**である。縦長率・面積率のような形の指標は
    /// 「どんな誤検出か」の手掛かりにすぎず、顔なし素材では検出率が唯一の正しい指標。
    ///
    /// **0 は要求しない。** MediaPipe 本体が胴体に conf 1.00 / 478 点フルメッシュを
    /// 貼るケースは幾何では実顔と区別できず、全候補 crop 再検証で 71% → 29% まで
    /// 落とすのが現状の上限（`MediaPipeFaceLandmarkerAdapter.verifyAndPruneTracks` の doc）。
    /// これ以上は「棄却の記憶」で下げられるが横顔の検出を落とすため採っていない。
    /// このテストは**これ以上悪化させない**ための上限ガードとして 40% を置く。
    func test_NonFaceVideos_falsePositiveRateIsBounded() async throws {
        let urls = nonFaceVideoURLs
        try XCTSkipIf(urls.isEmpty, "\(sampleDir)/nonfaces に顔なし動画がありません")

        var failures: [String] = []
        for url in urls {
            let stats = try await scan(url: url, maxSeconds: 15, label: "NONFACE-RESULT")
            if stats.detectionRate > 0.40 {
                failures.append(String(
                    format: "%@: 顔が無いのに %d/%d フレーム（%.0f%%）で検出 detections=%d",
                    url.lastPathComponent, stats.framesWithDetection, stats.totalFrames,
                    stats.detectionRate * 100, stats.totalDetections))
            }
        }
        XCTAssertTrue(failures.isEmpty, "顔なし素材への誤検出が上限超過:\n" + failures.joined(separator: "\n"))
    }

    /// 実機ライブ検出と同じ `MosaicEditorModel.liveDetectionTargetWidth` px 幅へ
    /// 縮小した CGImage を返す。
    /// `MosaicPreviewController.detectionCGImage(from:)` と同じスケール規則。
    private static let ciContext = CIContext()
    static func downscaleForLiveDetection(_ cg: CGImage) -> CGImage {
        let target = MosaicEditorModel.liveDetectionTargetWidth
        let scale = min(target / Double(cg.width), 1.0)
        guard scale < 0.99 else { return cg }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(ci, from: ci.extent) ?? cg
    }

    // MARK: - (B) 再生開始時のモザイク挙動テスト
    //
    // 2つの実機報告をカバーする:
    // 1.「顔サムネ100%だが探索中0%でモザイクが掛からない」→ 顔がシード時刻に写っている
    //    なら、その近傍でモザイク（selectedLandmarks 非空）が出ること。
    // 2.「体にモザイクが乗る／ずれる」→ 顔が写っていないと分かっている時刻（先頭に顔が
    //    無い動画の冒頭）に、未来の顔位置のモザイクを描かないこと。

    @MainActor
    func test_AllSampleVideos_previewContinuityAfterLoad() async throws {
        let urls = videoURLs
        try XCTSkipIf(urls.isEmpty, "\(sampleDir) に検証対象の動画がありません")

        var failures: [String] = []
        for url in urls {
            let asset = AVAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > 0 else { continue }

            let recents = RecentItemsStore()
            let model = MosaicEditorModel(mode: .video, recents: recents)
            model.load(videoURL: url)

            // load() は「実際に顔が写っていた時刻」のバケット1つにシードする。
            // 顔が全く写らない動画（またはリールの一部で probe 範囲外まで顔が出ない
            // 動画）はシードなし＝そもそも検出対象がない扱いとしてスキップする。
            // これはバグではなく、実機でも同じ結果になる正当な状態。
            guard let seedTime = model.cacheStore.allEntries.keys.map(\.bucket).min() else {
                fputs("\(url.lastPathComponent): 顔検出できる範囲内に顔なし（スキップ）\n", stderr)
                continue
            }
            fputs(String(format: "[PLAYBACK-SEED] file=%@ seedTime=%.3f detectedFaces=%d\n",
                         url.lastPathComponent, seedTime, model.detectedFaces.count), stderr)

            if model.detectedFaces.isEmpty {
                failures.append("\(url.lastPathComponent): detectedFaces が空（サムネが出ない）")
                continue
            }
            if !model.detectedFaces.contains(where: \.isSelected) {
                failures.append("\(url.lastPathComponent): auto-select されていない（faceMosaicOn=\(model.faceMosaicOn)）")
                continue
            }

            // (1) シード時刻の近傍（ホールドウィンドウ 0.75s 以内）ではモザイクが出る。
            //     実再生ではライブ検出が随時バケットを埋めるので、ここは
            //     「ライブ検出が追いつくまでの隙間をホールドが埋める」ことの検証。
            let nearProbes = [0.0, 0.033, 0.1, 0.25, 0.5, 0.7]
                .map { seedTime + $0 }
                .filter { $0 < duration }
            var missing: [Double] = []
            for t in nearProbes {
                let landmarks = model.selectedLandmarks(at: t)
                fputs(String(format: "[PLAYBACK-PROBE] file=%@ t=%.3f faces=%d\n",
                             url.lastPathComponent, t, landmarks.count), stderr)
                if landmarks.isEmpty { missing.append(t) }
            }
            if !missing.isEmpty {
                let ts = missing.map { String(format: "%.3f", $0) }.joined(separator: ",")
                failures.append("\(url.lastPathComponent): シード近傍でモザイク欠落 t=[\(ts)]")
            }

            // (2) 先頭に顔が無い動画（seedTime > ホールドウィンドウ）では、
            //     冒頭に未来の顔のモザイクを描いてはいけない（体モザイク回帰ガード）。
            if seedTime > 0.75 {
                let early = model.selectedLandmarks(at: 0.001)
                fputs(String(format: "[PLAYBACK-EARLY] file=%@ t=0.001 faces=%d (expect 0)\n",
                             url.lastPathComponent, early.count), stderr)
                if !early.isEmpty {
                    failures.append("\(url.lastPathComponent): 顔が無い冒頭フレームに未来の顔モザイクを描いている")
                }
            }

            // (3)「スキャン済みで顔なし」のフレームにはホールドしない。
            //     シード直後のバケットに空エントリを記録した状態を再現して確認する。
            let emptyBucket = ((seedTime + 1.0 / 15.0) * 15.0).rounded() / 15.0
            model.recordScannedEmptyForTesting(at: emptyBucket)
            let held = model.selectedLandmarks(at: emptyBucket)
            fputs(String(format: "[PLAYBACK-EMPTYHOLD] file=%@ t=%.3f faces=%d (expect 0)\n",
                         url.lastPathComponent, emptyBucket, held.count), stderr)
            if !held.isEmpty {
                failures.append("\(url.lastPathComponent): 顔なしと判明したフレームに古い顔をホールドしている")
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "再生連続性テスト失敗:\n" + failures.joined(separator: "\n"))
    }
}

#endif
