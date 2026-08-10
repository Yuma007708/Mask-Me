import AVFoundation
import Vision
import XCTest
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// 人物同定の較正（S1c）。
///
/// **これが要る理由**: 閾値 0.363 の妥当性は、SFace 公式デモと同じ「YuNet が出す 5 点」で
/// 整列したときの数字として確認したもの（同一人物の最小 0.8384 / 別人の最大 0.2344）。
/// このアプリは YuNet ではなく **MediaPipe の 478 点メッシュから 5 点を作る**ので、
/// 整列が変われば分布ごと動く。同じ素材で測り直して、分離が保たれることを確かめる。
///
/// 正解ラベルは目視で確認したもの。`Fixtures/faces/` の接頭辞 a/b/d/e は人物 ID ではなく
/// 撮影カットの区別で、実際には **a と d が同一人物、b と e が同一人物の計 2 人**。
/// （README にも人物の定義は無い。数字だけ見て「分離できない」と誤読しないこと。）
final class FaceIdentityAccuracyTests: XCTestCase {

    /// 目視で確認した正解ラベル。
    private func person(forFixture name: String) -> String? {
        guard name.hasPrefix("face_") else { return nil }
        let letter = name.dropFirst(5).prefix(while: { $0 != "_" })
        switch letter {
        case "a", "d": return "P1"
        case "b", "e": return "P2"
        default: return nil
        }
    }

    private func makeAdapter() throws -> MediaPipeFaceLandmarkerAdapter {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません（Fixtures に配置してください）")
        }
        return try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .image)
    }

    private struct Sample {
        let name: String
        let person: String
        let signature: FaceSignature
    }

    private func collectSamples() throws -> [Sample] {
        let provider = FaceSignatureProvider()
        try XCTSkipUnless(provider.isAvailable,
                          "sface.onnx がアプリバンドルに見つかりません")
        let adapter = try makeAdapter()
        let fixtures = FixtureLoader.namedImages(in: "faces")
        try XCTSkipIf(fixtures.isEmpty, "Fixtures/faces に顔画像がありません")

        var samples: [Sample] = []
        for (name, image) in fixtures {
            guard let person = person(forFixture: name) else { continue }
            guard let set = adapter.landmarks(in: image) else {
                XCTFail("\(name): MediaPipe が顔を検出できていない（同定以前の問題）")
                continue
            }
            guard let signature = provider.signature(for: set, in: image) else {
                XCTFail("\(name): 478 点メッシュから署名を作れていない")
                continue
            }
            samples.append(Sample(name: name, person: person, signature: signature))
        }
        return samples
    }

    /// メッシュ由来の 5 点で整列しても、同一人物と別人が 1 つの閾値で分離できること。
    func test_meshDerivedAlignmentSeparatesPeople() throws {
        let samples = try collectSamples()
        try XCTSkipIf(samples.count < 4, "人物ラベルの付いた fixture が足りません")

        var minSame = Float.infinity, maxDifferent = -Float.infinity
        var minSamePair = "", maxDifferentPair = ""
        var sameCount = 0, differentCount = 0
        var falseNegative = 0, falsePositive = 0

        for i in samples.indices {
            for j in (i + 1)..<samples.count {
                let similarity = samples[i].signature.similarity(to: samples[j].signature)
                let pair = "\(samples[i].name) vs \(samples[j].name)"
                if samples[i].person == samples[j].person {
                    sameCount += 1
                    if similarity < minSame { minSame = similarity; minSamePair = pair }
                    if similarity < FaceIdentityThreshold.match { falseNegative += 1 }
                } else {
                    differentCount += 1
                    if similarity > maxDifferent {
                        maxDifferent = similarity; maxDifferentPair = pair
                    }
                    if similarity >= FaceIdentityThreshold.match { falsePositive += 1 }
                }
            }
        }

        print(String(format: "[IDENTITY] メッシュ由来5点 同一%d件 最小=%.4f (%@) / "
                     + "別人%d件 最大=%.4f (%@) / マージン=%.4f",
                     sameCount, minSame, minSamePair,
                     differentCount, maxDifferent, maxDifferentPair,
                     minSame - maxDifferent))
        print("[IDENTITY] 参考(YuNet由来5点・P0実測): 同一最小=0.8384 / 別人最大=0.2344 "
              + "/ マージン=0.6040")

        XCTAssertGreaterThan(sameCount, 0, "同一人物ペアが 1 件も無い")
        XCTAssertGreaterThan(differentCount, 0, "別人ペアが 1 件も無い")
        XCTAssertGreaterThan(minSame, maxDifferent,
                             "同一人物と別人が 1 つの閾値で分離できていない"
                             + "（メッシュ由来の 5 点の順序・指標番号を疑うこと）")
        XCTAssertEqual(falseNegative, 0,
                       "閾値 \(FaceIdentityThreshold.match) で同一人物を別人と誤った"
                       + "（選んだ人が素で映る側の誤り）")
        XCTAssertEqual(falsePositive, 0,
                       "閾値 \(FaceIdentityThreshold.match) で別人を同一人物と誤った"
                       + "（選んでいない人が隠れる側の誤り）")
    }

    /// 台帳に流し込んだとき、実際に写っている人数（2 人）へまとまること。
    /// 顔一覧を「検出顔の数」ではなく「人の数」で見せる土台がこれ。
    func test_registryGroupsFixturesIntoActualPeople() throws {
        let samples = try collectSamples()
        try XCTSkipIf(samples.count < 4, "人物ラベルの付いた fixture が足りません")

        var registry = PersonRegistry()
        var assigned: [String: UUID] = [:]
        for sample in samples {
            if let id = registry.register(sample.signature) {
                assigned[sample.name] = id
            }
        }

        let expected = Set(samples.map(\.person)).count
        print("[IDENTITY] 台帳の人数=\(registry.persons.count) 期待=\(expected) "
              + "(署名 \(samples.count) 本, 割り当て \(assigned.count) 本)")
        XCTAssertEqual(registry.persons.count, expected,
                       "写っている人数と台帳の人数が食い違う")

        // 同じ人物ラベルの fixture が同じ人物 ID にまとまっていること。
        for group in Dictionary(grouping: samples, by: \.person) {
            let ids = Set(group.value.compactMap { assigned[$0.name] })
            XCTAssertEqual(ids.count, 1,
                           "\(group.key) が \(ids.count) 人に分かれている")
        }
    }

    /// スタジオ撮影の大きな正面顔は、品質ゲートを通ること。
    /// （ここで落ちるならゲートが厳しすぎて、署名判定がまるで働かない）
    func test_qualityGateAcceptsLargeFrontalFixtures() throws {
        let adapter = try makeAdapter()
        let fixtures = FixtureLoader.namedImages(in: "faces")
        try XCTSkipIf(fixtures.isEmpty, "Fixtures/faces に顔画像がありません")

        var accepted = 0, total = 0
        for (name, image) in fixtures where person(forFixture: name) != nil {
            guard let set = adapter.landmarks(in: image) else { continue }
            let pixelSize = CGSize(width: image.size.width * image.scale,
                                   height: image.size.height * image.scale)
            guard let quality = FaceSignatureQuality.measure(set, imageSize: pixelSize)
            else { continue }
            total += 1
            if quality.isTrustworthy { accepted += 1 } else {
                print(String(format: "[IDENTITY] ゲート落ち %@ 幅=%.0fpx 正面度=%.3f 信頼度=%.2f",
                             name, quality.facePixelWidth, quality.noseSkew, quality.confidence))
            }
        }
        print("[IDENTITY] 品質ゲート通過 \(accepted)/\(total)")
        XCTAssertEqual(accepted, total, "大きな正面顔がゲートで落ちている（ゲートが厳しすぎる）")
    }

    // MARK: - 実素材での署名取得率（S6）

    /// 1 本の動画の集計。
    private struct FieldStat {
        var frames = 0
        var faces = 0
        var measurable = 0      // 5 点が取れた（品質を測れた）顔
        var trustworthy = 0     // 品質ゲートを通った顔
        var narrow = 0          // 幅不足で落ちた
        var skewed = 0          // 正面度で落ちた
        var lowConfidence = 0   // 信頼度で落ちた
        var signed = 0          // 実際に署名が作れた
        var widths: [CGFloat] = []
    }

    private func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// **実素材で署名がどれだけ取れるのかを測る（S6 の出発点）。**
    ///
    /// 人物同定は署名が取れて初めて働く。取れなければ判定は位置追跡へ落ち、
    /// S3〜S5 で入れた仕組みは丸ごと空振りする。そこでまず「実際の動画で
    /// 品質ゲートを通る顔がどれくらいあるのか」を、**ライブ検出と同じ 640px 幅**と
    /// **初期スキャンと同じ原寸**の両方で測る（`minimumFacePixelWidth` は画素幅なので、
    /// どちらの経路かで通過率がまるで違う）。
    ///
    /// 数値を assert しない診断テスト。閾値を決めるための材料を出すのが仕事で、
    /// ここで基準を先に固定すると「測る前に答えを決める」ことになる。
    @MainActor
    func test_Diag_signatureYieldOnRealFootage() throws {
        let provider = FaceSignatureProvider()
        try XCTSkipUnless(provider.isAvailable, "sface.onnx がアプリバンドルに見つかりません")
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())

        let names = ["probe_crowd_01", "probe_crowd_02", "probe_crowd_03", "probe_crowd_04",
                     "probe_hard_dark", "probe_hard_motion", "probe_hard_occluded"]
        var found = 0
        for name in names {
            guard let url = Bundle(for: type(of: self))
                .url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/probe")
            else { continue }
            found += 1
            let asset = AVAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            var live = FieldStat()      // 640px（ライブ検出・カメラ）
            var full = FieldStat()      // 原寸（初期スキャン）
            var t = 0.0
            while t <= duration {
                autoreleasepool {
                    guard let cg = try? generator.copyCGImage(
                        at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                    else { return }
                    let original = UIImage(cgImage: cg)
                    let downscaled = MosaicEditorModel.downscaleForDetection(original)
                    // 検出そのものはライブと同じ 640px で行う（顔の集合を揃えて、
                    // 差が「品質ゲートの通過率」だけになるようにする）。
                    let faces = scanner.allLandmarks(in: downscaled)
                    live.frames += 1
                    full.frames += 1
                    tally(faces, in: downscaled, provider: provider, into: &live)
                    tally(faces, in: original, provider: provider, into: &full)
                }
                t += 0.25
            }
            report(name: "\(name) 640px", stat: live)
            report(name: "\(name) 原寸(\(cgWidth(of: asset))px)", stat: full)
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    private func cgWidth(of asset: AVAsset) -> Int {
        guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
        let size = track.naturalSize.applying(track.preferredTransform)
        return Int(abs(size.width))
    }

    private func tally(_ faces: [FaceLandmarkSet], in image: UIImage,
                       provider: FaceSignatureProvider, into stat: inout FieldStat) {
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        for face in faces {
            stat.faces += 1
            guard let quality = FaceSignatureQuality.measure(face, imageSize: pixelSize) else {
                continue
            }
            stat.measurable += 1
            stat.widths.append(quality.facePixelWidth)
            if quality.facePixelWidth < FaceSignatureQuality.minimumFacePixelWidth {
                stat.narrow += 1
            }
            if quality.noseSkew > FaceSignatureQuality.maximumNoseSkew { stat.skewed += 1 }
            if quality.confidence < FaceSignatureQuality.minimumConfidence {
                stat.lowConfidence += 1
            }
            guard quality.isTrustworthy else { continue }
            stat.trustworthy += 1
            if provider.measure(face, in: image).signature != nil { stat.signed += 1 }
        }
    }

    private func report(name: String, stat: FieldStat) {
        let rate = stat.faces > 0 ? Double(stat.signed) / Double(stat.faces) * 100 : 0
        print(String(format:
            "[S6IDQ] %@ frames=%d faces=%d 署名=%d (%.1f%%) "
            + "測定可=%d ゲート通過=%d / 落ち: 幅=%d 正面度=%d 信頼度=%d "
            + "顔幅px p10=%.0f 中央=%.0f p90=%.0f",
            name, stat.frames, stat.faces, stat.signed, rate,
            stat.measurable, stat.trustworthy, stat.narrow, stat.skewed, stat.lowConfidence,
            percentile(stat.widths, 0.1), percentile(stat.widths, 0.5),
            percentile(stat.widths, 0.9)))
    }

    /// **Simulator で Vision の各リクエストが実際に動くか**を確かめる診断。
    ///
    /// 「Simulator では Vision が動かない」は Intel Mac 時代の話が混ざりやすいので、
    /// 記憶ではなく走らせて確かめる。assert はせず結果を `[S6VIS]` で出す。
    func test_Diag_visionRequestsOnThisRuntime() throws {
        let fixtures = FixtureLoader.namedImages(in: "faces")
        try XCTSkipIf(fixtures.isEmpty, "Fixtures/faces に顔画像がありません")
        guard let (name, image) = fixtures.first, let cgImage = image.cgImage else {
            throw XCTSkip("fixture を CGImage にできません")
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        func probe(_ label: String, _ request: VNRequest) -> String {
            do {
                try handler.perform([request])
                return "\(label)=OK(\(request.results?.count ?? 0)件)"
            } catch {
                return "\(label)=NG(\(error.localizedDescription))"
            }
        }

        let rect = probe("顔矩形", VNDetectFaceRectanglesRequest())
        let landmarks = probe("顔ランドマーク", VNDetectFaceLandmarksRequest())
        let quality = probe("顔の写り品質", VNDetectFaceCaptureQualityRequest())
        let segmentation = probe("人物切り抜き", VNGeneratePersonSegmentationRequest())
        print("[S6VIS] fixture=\(name) \(rect) \(landmarks) \(quality) \(segmentation)")

        // 既存の PersonSegmenter（＝アプリが実際に使っている経路）も通す。
        let mask = PersonSegmenter(quality: .balanced).backgroundMask(cgImage: cgImage)
        print("[S6VIS] PersonSegmenter マスク取得=\(mask != nil)")
    }

    // MARK: - 署名は原寸から測る（S6a）

    /// **同じ顔・同じ検出でも、品質ゲートの通過は切り出し元の解像度で入れ替わる。**
    ///
    /// `minimumFacePixelWidth`(80) は SFace の入力 112×112 に対する実解像度の下限なので、
    /// 640px の検出画像から測ると実素材で軒並み落ちる。ここはその事実を素材で固定する
    /// 契約テスト——「640px で全滅・原寸で通過」が崩れたら、閾値か縮小幅か
    /// `FaceSignatureQuality` の意味論のどれかが動いたということ。
    @MainActor
    func test_signatureGatePassesAtNativeResolutionButNotAt640() throws {
        let provider = FaceSignatureProvider()
        try XCTSkipUnless(provider.isAvailable, "sface.onnx がアプリバンドルに見つかりません")
        let frames = try faceFrames(of: "probe_crowd_04", limit: 8)
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())

        var live = FieldStat()
        var full = FieldStat()
        for original in frames {
            let downscaled = MosaicEditorModel.downscaleForDetection(original)
            // 検出は両方とも 640px（顔の集合を揃え、差を品質ゲートだけに絞る）。
            let faces = scanner.allLandmarks(in: downscaled)
            live.frames += 1
            full.frames += 1
            tally(faces, in: downscaled, provider: provider, into: &live)
            tally(faces, in: original, provider: provider, into: &full)
        }
        report(name: "probe_crowd_04 640px", stat: live)
        report(name: "probe_crowd_04 原寸", stat: full)

        try XCTSkipIf(live.faces == 0, "この素材で顔が検出できませんでした")
        XCTAssertEqual(live.trustworthy, 0,
                       "640px の検出画像でも品質ゲートを通ってしまう。差が出ない素材に"
                       + "変わったか、幅ゲートが緩んだ（この素材の顔幅は 640px で 80px 未満）")
        XCTAssertGreaterThan(full.trustworthy, 0,
                             "原寸でも品質ゲートを 1 つも通らない。原寸経路の意味が無くなっている")
        XCTAssertGreaterThan(full.signed, 0, "原寸でゲートを通ったのに署名が 1 本も作れていない")
    }

    /// **ライブ検出の配線**: `submitPreviewFrameForDetection` が `signatureSource`
    /// （原寸フレーム）から署名を測っていること。
    ///
    /// 上の契約テストは「原寸なら通る」ことしか言わない。実際に原寸が渡っていなければ
    /// 人物同定は動かないので、経路そのものを固定する。原寸を渡さない側を並べて
    /// 測るのは、**この素材で本当に差が出ること**を同じ実行の中で示すため
    /// （差が出ない素材に変わったら、通る側だけ見ていると気づけない）。
    @MainActor
    func test_livePathMeasuresSignatureFromNativeFrame() async throws {
        try XCTSkipUnless(FaceSignatureProvider.shared.isAvailable,
                          "sface.onnx がアプリバンドルに見つかりません")
        let frames = try faceFrames(of: "probe_crowd_04", limit: 1)
        guard let original = frames.first, let nativeCG = original.cgImage,
              let detectionCG = MosaicEditorModel.downscaleForDetection(original).cgImage
        else { throw XCTSkip("フレームを CGImage にできません") }

        let withNative = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        withNative.submitPreviewFrameForDetection(detectionCG, at: 5.0) { nativeCG }
        // 原寸を渡さない = 修正前（および退行したとき）の姿。
        let withoutNative = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        withoutNative.submitPreviewFrameForDetection(detectionCG, at: 5.0)

        // 署名は検出より**遅れて**届く（`liveSignatureQueue`）。検出の完了だけを
        // 待つと署名が入る前に読んでしまうので、置き場が埋まるのを待つ。
        try await waitForLiveDetection(withNative)
        try await waitForLiveDetection(withoutNative)
        try await waitForSignature(withNative)
        // 入らないことを確かめる側は、同じだけ待ってから読む（待たずに 0 件を見ても
        // 「まだ来ていない」と区別できない）。
        try await Task.sleep(nanoseconds: 3_000_000_000)

        print("[S6IDQ] ライブ配線 原寸=\(withNative.signatureCache.count)件 "
              + "縮小のみ=\(withoutNative.signatureCache.count)件")
        XCTAssertEqual(withoutNative.signatureCache.count, 0,
                       "縮小画像だけでも署名が入る。この素材では差が出ないので、"
                       + "前提素材を選び直さないとこのテストは配線を守れない")
        XCTAssertGreaterThan(withNative.signatureCache.count, 0,
                             "原寸を渡しても署名が置き場に入らない。ライブ検出の"
                             + "signatureSource が使われていない")
    }

    /// 署名が置き場に入るまで待つ（`liveSignatureQueue` は検出の後ろで追いつく）。
    @MainActor
    private func waitForSignature(_ model: MosaicEditorModel,
                                  timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.signatureCache.isEmpty {
            if Date() > deadline { return }   // 空のまま返す。判定は呼び出し側の assert に任せる
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// ライブ検出 1 件分の完了待ち（`liveDetectionInFlight` が下りるまで）。
    @MainActor
    private func waitForLiveDetection(_ model: MosaicEditorModel,
                                     timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.liveDetectionInFlight {
            if Date() > deadline { XCTFail("ライブ検出が \(timeout)s で完了しなかった"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Vision 顔検出の限界利得（S6b）

    /// **Vision 顔検出を union で足すと、何が増えるのか**を実素材で測る診断。
    ///
    /// Vision の顔検出は過去に導入 → 常時 ON → デフォルト化 → **完全削除**という
    /// 往復の跡がある（削除理由は `DetectionSettings` の注記: 実機で torso・首・肩を
    /// 顔として拾い体モザイクの原因になった／Simulator で 0 検出のため挙動検証が
    /// できない）。`CompositeBBoxDetector` は IoU 重複除去だけの union でフィルタが
    /// 無いため、Vision を足すと**誤検出はそのまま足し算される**。
    ///
    /// そこで再導入の前に、現行 union（FaceDetector + YuNet）に対する Vision の
    /// 差分だけを両側で数える:
    /// - 実顔素材で「Vision だけが見つけた矩形」= 取りこぼしを減らせる見込み（得）
    /// - 非顔素材で「Vision だけが見つけた矩形」= 増える誤検出（損）
    ///
    /// **assert しない。** 得と損の数字を出すのが仕事で、ここで基準を先に決めると
    /// 「測る前に答えを決める」ことになる。**Simulator では Vision が動かないので
    /// skip する**（`nil`/0 件を「損も得も無い」と読み違えないため）。
    @MainActor
    func test_Diag_visionMarginalGainOverCurrentDetectors() throws {
        try XCTSkipUnless(visionFaceDetectionWorks(),
                          "この実行環境では Vision の顔検出が動きません（Simulator では既知。"
                          + "実機で走らせること）")
        let current = CompositeBBoxDetector([MediaPipeFaceBBoxDetector(), YuNetFaceDetector()])

        // 非顔素材（誤検出専用）。ここで Vision 独自検出が出れば、それは誤検出の増分。
        var nonFace = (images: 0, current: 0, vision: 0, visionOnly: 0)
        let nonFaceNames = ["mannequin", "statue", "animal", "mask", "living_room"]
        for (name, image) in FixtureLoader.namedImages(in: "probe")
        where nonFaceNames.contains(where: { name.hasPrefix($0) }) {
            let base = current.detectFaceBoundingBoxes(in: image)
            let vision = visionFaceBoxes(in: image)
            nonFace.images += 1
            nonFace.current += base.count
            nonFace.vision += vision.count
            nonFace.visionOnly += vision.filter { v in !base.contains { overlaps($0, v) } }.count
        }
        for image in FixtureLoader.images(in: "nonfaces") {
            let base = current.detectFaceBoundingBoxes(in: image)
            let vision = visionFaceBoxes(in: image)
            nonFace.images += 1
            nonFace.current += base.count
            nonFace.vision += vision.count
            nonFace.visionOnly += vision.filter { v in !base.contains { overlaps($0, v) } }.count
        }
        print("[S6VIS2] 非顔 画像=\(nonFace.images) 現行=\(nonFace.current)件 "
              + "Vision=\(nonFace.vision)件 Vision独自=\(nonFace.visionOnly)件（＝誤検出の増分）")

        // 実顔素材。Vision 独自検出は「取りこぼしを拾えた」候補だが、体・首の誤検出も
        // ここに混ざる（実顔動画にも体は写っている）ので、得の**上限**として読む。
        var found = 0
        for name in ["probe_crowd_01", "probe_crowd_02", "probe_crowd_03", "probe_crowd_04",
                     "probe_hard_dark", "probe_hard_motion", "probe_hard_occluded"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 6), !frames.isEmpty
            else { continue }
            found += 1
            var stat = (current: 0, vision: 0, visionOnly: 0, currentOnly: 0)
            for image in frames {
                let base = current.detectFaceBoundingBoxes(in: image)
                let vision = visionFaceBoxes(in: image)
                stat.current += base.count
                stat.vision += vision.count
                stat.visionOnly += vision.filter { v in !base.contains { overlaps($0, v) } }.count
                stat.currentOnly += base.filter { b in !vision.contains { overlaps($0, b) } }.count
            }
            print("[S6VIS2] \(name) frames=\(frames.count) 現行=\(stat.current)件 "
                  + "Vision=\(stat.vision)件 Vision独自=\(stat.visionOnly)件 "
                  + "現行独自=\(stat.currentOnly)件")
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    // MARK: - 群衆素材でランドマークが 0 件になる件の切り分け（S6c）

    /// **`probe_crowd_02` は正面顔が 6 人はっきり写っているのに、ランドマーク段が 0 件になる。**
    ///
    /// `numFaces=5`・各 confidence `0.2` という緩い設定で 0 件は素材の難しさで説明が
    /// つかないので、原因が**検出前の縮小**（`downscaleForDetection` の 640px）に
    /// あるのかを、同じフレーム・同じ検出器で解像度だけ変えて数える。
    ///
    /// bbox 検出器（FaceDetector + YuNet）の件数も並べる。bbox が反応していて
    /// ランドマークだけ 0 なら、落ちているのは**顔メッシュ段**だと確定できる
    /// （bbox も 0 なら検出前の画像処理を疑う番になる）。
    ///
    /// **assert しない診断。** どこで落ちているかを特定するのが仕事で、
    /// ここで合格ラインを決めると原因が判る前に基準が固まる。
    @MainActor
    func test_Diag_crowdLandmarkYieldByResolution() throws {
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let bbox = CompositeBBoxDetector([MediaPipeFaceBBoxDetector(), YuNetFaceDetector()])
        var found = 0
        for name in ["probe_crowd_01", "probe_crowd_02", "probe_crowd_03", "probe_crowd_04"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 8), !frames.isEmpty
            else { continue }
            found += 1
            var stat = (lmDown: 0, lmFull: 0, bbDown: 0, bbFull: 0)
            var size = CGSize.zero
            for image in frames {
                autoreleasepool {
                    let downscaled = MosaicEditorModel.downscaleForDetection(image)
                    size = image.size
                    stat.lmDown += scanner.allLandmarks(in: downscaled).count
                    stat.lmFull += scanner.allLandmarks(in: image).count
                    stat.bbDown += bbox.detectFaceBoundingBoxes(in: downscaled).count
                    stat.bbFull += bbox.detectFaceBoundingBoxes(in: image).count
                }
            }
            print("[S6CROWD] \(name) frames=\(frames.count) 原寸=\(Int(size.width))x\(Int(size.height)) "
                  + "ランドマーク[640px=\(stat.lmDown) 原寸=\(stat.lmFull)] "
                  + "bbox[640px=\(stat.bbDown) 原寸=\(stat.bbFull)]")
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    /// **どのゲートが群衆素材の顔を落としているか**を棄却理由の内訳で特定する（S6c）。
    ///
    /// 上の診断で「bbox は反応しているのにランドマークは 0 件」まで絞れたので、
    /// 次は `allLandmarks` の最終段 `verifySuspiciousFaces`（crop 再検証）が
    /// 何を理由に候補を全棄却しているかを見る。`verifyStats` は採否に影響しない
    /// 集計なので、これを読んでも挙動は変わらない。
    ///
    /// 比較のため、ランドマークが取れている `crowd_01` / `crowd_04` も同じ形で出す。
    /// 「落ちる素材だけ」を見ても、その内訳が正常時と同じなのかが判らない。
    ///
    /// **assert しない診断。**
    @MainActor
    func test_Diag_crowdVerifyRejectionBreakdown() throws {
        var found = 0
        for name in ["probe_crowd_01", "probe_crowd_02", "probe_crowd_03", "probe_crowd_04"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 8), !frames.isEmpty
            else { continue }
            found += 1
            // 素材ごとに検出器を作り直す（`verifyStats` は累積なので、使い回すと
            // 前の素材の内訳が混ざる）。
            let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
            var detected = 0
            for image in frames {
                autoreleasepool {
                    detected += scanner.allLandmarks(
                        in: MosaicEditorModel.downscaleForDetection(image)).count
                }
            }
            guard let adapter = scanner as? MediaPipeFaceLandmarkerAdapter else {
                print("[S6CROWD2] \(name): verifyStats を読める実装ではありません")
                continue
            }
            let s = adapter.verifyStats
            print("[S6CROWD2] \(name) frames=\(frames.count) detected=\(detected) "
                  + "examined=\(s.examined) passed=\(s.passed) "
                  + "preGate=\(s.preGate) noRedetect=\(s.noRedetection) geometry=\(s.geometry) "
                  + "conf=\(s.confidence) bodyShape=\(s.bodyShape) displaced=\(s.displaced)")
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    /// **bbox が指している矩形は本当に顔なのか**、そして**そこだけを切り出せば
    /// メッシュが取れるのか**を測る（S6c）。
    ///
    /// `examined=0` から「crop 再検証より手前で候補が 0 になっている」ところまで
    /// 絞れた。残る分岐は 2 つで、どちらかで直す場所がまったく変わる:
    ///
    /// - bbox の 32 件が**誤検出**（顔でない）→ ランドマーク 0 は正しい挙動で、
    ///   直すべきものは無い
    /// - bbox は正しく顔を指しているのに**メッシュ段が全画面では取れない**
    ///   → 取りこぼしで、augment 経路（bbox → crop → メッシュ）が効いていない
    ///
    /// そこで bbox 矩形を切り出し、その 1 枚だけを `allLandmarks` に通す。
    /// 全画面で 0・crop で取れるなら後者。crop でも 0 なら、矩形を画像として
    /// 書き出して目視で顔かどうかを判定する（`[S6CROWD3] 保存先`）。
    ///
    /// **assert しない診断。**
    @MainActor
    func test_Diag_crowdBBoxCropYieldsMesh() throws {
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let bbox = CompositeBBoxDetector([MediaPipeFaceBBoxDetector(), YuNetFaceDetector()])
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s6crowd", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var found = 0
        for name in ["probe_crowd_02", "probe_crowd_03", "probe_crowd_04"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 3), !frames.isEmpty
            else { continue }
            found += 1
            var boxes = 0
            var cropHits = 0
            for (frameIndex, image) in frames.enumerated() {
                autoreleasepool {
                    for (boxIndex, box) in bbox.detectFaceBoundingBoxes(in: image).enumerated() {
                        boxes += 1
                        // 顔の周りに少し余白を付ける（タイトすぎる矩形では
                        // メッシュ段が輪郭を掴めないことがあるため）。
                        let roi = expandedNormalizedRect(box, factor: 1.6)
                        guard let crop = croppedImage(image, normalizedRect: roi) else { return }
                        let hit = !scanner.allLandmarks(in: crop).isEmpty
                        if hit { cropHits += 1 }
                        // 目視用に最初のフレームの矩形だけ書き出す（全部出すと数が多すぎる）。
                        if frameIndex == 0, boxIndex < 8,
                           let data = crop.jpegData(compressionQuality: 0.9) {
                            try? data.write(to: outDir.appendingPathComponent(
                                "\(name)_f0_b\(boxIndex)_mesh\(hit ? "1" : "0").jpg"))
                        }
                    }
                }
            }
            print("[S6CROWD3] \(name) frames=\(frames.count) bbox=\(boxes)件 "
                  + "crop単体でメッシュが取れた=\(cropHits)件")
        }
        print("[S6CROWD3] 保存先=\(outDir.path)")
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    /// **augment 経路のどの段で bbox 候補が消えるのか**を、実装と同じ順序で数える（S6c）。
    ///
    /// `crowd_02` は bbox が本物の顔を指していて（目視確認済み）、1.6 倍に広げた crop
    /// なら 13 件中 12 件でメッシュが取れる。それでも `allLandmarks` は 0 件を返す。
    /// `augmentWithBBoxDetector` は候補を次の順で削るので、同じ順で数えて
    /// **どこで 0 になるか**を突き止める:
    ///
    /// 1. 生 bbox
    /// 2. 形状ガード（短辺 6% 以上 / ピクセル換算 w/h が 0.5〜1.6）
    /// 3. crop → メッシュ抽出。**実装は余白なしのタイト crop**（ここが本命の疑い）
    /// 4. `confidence >= 0.6`（= 478 点中 287 点以上）
    ///
    /// 3 と 4 は「余白なし」と「1.6 倍」を並べて出す。両者の差がそのまま
    /// 「crop の取り方だけで失われている顔」の数になる。
    ///
    /// **assert しない診断。**
    @MainActor
    func test_Diag_crowdAugmentFunnel() throws {
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())
        let bbox = CompositeBBoxDetector([MediaPipeFaceBBoxDetector(), YuNetFaceDetector()])
        var found = 0
        for name in ["probe_crowd_02", "probe_crowd_03", "probe_crowd_04"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 4), !frames.isEmpty
            else { continue }
            found += 1
            var funnel = (raw: 0, shaped: 0, tightMesh: 0, tightConf: 0,
                          wideMesh: 0, wideConf: 0)
            for image in frames {
                autoreleasepool {
                    for box in bbox.detectFaceBoundingBoxes(in: image) {
                        funnel.raw += 1
                        // 実装と同一の述語を呼ぶ（式を複製すると実装変更で診断が嘘になる）。
                        guard RawFaceBoxGate.accepts(box, imageSize: image.size) else { continue }
                        funnel.shaped += 1

                        // 実装と同じ「余白なし」。
                        if let crop = croppedImage(image, normalizedRect: box),
                           let face = scanner.allLandmarks(in: crop).first {
                            funnel.tightMesh += 1
                            if face.confidence >= 0.6 { funnel.tightConf += 1 }
                        }
                        // 比較用の「1.6 倍」。
                        let wide = expandedNormalizedRect(box, factor: 1.6)
                        if let crop = croppedImage(image, normalizedRect: wide),
                           let face = scanner.allLandmarks(in: crop).first {
                            funnel.wideMesh += 1
                            if face.confidence >= 0.6 { funnel.wideConf += 1 }
                        }
                    }
                }
            }
            print("[S6CROWD4] \(name) frames=\(frames.count) 生bbox=\(funnel.raw) "
                  + "形状ガード通過=\(funnel.shaped) "
                  + "余白なし[mesh=\(funnel.tightMesh) conf0.6=\(funnel.tightConf)] "
                  + "1.6倍[mesh=\(funnel.wideMesh) conf0.6=\(funnel.wideConf)]")
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    /// **形状ガードが何を見て落としているのか**を、生 bbox の実値で確かめる（S6c）。
    ///
    /// 修正前は `crowd_02` の生 bbox 18 件が全て形状ガードで落ち、同じ 1280x720 の
    /// `crowd_04` は 14 件全てが通っていた。実値を出したところ `crowd_02` の顔は
    /// 正規化 w=0.038〜0.043 で、**正規化のまま持っていた大きさゲート（6%）を
    /// 幅だけが割っていた**ことが確定した（→ `RawFaceBoxGate` でピクセル換算に修正）。
    /// 同種の再発を実値で見つけられるよう診断は残す。
    ///
    /// **assert しない診断。**
    @MainActor
    func test_Diag_crowdRawBoxShapes() throws {
        let bbox = CompositeBBoxDetector([MediaPipeFaceBBoxDetector(), YuNetFaceDetector()])
        var found = 0
        for name in ["probe_crowd_02", "probe_crowd_04"] {
            guard let frames = try? faceSampleFrames(of: name, limit: 1), let image = frames.first
            else { continue }
            found += 1
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            let boxes = bbox.detectFaceBoundingBoxes(in: image)
            let described = boxes.prefix(8).map { box -> String in
                let ratio = box.height > 0 ? (box.width / box.height) * aspect : -1
                return String(format: "w=%.3f h=%.3f px比=%.2f", box.width, box.height, ratio)
            }
            print("[S6CROWD5] \(name) 画像=\(Int(image.size.width))x\(Int(image.size.height)) "
                  + "aspect=\(String(format: "%.2f", aspect)) bbox=\(boxes.count)件 "
                  + "→ \(described.joined(separator: " | "))")
        }
        try XCTSkipIf(found == 0, "Fixtures/probe に計測用の動画がありません")
    }

    /// 正規化矩形を中心を保ったまま `factor` 倍し、[0,1] にクランプする。
    private func expandedNormalizedRect(_ rect: CGRect, factor: CGFloat) -> CGRect {
        let w = rect.width * factor
        let h = rect.height * factor
        let x = rect.midX - w / 2
        let y = rect.midY - h / 2
        let clampedX = max(0, min(1, x))
        let clampedY = max(0, min(1, y))
        return CGRect(x: clampedX, y: clampedY,
                      width: min(w, 1 - clampedX), height: min(h, 1 - clampedY))
    }

    /// 正規化矩形（左上原点）で画像を切り出す。
    private func croppedImage(_ image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let pixels = CGRect(x: normalizedRect.minX * CGFloat(cg.width),
                            y: normalizedRect.minY * CGFloat(cg.height),
                            width: normalizedRect.width * CGFloat(cg.width),
                            height: normalizedRect.height * CGFloat(cg.height))
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = cg.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// この実行環境で Vision の顔矩形検出が動くか（`PersonSegmenter.isAvailable` と同じ流儀で
    /// 記憶ではなく実測する）。Simulator では `Could not create inference context` で失敗する。
    private func visionFaceDetectionWorks() -> Bool {
        guard let image = FixtureLoader.namedImages(in: "faces").first?.image,
              let cgImage = image.cgImage else { return false }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return false
        }
        return request.results != nil
    }

    /// Vision の顔矩形を `FaceBBoxDetecting` の契約（**左上原点・[0,1] 正規化**）へ揃える。
    /// Vision は左下原点なので y を反転しないと union の IoU が全て 0 になり、
    /// 「Vision 独自検出」が水増しされる。
    private func visionFaceBoxes(in image: UIImage) -> [CGRect] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    /// `CompositeBBoxDetector` と**同じ閾値**で「同じ顔」と見なす（0.3）。
    /// ここを変えると union の実挙動と食い違い、独自検出の数が実態から離れる。
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return false }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 && interArea / unionArea > 0.3
    }

    /// 動画から等間隔にフレームを取り出す（顔の有無で絞らない。取りこぼしを測るのに
    /// 「現行検出器が顔を見つけたフレーム」だけを見ては意味がない）。
    @MainActor
    private func faceSampleFrames(of name: String, limit: Int) throws -> [UIImage] {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/probe")
        else { throw XCTSkip("Fixtures/probe/\(name).mov がありません") }
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let step = duration / Double(limit + 1)
        return (1...limit).compactMap { index in
            let time = CMTime(seconds: step * Double(index), preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    /// `Fixtures/probe` の動画から、**顔が検出できたフレーム**を最大 `limit` 枚返す。
    /// 顔の有無は 640px 縮小後の検出で見る（ライブ経路と同じ条件）。
    @MainActor
    private func faceFrames(of name: String, limit: Int) throws -> [UIImage] {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/probe")
        else { throw XCTSkip("Fixtures/probe/\(name).mov がありません") }
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let scanner = makeFaceLandmarker(forVideo: false, settings: DetectionSettings())

        var result: [UIImage] = []
        var t = 0.0
        while t <= duration, result.count < limit {
            autoreleasepool {
                guard let cg = try? generator.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                else { return }
                let image = UIImage(cgImage: cg)
                if !scanner.allLandmarks(in: MosaicEditorModel.downscaleForDetection(image))
                    .isEmpty {
                    result.append(image)
                }
            }
            t += 0.25
        }
        return result
    }
}
#endif
