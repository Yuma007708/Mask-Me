import XCTest
import AVFoundation
import CoreImage
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// 実動画 × フルモデル経路（選択層込み）の被覆率計測。
///
/// DValidLivePathTests は検出器〜lookupFaces までしか測らず、実機の描画が通る
/// 選択層（detectedFaces / isSelected / selectedLandmarks の重心マッチング）を
/// バイパスしていた。実機報告「フレームアウト→イン後に一切モザイクが掛からない」
/// はこの未検証層で起きたため、本テストは実機と同じ
/// storeLiveDetection → selectedLandmarks の経路で「ユーザーが目にするモザイク」
/// の被覆率を実動画で測る。
///
/// 出力: `[DVALMODEL] {json}` を 1 動画 1 行。
///   - modelCoverage: selectedLandmarks(at:) が非空を返したフレーム割合
///     （lookup 段の previewCoverage と比べ、選択層での取りこぼしを検出する）
final class DValidLiveModelTests: XCTestCase {
    private static let bucketFPS = 15.0
    private let ciContext = CIContext()

    private var sampleDir: String? {
        ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"]
    }

    /// 被覆率ゲート。新セット導入時はまず現状ベースラインで回帰防止し、
    /// 改修後に 0.90 へ引き上げる運用のため env で可変にしている。
    private var gate: Double {
        ProcessInfo.processInfo.environment["DVAL_GATE"].flatMap(Double.init) ?? 0.90
    }

    /// `load(videoURL:)` の**非同期**部（初期スキャン → タイムライン →
    /// composition → previewController → 初期フレーム）の完了待ち。
    /// `isLoading` はその Task の末尾で必ず下りる（成功・失敗どちらの経路でも）。
    @MainActor
    private func waitUntilLoaded(_ model: MosaicEditorModel,
                                 timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoading {
            if Date() > deadline {
                XCTFail("動画の読み込みが \(timeout)s 以内に完了しない")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func test_LiveModelPath_AllSamples() async throws {
        guard let dir = sampleDir else {
            throw XCTSkip("SAMPLE_VIDEO_DIR 未設定")
        }
        for name in ["s1", "s2", "s3", "s4", "s5"] {
            let url = URL(fileURLWithPath: "\(dir)/\(name).mov")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let coverage = try await measureModelPath(name: name, url: url)
            XCTAssertGreaterThanOrEqual(
                coverage, gate,
                "\(name): 選択層込みのモザイク被覆率が基準未満")
        }
    }

    /// **難素材のモザイク被覆率**（暗所・逆光・遮蔽・動きブレ・群衆）。
    ///
    /// `test_LiveModelPath_AllSamples` は手元の `s1`〜`s5` が要り、素材が無い環境では
    /// まるごと skip される。難素材は `MaskMeTests/Fixtures/probe/` に同梱してあるので、
    /// こちらは **pod install 済みなら必ず走る**。
    ///
    /// `DiagFaceCoverageTests`（検出率）とは測るものが違う。あちらは「そのフレームで
    /// 顔を検出できたか」、こちらは **検出できなかったフレームを前後から埋めた後**の
    /// 「ユーザーが実際に目にするモザイクが乗っているか」。プライバシーアプリで
    /// 本当に守るべきはこちらで、**検出率が上がってもモザイクが切れている**という
    /// 事故はこの計測でしか気づけない。
    ///
    /// 逆光（`probe_hard_backlight`）の検出率は 0% だが、それは「顔がシルエットしか
    /// 写っていない」ためで、被覆率まで 0 なら実害がある。数字を分けて持つ理由がここにある。
    @MainActor
    func test_LiveModelPath_HardFixtures() async throws {
        var measured = false
        for (name, floor) in Self.hardFixtureCoverageFloor.sorted(by: { $0.key < $1.key }) {
            guard let url = Bundle(for: Self.self)
                .url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/probe")
            else { continue }
            measured = true
            let coverage = try await measureModelPath(name: name, url: url)
            XCTAssertGreaterThanOrEqual(
                coverage, floor,
                "\(name): モザイク被覆率が \(floor) → \(String(format: "%.3f", coverage)) に下がっている。"
                + "検出が落ちたか、穴埋め（bridge / フロー / ホールド）が効かなくなっている")
        }
        try XCTSkipIf(!measured, "Fixtures/probe が同梱されていない")
    }

    /// 難素材ごとの被覆率の下限。**この数字を下げる変更はモザイクの退行**であり、
    /// 検出率がいくら上がっても採ってはいけない（顔が露わになるフレームが増えるため）。
    ///
    /// 2026-07-31 の実測（iPhone 17 Pro Simulator）に、素材ごとのブレぶんの余裕を見た値:
    /// backlight 0.00 / dark 1.00 / motion 1.00 / occluded 1.00 / beach 1.00 / crowd 0.96。
    ///
    /// `probe_hard_backlight` が 0 なのは**現状がそうだから**で、目標ではない。
    /// 0.72 秒・11 フレームしかない極端な素材だが、逆光でモザイクが一切乗らないのは
    /// プライバシー上の実害なので、**改善したら下限を引き上げること**。
    /// 更新するときは理由と計測日を添える。
    private static let hardFixtureCoverageFloor: [String: Double] = [
        "probe_hard_backlight": 0.00,
        "probe_hard_dark": 0.95,
        "probe_hard_motion": 0.95,
        "probe_hard_occluded": 0.95,
        "probe_beach_01": 0.95,
        "probe_crowd_01": 0.93
    ]

    /// 実機報告「プレビューを途中から始めるとモザイクが掛からない」の再現計測。
    /// 実機と同じ流れを踏む: load(videoURL:) で冒頭シード（初期スキャン + 自動選択）
    /// → 中盤へシーク（notifyLiveSeek で追跡リセット）→ 中盤以降だけをライブ検出
    /// → 中盤以降の selectedLandmarks 被覆率を測る。先頭からのスキャン履歴は無し。
    @MainActor
    func test_LiveModelPath_StartingMidVideo() async throws {
        guard let dir = sampleDir else {
            throw XCTSkip("SAMPLE_VIDEO_DIR 未設定")
        }
        let url = URL(fileURLWithPath: "\(dir)/s1.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("s1.mov なし")
        }
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)

        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        // 実機と同じ初期状態: 冒頭の初期スキャンで detectedFaces をシード（自動選択）
        model.load(videoURL: url)
        // **初期スキャンは非同期**（`load(videoURL:)` の Task。同期部は
        // `detectedFaces = []` までしかやらない）。待たずに assert すると常に空を見る。
        try await waitUntilLoaded(model)
        XCTAssertFalse(model.detectedFaces.isEmpty, "初期スキャンで顔がシードされるはず")
        XCTAssertTrue(model.detectedFaces.contains(where: \.isSelected), "単一顔は自動選択されるはず")

        // 中盤へシーク → そこから再生（先頭からのライブ検出履歴なし）
        let start = duration / 2
        model.notifyLiveSeek()
        scanner.resetLiveTracking()

        var frames = 0
        var hits = 0
        let interval = 1.0 / Self.bucketFPS
        var t = start
        while t <= duration {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else { return }
                let img = UIImage(cgImage: downscaleForLiveDetection(cg))
                let detection = scanner.liveLandmarks(in: img, atMediaSeconds: t)
                model.storeLiveDetection(detection, at: model.liveBucket(t), source: img)
                frames += 1
                if !model.selectedLandmarks(at: t).isEmpty { hits += 1 }
            }
            t += interval
        }
        let coverage = frames > 0 ? Double(hits) / Double(frames) : 0
        fputs("""
        [DVALMODEL] {"video":"s1-midstart","frames":\(frames),\
        "modelCoverage":\(String(format: "%.4f", coverage))}
        """ + "\n", stderr)
        XCTAssertGreaterThanOrEqual(coverage, gate,
                                    "途中スタートで選択層込みのモザイク被覆率が基準未満")
    }

    /// 実機報告「途中スタートでモザイクなし」の統合再現: モデル層ではなく
    /// **本物の MosaicPreviewController + AVPlayer** を実時間で駆動する。
    /// 中盤へシーク → 再生 3 秒 → シーク先以降のバケットにライブ検出が乗り、
    /// selectedLandmarks が引けることを確認する。
    @MainActor
    func test_PreviewController_MidStartPlayback_AppliesMosaic() async throws {
        guard let dir = sampleDir else { throw XCTSkip("SAMPLE_VIDEO_DIR 未設定") }
        let url = URL(fileURLWithPath: "\(dir)/s1.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("s1.mov なし") }

        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.load(videoURL: url)
        // previewController も composition も `load(videoURL:)` の Task の中で作られる。
        // 直後に読むと必ず nil で、原因が「Metal が無い」ことと見分けられない。
        try await waitUntilLoaded(model)
        // 待った上でまだ無いなら Metal renderer が用意できない環境（Simulator）。
        // 製品の退行ではないので skip する（XCTUnwrap の失敗として残すと、
        // 実機で見るべき欠陥が Simulator の常時赤に埋もれる）。
        guard let controller = model.previewController else {
            throw XCTSkip("previewController を作れない環境（Metal renderer が必要）")
        }
        // duration の非同期ロード完了を待つ（seek(to:) のガードに必要）
        var waited = 0.0
        while controller.duration <= 0, waited < 5.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        XCTAssertGreaterThan(controller.duration, 0)
        let duration = controller.duration

        // 途中スタート: 実機のタイムライン・ドラッグを再現（seekToLatest の連打で
        // 0→50% までスクラブ。ドラッグ中の連続発火 + 直前シークのキャンセルを通す）
        for i in 1...25 {
            model.seekToLatest(position: 0.5 * Double(i) / 25.0)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        model.togglePlayback()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        model.togglePlayback()

        // シーク先以降のバケットにライブ検出が乗っているか（実検出+flow の合算）
        let midStart = duration * 0.5 - 0.1
        let scannedMid = model.cacheStore.allEntries.keys.filter { $0.bucket >= midStart }.count
        let facesMid = model.cacheStore.allEntries
            .filter { $0.key.bucket >= midStart && !$0.value.isEmpty }.count
        fputs("[MIDSTART] duration=\(duration) scannedMid=\(scannedMid) facesMid=\(facesMid) " +
              "pos=\(model.playbackPosition) detected=\(model.detectedFaces.count) " +
              "selected=\(model.detectedFaces.filter(\.isSelected).count)\n", stderr)
        XCTAssertGreaterThan(scannedMid, 0, "途中スタート後にライブ検出が1件も走っていない")
        XCTAssertGreaterThan(facesMid, 0, "途中スタート後の検出が全て空（顔を拾えていない）")

        // ユーザーが目にする層（選択層 = detectedFaces / isSelected / 重心マッチング）が
        // 通っていること。**検出が乗ったバケットすべてで**引けることを見る。
        //
        // かつては `playbackPosition` の一点だけを見ていたが、それはこのテストが
        // 再現したい欠陥（途中スタートで**一切**モザイクが掛からない）より狭くも広くもある:
        // 検出は再生に対して非同期・間引きされるので最新バケットは常に再生位置より後ろにあり、
        // ホスト負荷で検出スループットが落ちるとバケット間隔がホールド窓 0.75s を超え、
        // 製品が正常でも落ちる（実測: アイドルで scannedMid=12 通過、load 542 で 5・
        // load 100+ で 4 で失敗）。**負荷で結果が変わる assert は信号にならない。**
        //
        // 「検出が乗った時刻では必ず引ける」は、その時刻については一点チェックより厳しく、
        // かつ何バケット埋まったかに依存しない。元の欠陥（被覆率 0）は上の 2 つと
        // このループで捕まる。単一クリップ・rate=1 なので素材時刻＝合成時刻
        // （`scannedMid` の算出が既にそれを前提にしている）。
        let detectedBuckets = model.cacheStore.allEntries
            .filter { $0.key.bucket >= midStart && !$0.value.isEmpty }
            .map(\.key.bucket)
            .sorted()
        let drawable = detectedBuckets.filter { !model.selectedLandmarks(at: $0).isEmpty }
        fputs("[MIDSTART] detectedBuckets=\(detectedBuckets.count) drawable=\(drawable.count) " +
              "atPlaybackPosition=\(!model.selectedLandmarks(at: model.playbackPosition * duration).isEmpty)\n",
              stderr)
        XCTAssertEqual(drawable.count, detectedBuckets.count,
                       "顔を検出したバケットなのに選択層を通すとモザイクが引けない"
                       + "（検出は乗っているのに描画されない = 選択層の取りこぼし）")
    }

    /// 実機のライブ再生と同じ流れ: 各バケットのフレームを 640px に縮小 → IMAGE モード
    /// 検出 → storeLiveDetection（選択層シード・追跡込み）→ 全バケットで
    /// selectedLandmarks を引いて被覆率を出す。
    @MainActor
    private func measureModelPath(name: String, url: URL) async throws -> Double {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / Self.bucketFPS, preferredTimescale: 600)

        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())

        var frames = 0
        var flowFrames = 0
        let interval = 1.0 / Self.bucketFPS
        var t = 0.0
        while t <= duration {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else { return }
                let img = UIImage(cgImage: downscaleForLiveDetection(cg))
                // 実機と同じライブ経路: IMAGE 検出 + テンポラル ROI 再検出 + フロー橋渡し
                let detection = scanner.liveLandmarks(in: img, atMediaSeconds: t)
                if detection.bridgedByFlow { flowFrames += 1 }
                model.storeLiveDetection(detection, at: model.liveBucket(t), source: img)
                // 複数顔動画は自動選択されない（ユーザーがサムネで選ぶ仕様）ため、
                // 「全員選択した」ユーザー操作を再現する。単一顔は自動選択のまま。
                if !model.detectedFaces.isEmpty,
                   !model.detectedFaces.contains(where: \.isSelected) {
                    for face in model.detectedFaces { model.toggleFace(face.id) }
                }
                frames += 1
            }
            t += interval
        }

        // 分母は**引いた時刻の数**で数える。デコードできたフレーム数（`frames`）を分母に
        // 使うと、末尾の端数ぶんだけ引く回数が 1 多くなり被覆率が 1.0 を超える
        // （実測で 1.0222 が出ていた）。ゲートの意味が壊れるので分子と同じループで数える。
        var hits = 0
        var sampled = 0
        for time in stride(from: 0.0, through: duration, by: interval) {
            sampled += 1
            if !model.selectedLandmarks(at: time).isEmpty { hits += 1 }
        }
        let coverage = sampled > 0 ? Double(hits) / Double(sampled) : 0
        let selectedCount = model.detectedFaces.filter(\.isSelected).count
        // どのレバー（ROI 再検出 / フロー橋渡し）が何フレーム救ったかの帰属。
        let stats = (scanner as? MediaPipeFaceLandmarkerAdapter)?.sourceStats
        let json = """
        [DVALMODEL] {"video":"\(name)","frames":\(frames),\
        "modelCoverage":\(String(format: "%.4f", coverage)),\
        "faces":\(model.detectedFaces.count),"selected":\(selectedCount),\
        "roiFrames":\(stats?.roiFrames ?? 0),"flowFrames":\(flowFrames)}
        """
        fputs(json + "\n", stderr)
        return coverage
    }

    private func downscaleForLiveDetection(_ cg: CGImage) -> CGImage {
        let targetWidth = MosaicEditorModel.liveDetectionTargetWidth
        let scale = min(targetWidth / Double(cg.width), 1.0)
        guard scale < 1.0 else { return cg }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(ci, from: ci.extent) ?? cg
    }
}

#endif
