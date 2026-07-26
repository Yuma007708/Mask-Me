import AVFoundation
import Metal
import MosaicCore
import UIKit
import XCTest
@testable import MaskMe

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// 実顔素材でモザイクの焼き込みを画素で確認する。
///
/// 既存の画素検証（`MultiClipExportTests`）は 8px 市松 + 円周 477 点の合成顔なので、
/// **478 点フルメッシュの 3D warp 経路は一度も通らない**（477 点は意図的にコンタマスク
/// 経路へ落としてある）。ここは `Fixtures/profile.mov`（正面 → 完全な横顔まで首を回す
/// 実写クリップ）を素材にして、その経路を実際に通す。
///
/// 素材が無い環境では `XCTSkip`（`Fixtures/README.md` 参照）。
final class RealFaceMosaicTests: XCTestCase {
    /// 顔領域の平坦さ。ブロックモザイクはブロック内を単色へ潰すので、隣接画素の
    /// 絶対差の平均（total variation）が素の映像より必ず小さくなる。
    ///
    /// 標準偏差ではなく TV を使うのは、実顔は素のままでも領域全体の輝度分布が広く
    /// （髪と肌と背景が同居する）std が下がりにくい一方、**ブロック内が平坦かどうか**は
    /// TV に直接出るため。
    private func totalVariation(_ pixels: [UInt8], width: Int) -> Double {
        guard width > 1, pixels.count >= width * 2 else { return .nan }
        let height = pixels.count / width
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            for x in 1..<width {
                sum += abs(Double(pixels[y * width + x]) - Double(pixels[y * width + x - 1]))
                count += 1
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    /// 出力動画の全フレームを (pts, 輝度平面, 幅, 高さ) で返す。
    private func luminanceFrames(of url: URL) async throws
    -> [(pts: Double, plane: [UInt8], width: Int, height: Int)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()

        var frames: [(pts: Double, plane: [UInt8], width: Int, height: Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            var plane = [UInt8](repeating: 0, count: width * height)
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<height {
                    for x in 0..<width {
                        plane[y * width + x] = base[y * bytesPerRow + x * 4]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append((pts, plane, width, height))
        }
        return frames
    }

    /// 正規化矩形を輝度平面から切り出す。
    private func patch(_ frame: (pts: Double, plane: [UInt8], width: Int, height: Int),
                       rect: CGRect) -> (pixels: [UInt8], width: Int) {
        let x0 = max(0, Int(rect.minX * CGFloat(frame.width)))
        let x1 = min(frame.width, Int(rect.maxX * CGFloat(frame.width)))
        let y0 = max(0, Int(rect.minY * CGFloat(frame.height)))
        let y1 = min(frame.height, Int(rect.maxY * CGFloat(frame.height)))
        guard x1 > x0, y1 > y0 else { return ([], 0) }
        var pixels: [UInt8] = []
        pixels.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 { pixels.append(frame.plane[y * frame.width + x]) }
        }
        return (pixels, x1 - x0)
    }

    /// 目視用の PNG をテスト成果物として書き出し、ホストから読めるパスをログに出す。
    private func dump(_ frame: (pts: Double, plane: [UInt8], width: Int, height: Int),
                      name: String) {
        var plane = frame.plane
        guard let provider = CGDataProvider(data: Data(bytes: &plane, count: plane.count) as CFData),
              let cg = CGImage(width: frame.width, height: frame.height,
                               bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: frame.width,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
              let data = UIImage(cgImage: cg).pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("[REALFACE] dumped \(url.path)")
    }

    func test_realFace_mosaicIsBakedInsideApplyRangeOnly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        guard let src = FixtureLoader.videoURL(named: "profile") else {
            throw XCTSkip("Fixtures/profile.mov がありません")
        }

        let asset = AVURLAsset(url: src)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThan(duration, 2.0)

        // 1) 素材を事前スキャンして顔の位置と点数を掴む（フルメッシュ経路の確認も兼ねる）。
        let scanner = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var faceRects: [Double: CGRect] = [:]
        var fullMeshCount = 0
        var scanned = 0
        var time = 0.0
        while time < duration {
            defer { time += 0.25 }
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600),
                                                      actualTime: nil) else { continue }
            scanned += 1
            guard let set = scanner.landmarks(in: UIImage(cgImage: cg),
                                              timestampMs: Int(time * 1000)) else { continue }
            if set.isFullMesh { fullMeshCount += 1 }
            let xs = set.points.map { CGFloat($0.x) }
            let ys = set.points.map { CGFloat($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }
            faceRects[time] = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        print("[REALFACE] scanned=\(scanned) detected=\(faceRects.count) fullMesh=\(fullMeshCount)")
        XCTAssertGreaterThan(faceRects.count, 0, "実顔素材で 1 フレームも検出できていない")
        XCTAssertEqual(fullMeshCount, faceRects.count,
                       "検出できたのにフルメッシュ(478点)でないフレームがある")

        // 2) 前半だけモザイクを掛けて書き出す。
        let sourceID = UUID()
        let clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: duration)]
        let composition = try await TimelineCompositionBuilder()
            .build(clips: clips, sources: [sourceID: asset]).composition
        let mapping = TimelineMapping(clips: clips)
        let half = duration / 2

        let renderer = try MosaicRenderer(evaluator: TrackingEvaluator(smoothing: 1.0))
        let exporter = VideoMosaicExporter(
            renderer: renderer,
            landmarker: try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .video))
        let outURL = try await exporter.export(
            asset: composition, mapping: mapping,
            applyRanges: [MosaicApplyRange(clipID: clips[0].id, sourceID: sourceID,
                                           sourceStart: 0, sourceEnd: half)]) { _ in }
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 3) 顔領域の平坦さを区間の内外で比べる。
        let frames = try await luminanceFrames(of: outURL)
        XCTAssertGreaterThan(frames.count, 0)

        func nearestRect(to pts: Double) -> CGRect? {
            faceRects.min { abs($0.key - pts) < abs($1.key - pts) }.map(\.value)
        }

        var inside: [Double] = []
        var outside: [Double] = []
        var dumpedInside = false
        var dumpedOutside = false
        for frame in frames {
            // 顔の中心 60% だけ見る。輪郭の外を混ぜると背景の平坦さが指標を鈍らせる。
            guard let rect = nearestRect(to: frame.pts) else { continue }
            let core = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
            let (pixels, width) = patch(frame, rect: core)
            let variation = totalVariation(pixels, width: width)
            guard variation.isFinite else { continue }
            if frame.pts < half - 0.2 {
                inside.append(variation)
                if !dumpedInside, frame.pts > 0.5 {
                    dump(frame, name: "realface-inside")
                    dumpedInside = true
                }
            } else if frame.pts > half + 0.2 {
                outside.append(variation)
                if !dumpedOutside, frame.pts > half + 0.5 {
                    dump(frame, name: "realface-outside")
                    dumpedOutside = true
                }
            }
        }

        XCTAssertGreaterThan(inside.count, 0)
        XCTAssertGreaterThan(outside.count, 0)
        let insideMean = inside.reduce(0, +) / Double(inside.count)
        let outsideMean = outside.reduce(0, +) / Double(outside.count)
        print("[REALFACE] TV inside(mosaic)=\(insideMean) outside(raw)=\(outsideMean) "
              + "frames=\(inside.count)/\(outside.count)")

        XCTAssertLessThan(insideMean, outsideMean * 0.6,
                          "適用区間内の顔が平坦になっていない（モザイクが乗っていない疑い）: "
                              + "inside=\(insideMean) outside=\(outsideMean)")

        // 4) 区間を後半へ入れ替えて、**横顔**にもモザイクが乗ることを確かめる。
        //    profile.mov は後半で完全なプロファイルまで首が回るので、3D warp が
        //    効いていなければここで顔からモザイクがずれる。
        let flippedURL = try await exporter.export(
            asset: composition, mapping: mapping,
            applyRanges: [MosaicApplyRange(clipID: clips[0].id, sourceID: sourceID,
                                           sourceStart: half, sourceEnd: duration)]) { _ in }
        defer { try? FileManager.default.removeItem(at: flippedURL) }

        var profileInside: [Double] = []
        var dumpedProfile = false
        for frame in try await luminanceFrames(of: flippedURL) where frame.pts > half + 0.2 {
            guard let rect = nearestRect(to: frame.pts) else { continue }
            let core = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
            let (pixels, width) = patch(frame, rect: core)
            let variation = totalVariation(pixels, width: width)
            guard variation.isFinite else { continue }
            profileInside.append(variation)
            if !dumpedProfile, frame.pts > duration - 1.0 {
                dump(frame, name: "realface-profile-mosaic")
                dumpedProfile = true
            }
        }
        XCTAssertGreaterThan(profileInside.count, 0)
        let profileMean = profileInside.reduce(0, +) / Double(profileInside.count)
        print("[REALFACE] TV profile-half mosaic=\(profileMean) (raw was \(outsideMean))")
        XCTAssertLessThan(profileMean, outsideMean * 0.6,
                          "横顔区間でモザイクが乗っていない: \(profileMean) vs raw \(outsideMean)")
    }

    // MARK: - 診断: 実素材での検出の当たり外れ

    /// 検出結果を重ねた PNG を書き出す（どこを顔と判定したかを目で確かめるため）。
    private func dumpAnnotated(_ image: UIImage, sets: [FaceLandmarkSet], name: String) {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let annotated = renderer.image { context in
            image.draw(at: .zero)
            context.cgContext.setStrokeColor(UIColor.red.cgColor)
            context.cgContext.setLineWidth(max(2, image.size.width / 200))
            for set in sets {
                let xs = set.points.map { CGFloat($0.x) * image.size.width }
                let ys = set.points.map { CGFloat($0.y) * image.size.height }
                guard let minX = xs.min(), let maxX = xs.max(),
                      let minY = ys.min(), let maxY = ys.max() else { continue }
                context.cgContext.stroke(CGRect(x: minX, y: minY,
                                                width: maxX - minX, height: maxY - minY))
            }
        }
        guard let data = annotated.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("[PROBE] dumped \(url.path)")
    }

    /// `Fixtures/probe/` に置いた実素材（水着・群衆・暗所・逆光・遮蔽など）を走査し、
    /// 何を顔として検出したかを出力する。合否は判定しない — 素材ごとの期待値は
    /// 人が見て決めるしかないため、事実（検出数と位置）だけを残す診断テスト。
    func test_diagnose_detectionOnProbeClips() throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        let urls = (Bundle(for: RealFaceMosaicTests.self)
            .urls(forResourcesWithExtension: "mov", subdirectory: "Fixtures/probe") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(urls.isEmpty, "Fixtures/probe に素材がありません")

        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // 素材ごとに作り直す（VIDEO モードは timestamp の単調増加を要求する）。
            let adapter = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath,
                                                             runningMode: .video)

            var frames = 0
            var detectedFrames = 0
            var maxFaces = 0
            var fullMesh = 0
            var lines: [String] = []
            var dumped = false
            var time = 0.0
            while time < duration {
                defer { time += 0.5 }
                guard let cg = try? generator.copyCGImage(
                    at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { continue }
                frames += 1
                let image = UIImage(cgImage: cg)
                let sets = adapter.allLandmarks(in: image, timestampMs: Int(time * 1000))
                guard !sets.isEmpty else { continue }
                detectedFrames += 1
                maxFaces = max(maxFaces, sets.count)
                fullMesh += sets.filter(\.isFullMesh).count
                let rects = sets.map { set -> String in
                    let xs = set.points.map { Double($0.x) }
                    let ys = set.points.map { Double($0.y) }
                    return String(format: "(%.2f,%.2f)-(%.2f,%.2f)",
                                  xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
                }
                lines.append(String(format: "t=%.1f n=%d %@", time, sets.count, rects.joined(separator: " ")))
                if !dumped {
                    dumpAnnotated(image, sets: sets, name: name)
                    dumped = true
                }
            }
            print("[PROBE] \(name) frames=\(frames) detectedFrames=\(detectedFrames) "
                  + "maxFaces=\(maxFaces) fullMesh=\(fullMesh)")
            for line in lines.prefix(8) { print("[PROBE]   \(line)") }
        }
    }

    /// 静止画版。彫像・マネキン・仮面・動物など「顔に見えるが人ではないもの」を
    /// 顔と判定するかを出力する。こちらも合否は判定しない。
    func test_diagnose_detectionOnProbeStills() throws {
        guard let modelPath = FixtureLoader.modelPath() else {
            throw XCTSkip("face_landmarker.task が見つかりません")
        }
        let bundle = Bundle(for: RealFaceMosaicTests.self)
        var urls: [URL] = []
        // probe（顔らしい非顔）と faces（本物の顔 1 人）の両方を見る。
        // 重複検出が「顔らしい非顔」限定なのか、本物の顔でも起きるのかを分けるため。
        for directory in ["Fixtures/probe", "Fixtures/faces", "Fixtures/nonfaces"] {
            for ext in ["jpg", "jpeg", "png"] {
                urls += bundle.urls(forResourcesWithExtension: ext, subdirectory: directory) ?? []
            }
        }
        urls.sort { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(urls.isEmpty, "Fixtures/probe に静止画がありません")

        let adapter = try MediaPipeFaceLandmarkerAdapter(modelPath: modelPath, runningMode: .image)
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                print("[STILL] \(name) 読み込み失敗"); continue
            }
            let sets = adapter.allLandmarks(in: image)
            let rects = sets.map { set -> String in
                let xs = set.points.map { Double($0.x) }
                let ys = set.points.map { Double($0.y) }
                return String(format: "(%.2f,%.2f)-(%.2f,%.2f)",
                              xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
            }
            print("[STILL] \(name) n=\(sets.count) fullMesh=\(sets.filter(\.isFullMesh).count) "
                  + rects.joined(separator: " "))
            if !sets.isEmpty { dumpAnnotated(image, sets: sets, name: "still-\(name)") }
        }
    }
}
#endif
