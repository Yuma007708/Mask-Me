import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// `MediaPipeFaceLandmarkerAdapter` の「検出全滅フレームをオプティカルフローで
/// ブリッジする」状態機械（src=flow・連続上限30・実検出復帰で再seed）を検証する。
///
/// seed 用の実顔フレームは `DValidVideoTests` と同じ方式でサンプル動画から取得する:
/// 環境変数 `SAMPLE_VIDEO_DIR` の指すディレクトリの `s2.mov`（検出率が最も安定）の
/// 中盤付近から `AVAssetImageGenerator` で1フレーム切り出す。環境変数未設定 or
/// 動画不在の場合のみ `XCTSkip`（`DValidVideoTests` と同条件）。
///
/// MediaPipe の実検出を決定論的に全滅させるため、Adapter の DEBUG 専用テストシーム
/// `simulateDetectionFailureForTesting` を使う（true の間は検出パイプライン全段を
/// スキップし、そのフレームを「検出全滅」として扱う）。平行移動フレームは取得した
/// seed フレームから CoreGraphics で生成する（余白は黒。移動後も顔領域自体は
/// 写っているので疎 LK は追跡できる）。
final class FlowBridgeTests: XCTestCase {

    private var videoDir: String { ProcessInfo.processInfo.environment["SAMPLE_VIDEO_DIR"] ?? "" }

    /// MediaPipe モデルはテストホスト (MaskMe.app) のバンドルから解決する
    /// （`makeFaceLandmarker` と同じ経路。FixtureLoader は使わない）。
    private func makeAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            throw XCTSkip("face_landmarker.task がアプリバンドルにありません")
        }
        // DValidVideoTests の .off backend と同じ MP 単独構成（決定論性優先）。
        var settings = DetectionSettings()
        settings.faceDetectorBackend = .off
        return try MediaPipeFaceLandmarkerAdapter(
            modelPath: modelPath, runningMode: .video, settings: settings
        )
    }

    /// s2.mov の中盤付近から「実検出が成功する」フレームを1枚探して返す。
    /// s2 は検出率 88.9% で最も安定しているため、中盤±数フレームの走査で必ず見つかる想定。
    /// 動画不在時のみ XCTSkip。見つからなければ XCTFail（環境ではなく検出の退行を疑う）。
    private func loadDetectableSeedFrame() async throws -> UIImage {
        try XCTSkipIf(videoDir.isEmpty, "SAMPLE_VIDEO_DIR 未設定（ローカルでは XCTSkip）")
        let url = URL(fileURLWithPath: "\(videoDir)/s2.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path),
                      "\(url.path) が存在しません")

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.067, preferredTimescale: 600)

        // 検出可否の判定は使い捨ての probe 用 adapter で行い、本編のテスト対象 adapter の
        // 内部状態（trackedFaces / flowStates / タイムスタンプ）を汚さない。
        let probe = try makeAdapter()
        let mid = duration / 2
        let candidates = stride(from: 0.0, through: 3.0, by: 0.5).map { mid + $0 }
        for (i, t) in candidates.enumerated() where t < duration {
            guard let cg = try? gen.copyCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
            ) else { continue }
            let img = UIImage(cgImage: cg)
            if !probe.allLandmarks(in: img, timestampMs: i * 100).isEmpty {
                return img
            }
        }
        XCTFail("s2.mov 中盤 \(mid)s 付近で実検出可能なフレームが見つかりませんでした")
        throw XCTSkip("seed フレーム取得失敗")
    }

    /// フロー橋渡し系テスト専用の seed フレーム探索。検出成功かつ
    /// `isFlowBridgeEligible`（面積≤0.08・midY≤0.5）な顔を含むフレームを
    /// s1..s5 の 1 秒刻みで探す。クローズアップ中心のセット（bright/backlight 等）は
    /// 顔 bbox が面積ゲートを超えフローが原理的に発火しないため、見つからなければ
    /// 失敗ではなく XCTSkip（セット依存の前提不成立）。フローの実効性そのものは
    /// DValidLiveModelTests の flowFrames 帰属が実動画で担保する。
    private func loadFlowEligibleSeedFrame() async throws -> UIImage {
        try XCTSkipIf(videoDir.isEmpty, "SAMPLE_VIDEO_DIR 未設定（ローカルでは XCTSkip）")
        let probe = try makeAdapter()
        var ts = 0
        for name in ["s1", "s2", "s3", "s4", "s5"] {
            let url = URL(fileURLWithPath: "\(videoDir)/\(name).mov")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds,
                  duration > 0 else { continue }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.067, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.067, preferredTimescale: 600)
            for t in stride(from: 1.0, to: duration, by: 1.0) {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else { continue }
                let img = UIImage(cgImage: cg)
                ts += 100
                let faces = probe.allLandmarks(in: img, timestampMs: ts)
                if faces.contains(where: { probe.isFlowBridgeEligible($0.boundingBox) }) {
                    return img
                }
            }
        }
        throw XCTSkip("flow 適格（面積≤0.08・midY≤0.5）の顔を含むフレームがこのセットに無い")
    }

    /// `image` を黒背景の同サイズキャンバスに (dx, dy) だけずらして描き直す。
    /// AVAssetImageGenerator 由来のフレームは scale=1 なのでポイント=ピクセル。
    /// 余白は黒でよい。移動後も顔領域自体はフレーム内に残るので LK は追跡できる。
    private func translated(_ image: UIImage, dx: CGFloat, dy: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: image.size))
            image.draw(at: CGPoint(x: dx, y: dy))
        }
    }

    /// UIImage のピクセル寸法（UIImage.size はポイント単位で scale 依存のため CGImage を使う）。
    private func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }

    /// seed フレームを実検出させ、trackedFaces / flowStates を seed する。
    @discardableResult
    private func seedWithRealDetection(
        _ adapter: MediaPipeFaceLandmarkerAdapter,
        image: UIImage,
        timestampMs: Int
    ) -> FaceLandmarkSet? {
        adapter.simulateDetectionFailureForTesting = false
        let result = adapter.allLandmarks(in: image, timestampMs: timestampMs)
        XCTAssertFalse(result.isEmpty, "seed フレームは実検出に成功するはず（probe 済み）")
        XCTAssertNotEqual(adapter.lastSource, .flow, "seed フレームは実検出ソースのはず")
        XCTAssertNotEqual(adapter.lastSource, .none)
        return result.first
    }

    // MARK: - (a) 既知量の平行移動をフローが前進として反映する

    func test_flowBridge_translatesLandmarksOnKnownShift() async throws {
        #if DEBUG
        let baseImage = try await loadFlowEligibleSeedFrame()
        let adapter = try makeAdapter()
        let size = pixelSize(of: baseImage)

        let seeded = try XCTUnwrap(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))
        let baseFlowFrames = adapter.sourceStats.flowFrames

        let dx: CGFloat = 12, dy: CGFloat = 8
        let shifted = translated(baseImage, dx: dx, dy: dy)

        adapter.simulateDetectionFailureForTesting = true
        let result = adapter.allLandmarks(in: shifted, timestampMs: 100)

        XCTAssertFalse(result.isEmpty, "検出全滅でもフロー・ブリッジで空でない結果が返るはず")
        XCTAssertEqual(adapter.lastSource, .flow, "src=flow で記録されるはず")
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, baseFlowFrames + 1,
            "flowFrames カウンタが1件増えるはず"
        )

        let before = seeded.boundingBox
        let after = try XCTUnwrap(result.first).boundingBox
        let beforeCenter = CGPoint(x: before.midX * size.width, y: before.midY * size.height)
        let afterCenter = CGPoint(x: after.midX * size.width, y: after.midY * size.height)
        XCTAssertEqual(
            afterCenter.x - beforeCenter.x, dx, accuracy: 3.0,
            "返るbboxの水平移動量が仕込んだdxとほぼ一致するはず"
        )
        XCTAssertEqual(
            afterCenter.y - beforeCenter.y, dy, accuracy: 3.0,
            "返るbboxの垂直移動量が仕込んだdyとほぼ一致するはず"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }

    // MARK: - (b) 連続上限30フレームで打ち切られる

    func test_flowBridge_stopsAfterMaxConsecutiveFrames() async throws {
        #if DEBUG
        let baseImage = try await loadFlowEligibleSeedFrame()
        let adapter = try makeAdapter()
        XCTAssertNotNil(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))

        let shifted = translated(baseImage, dx: 12, dy: 8)
        adapter.simulateDetectionFailureForTesting = true

        var ts = 100
        for frame in 1...31 {
            ts += 10
            let result = adapter.allLandmarks(in: shifted, timestampMs: ts)
            if frame <= 30 {
                XCTAssertFalse(result.isEmpty, "フレーム \(frame) はまだフロー供給されるはず（上限30）")
                XCTAssertEqual(adapter.lastSource, .flow, "フレーム \(frame) は src=flow のはず")
            } else {
                XCTAssertTrue(result.isEmpty, "31フレーム目は連続上限で打ち切られ空になるはず")
            }
        }
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 30,
            "flowFrames は連続上限30でカウントが止まるはず"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }

    // MARK: - (c) 上限打ち切り後、実検出復帰で再seed・カウンタリセットされる

    func test_flowBridge_reseedsAfterRealDetectionReturns() async throws {
        #if DEBUG
        let baseImage = try await loadFlowEligibleSeedFrame()
        let adapter = try makeAdapter()
        XCTAssertNotNil(seedWithRealDetection(adapter, image: baseImage, timestampMs: 0))

        let shifted = translated(baseImage, dx: 12, dy: 8)
        adapter.simulateDetectionFailureForTesting = true

        var ts = 100
        for _ in 1...31 {
            ts += 10
            _ = adapter.allLandmarks(in: shifted, timestampMs: ts)
        }
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 30,
            "前提: 上限打ち切りまで到達しているはず"
        )

        // 実検出に復帰させる（フラグOFF + 元の実顔フレーム）。
        adapter.simulateDetectionFailureForTesting = false
        ts += 10
        let recovered = adapter.allLandmarks(in: baseImage, timestampMs: ts)
        XCTAssertFalse(recovered.isEmpty, "seed 可能フレームなので実検出に復帰するはず")
        XCTAssertNotEqual(adapter.lastSource, .flow, "復帰フレームは実検出ソースのはず")
        XCTAssertNotEqual(adapter.lastSource, .none)

        // 再seedされているはずなので、フラグを戻せば再びフローが供給される。
        adapter.simulateDetectionFailureForTesting = true
        ts += 10
        let flowedAgain = adapter.allLandmarks(in: shifted, timestampMs: ts)
        XCTAssertFalse(flowedAgain.isEmpty, "実検出復帰による再seed後は再びフローが供給されるはず")
        XCTAssertEqual(adapter.lastSource, .flow)
        XCTAssertEqual(
            adapter.sourceStats.flowFrames, 31,
            "カウンタがリセットされた上で再カウントされているはず（30で止まらない）"
        )
        #else
        throw XCTSkip("DEBUG限定のテスト専用シーム(simulateDetectionFailureForTesting)を使うため、DEBUGビルドでのみ実行可能")
        #endif
    }

    // MARK: - (d) 面積ゲート isFlowBridgeEligible の境界

    /// 実顔（≤0.06）は通し、s5の体誤検出相当（0.11〜0.17）は弾く面積ゲートの境界確認。
    /// 実検出・フローの状態機械には触れず、純粋関数としての境界のみを検証する。
    func test_isFlowBridgeEligible_boundary() throws {
        let adapter = try makeAdapter()

        let area006 = CGRect(x: 0, y: 0, width: 0.3, height: 0.2)
        XCTAssertTrue(
            adapter.isFlowBridgeEligible(area006),
            "面積0.06（真顔相当）は適格のはず"
        )

        // 0.4×0.2 は浮動小数点誤差で 0.08000000000000002 (> 0.08) になるため、
        // 二進表現で厳密に 0.08 になる組み合わせ (0.16×0.5) を使う。
        let area008 = CGRect(x: 0, y: 0, width: 0.16, height: 0.5)
        XCTAssertTrue(
            adapter.isFlowBridgeEligible(area008),
            "面積0.08ちょうど（上限）は適格のはず（境界含む）"
        )

        let area012 = CGRect(x: 0, y: 0, width: 0.4, height: 0.3)
        XCTAssertFalse(
            adapter.isFlowBridgeEligible(area012),
            "面積0.12（体誤検出相当）は不適格のはず"
        )
    }

    // MARK: - (e) cyゲート isFlowBridgeEligible の境界

    /// s5_Bでflowが延命したlowCy 33件はcy0.49〜0.69の弱ソース検出だった一方、
    /// s4/s1のflow利得239フレーム中cy>0.5は1件のみ（CI run 28710148201、2026-07-04）。
    /// 画面下半分（midY>0.5）のトラックはブリッジしない cy ゲートの境界確認。
    func test_isFlowBridgeEligible_centerYBoundary() throws {
        let adapter = try makeAdapter()

        // 面積0.0625（0.08以下）、midYちょうど0.5 → 適格（上限は含む）
        let midY05 = CGRect(x: 0.3, y: 0.25, width: 0.125, height: 0.5)
        XCTAssertTrue(
            adapter.isFlowBridgeEligible(midY05),
            "midY0.5ちょうど（上限）は適格のはず（境界含む）"
        )

        // 面積0.05（0.08以下）、midY0.625 → 不適格
        let midY0625 = CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.25)
        XCTAssertFalse(
            adapter.isFlowBridgeEligible(midY0625),
            "midY0.625（画面下半分）は不適格のはず"
        )

        // 面積0.12（超過）、midY0.25（cyは適格）→ 不適格（面積ゲートが効く）
        let areaOverCyOk = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3)
        XCTAssertFalse(
            adapter.isFlowBridgeEligible(areaOverCyOk),
            "面積超過かつcy適格でも不適格のはず（AND条件）"
        )
    }

    // MARK: - ライブ経路（liveLandmarks）: テンポラル追跡とシークリセット

    /// ライブプレビューと同じ IMAGE モード構成の adapter を作る。
    private func makeImageAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            throw XCTSkip("face_landmarker.task がアプリバンドルにありません")
        }
        var settings = DetectionSettings()
        settings.faceDetectorBackend = .off
        return try MediaPipeFaceLandmarkerAdapter(
            modelPath: modelPath, runningMode: .image, settings: settings
        )
    }

    /// liveLandmarks が IMAGE モードでも検出でき、実検出フレームで
    /// テンポラル track（次フレームの ROI 再検出の種）を構築すること。
    func test_liveLandmarks_seedsTracksOnRealDetection() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeImageAdapter()
        let result = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 1.0)
        XCTAssertFalse(result.faces.isEmpty, "seed フレームは実検出に成功するはず")
        XCTAssertFalse(result.bridgedByFlow)
        XCTAssertGreaterThan(adapter.liveTrackCountForTesting, 0,
                             "実検出フレームで trackedFaces が構築されるはず")
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }

    /// 巻き戻り（シーク）で追跡状態が破棄されること。破棄が漏れると
    /// シーク先の別時系列でシーク前の顔位置 ROI・フローが延命し、
    /// 無関係な位置にモザイクが貼り付く。
    func test_liveTracking_resetsOnBackwardTimeJump() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeImageAdapter()
        _ = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 1.0)
        XCTAssertGreaterThan(adapter.liveTrackCountForTesting, 0)

        // 検出を全滅させた状態で巻き戻す → リセットだけが起きる
        adapter.simulateDetectionFailureForTesting = true
        let back = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 0.2)
        XCTAssertTrue(back.faces.isEmpty)
        XCTAssertEqual(adapter.liveTrackCountForTesting, 0,
                       "巻き戻りで trackedFaces が破棄されるはず")
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }

    /// 前方への大ジャンプ（1 秒超）でも破棄され、通常の連続フレーム
    /// （次バケット）では保持されること。
    func test_liveTracking_resetsOnForwardJump_keepsOnAdjacentBucket() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeImageAdapter()
        _ = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 1.0)
        XCTAssertGreaterThan(adapter.liveTrackCountForTesting, 0)

        // 隣接バケット（+1/15s）: 検出全滅でも track は保持（ROI 再検出の種になる）
        adapter.simulateDetectionFailureForTesting = true
        _ = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 1.0 + 1.0 / 15.0)
        XCTAssertGreaterThan(adapter.liveTrackCountForTesting, 0,
                             "隣接バケットでは track を保持するはず")

        // 1 秒超の前方ジャンプ: 破棄
        _ = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 3.0)
        XCTAssertEqual(adapter.liveTrackCountForTesting, 0,
                       "1 秒超の前方ジャンプで trackedFaces が破棄されるはず")
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }

    /// ライブ経路でも検出全滅フレームがフローで橋渡しされ、`bridgedByFlow` で
    /// タグ付けされること（VIDEO 版 (a) のライブ対応）。
    func test_liveFlow_bridgesTranslatedFrame() async throws {
        #if DEBUG
        let baseImage = try await loadFlowEligibleSeedFrame()
        let adapter = try makeImageAdapter()
        let size = pixelSize(of: baseImage)
        let seeded = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 0.0)
        try XCTSkipIf(seeded.faces.isEmpty, "IMAGE モードで seed フレームを検出できない環境")

        let dx: CGFloat = 12, dy: CGFloat = 8
        let shifted = translated(baseImage, dx: dx, dy: dy)
        adapter.simulateDetectionFailureForTesting = true
        let bridged = adapter.liveLandmarks(in: shifted, atMediaSeconds: 1.0 / 15.0)

        XCTAssertTrue(bridged.bridgedByFlow, "検出全滅フレームは bridgedByFlow=true のはず")
        XCTAssertFalse(bridged.faces.isEmpty)
        XCTAssertEqual(adapter.lastSource, .flow)
        let before = try XCTUnwrap(seeded.faces.first).boundingBox
        let after = try XCTUnwrap(bridged.faces.first).boundingBox
        XCTAssertEqual((after.midX - before.midX) * size.width, dx, accuracy: 3.0)
        XCTAssertEqual((after.midY - before.midY) * size.height, dy, accuracy: 3.0)
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }

    /// ライブのフロー橋渡しは実検出からのメディア時刻 2.0 秒で打ち切られること
    /// （VIDEO 版 (b) のフレーム数上限に対応するメディア秒上限）。
    func test_liveFlow_stopsAfterMaxSeconds() async throws {
        #if DEBUG
        let baseImage = try await loadFlowEligibleSeedFrame()
        let adapter = try makeImageAdapter()
        let seeded = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 0.0)
        try XCTSkipIf(seeded.faces.isEmpty, "IMAGE モードで seed フレームを検出できない環境")

        let shifted = translated(baseImage, dx: 12, dy: 8)
        adapter.simulateDetectionFailureForTesting = true
        let step = 1.0 / 15.0
        var lastBridgedT: Double = 0
        // 2.0s 上限を跨いで供給し続ける（1s 超のジャンプでリセットされないよう連続時刻で）
        for i in 1...35 {
            let t = Double(i) * step
            let result = adapter.liveLandmarks(in: shifted, atMediaSeconds: t)
            if result.bridgedByFlow { lastBridgedT = t }
            if t <= 2.0 {
                XCTAssertTrue(result.bridgedByFlow, "t=\(t) はまだフロー供給されるはず（上限2.0s）")
            } else {
                XCTAssertTrue(result.faces.isEmpty, "t=\(t) はメディア秒上限で打ち切られるはず")
            }
        }
        XCTAssertLessThanOrEqual(lastBridgedT, 2.0)
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }

    /// 明示リセット（MosaicPreviewController.seek → notifyLiveSeek 経由）で
    /// 追跡状態が破棄されること。
    func test_resetLiveTracking_clearsTracks() async throws {
        #if DEBUG
        let baseImage = try await loadDetectableSeedFrame()
        let adapter = try makeImageAdapter()
        _ = adapter.liveLandmarks(in: baseImage, atMediaSeconds: 1.0)
        XCTAssertGreaterThan(adapter.liveTrackCountForTesting, 0)
        adapter.resetLiveTracking()
        XCTAssertEqual(adapter.liveTrackCountForTesting, 0)
        #else
        throw XCTSkip("DEBUG 専用テストシームが必要")
        #endif
    }
}
#endif
