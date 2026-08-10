import XCTest
import AVFoundation
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(MediaPipeTasksVision)

/// 診断専用: 実機プレビューのライブ検出と完全に同じ条件
/// （IMAGE モードスキャナー + 480px 幅縮小フレーム）で
/// RPReplay_Final1767530678.MP4 の 0〜10 秒をフレーム毎にダンプする。
/// 「3秒あたりで顔モザイク消失」「7秒あたりで体モザイク」の証拠収集用。
final class DiagLivePathDumpTests: XCTestCase {
    private var sampleDir: String {
        ProcessInfo.processInfo.environment["SAMPLE_DIR"] ?? "/Users/tatsuki/Downloads/サンプル"
    }

    /// 切り分け: 検出解像度 × 補助検出器 ON/OFF の組み合わせで
    /// 「顔ミス（2.9s〜）」と「体誤検知（y>0.4 の巨大bbox）」がどう変わるかを見る。
    func test_Diag_RPReplay1767530678_configMatrix() async throws {
        let url = URL(fileURLWithPath: "\(sampleDir)/RPReplay_Final1767530678.MP4")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "動画なし")

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.034, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.034, preferredTimescale: 600)

        // (ラベル, 検出幅px[0=フル], aux ON?)
        let configs: [(String, Double, Bool)] = [
            ("480-aux", 480, true),
            ("480-noaux", 480, false),
            ("720-aux", 720, true),
            ("960-aux", 960, true),
            ("full-aux", 0, true)
        ]
        for (label, width, aux) in configs {
            var settings = DetectionSettings()
            settings.useFaceDetector = aux
            settings.useYunet = aux
            let scanner = makeFaceLandmarker(forVideo: false, settings: settings)
            var frames = 0, hits = 0, bodyFP = 0
            var t = 0.0
            let endTime = min(duration, 10.0)
            while t <= endTime {
                autoreleasepool {
                    guard let cg = try? gen.copyCGImage(
                        at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                    ) else { return }
                    let img = width > 0 ? downscale(cg, targetWidth: width) : cg
                    let faces = scanner.allLandmarks(in: UIImage(cgImage: img))
                    frames += 1
                    // 本物の顔: この動画では 0-10s のあいだ y<0.4 かつ w<0.4 の帯に居る。
                    let real = faces.filter { $0.boundingBox.minY < 0.40 && $0.boundingBox.width < 0.40 }
                    let fp = faces.filter { $0.boundingBox.minY >= 0.40 || $0.boundingBox.width >= 0.45 }
                    if !real.isEmpty { hits += 1 }
                    bodyFP += fp.count
                }
                t += 1.0 / 15.0
            }
            fputs(String(format: "[MATRIX] %@ frames=%d realHits=%d rate=%.2f bodyFP=%d\n",
                         label, frames, hits, Double(hits) / Double(max(1, frames)), bodyFP), stderr)
        }
    }

    func test_Diag_RPReplay1767530678_livePathDump() async throws {
        let url = URL(fileURLWithPath: "\(sampleDir)/RPReplay_Final1767530678.MP4")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "動画なし")

        // 実機ライブ検出と同一: IMAGE モード + デフォルト設定（FD+YuNet ON）
        let settings = DetectionSettings()
        let scanner = makeFaceLandmarker(forVideo: false, settings: settings)

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.034, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.034, preferredTimescale: 600)

        var cache: [Double: [FaceLandmarkSet]] = [:]
        let interval = 1.0 / 15.0
        var t = 0.0
        let endTime = min(duration, 10.0)
        while t <= endTime {
            autoreleasepool {
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
                ) else {
                    fputs(String(format: "[DIAG] t=%.3f FRAME-FAIL\n", t), stderr)
                    return
                }
                // 実機と同じ幅へ縮小してから検出する。**直書きしないこと**
                // （480 と書かれていた頃、本体は既に 640 だった）。
                // すぐ上の `configMatrix` が 480/720/960 を直に並べているのは、
                // あちらが解像度そのものを比較する診断だから。
                let scaled = downscale(cg, targetWidth: MosaicEditorModel.liveDetectionTargetWidth)
                let faces = scanner.allLandmarks(in: UIImage(cgImage: scaled))
                let bucket = (t * 15.0).rounded() / 15.0
                cache[bucket] = faces
                var desc = faces.map { f -> String in
                    let bb = f.boundingBox
                    return String(format: "bbox(x=%.2f,y=%.2f,w=%.2f,h=%.2f,ar=%.2f,area=%.3f,conf=%.2f)",
                                  bb.minX, bb.minY, bb.width, bb.height,
                                  bb.height / max(bb.width, 0.001),
                                  bb.width * bb.height, f.confidence)
                }.joined(separator: " ")
                if desc.isEmpty { desc = "EMPTY" }
                fputs(String(format: "[DIAG] t=%.3f n=%d %@\n", t, faces.count, desc), stderr)
            }
            t += interval
        }

        // 描画経路のシミュレーション: 上記キャッシュに対して lookupFaces と同じロジック
        // （DetectionBridge 補間 → 0.75s 最寄りホールド）で描画結果を出す。
        fputs("[DIAG] ---- render simulation ----\n", stderr)
        var rt = 0.0
        while rt <= endTime {
            let bridged = DetectionBridge(interpolates: true).faces(in: cache, at: rt)
            let drawn: [FaceLandmarkSet]
            var via = "bridge"
            if bridged.isEmpty {
                var best: (dist: Double, faces: [FaceLandmarkSet])?
                for (ct, faces) in cache {
                    let d = abs(ct - rt)
                    if d > 0.75 { continue }
                    if best == nil || d < best!.dist { best = (d, faces) }
                }
                drawn = best?.faces ?? []
                via = "hold"
            } else {
                drawn = bridged
            }
            let desc = drawn.map { f -> String in
                let bb = f.boundingBox
                return String(format: "bbox(x=%.2f,y=%.2f,w=%.2f,h=%.2f)",
                              bb.minX, bb.minY, bb.width, bb.height)
            }.joined(separator: " ")
            fputs(String(format: "[DRAW] t=%.3f n=%d via=%@ %@\n",
                         rt, drawn.count, via, desc), stderr)
            rt += interval
        }
    }

    private func downscale(_ cg: CGImage, targetWidth: Double) -> CGImage {
        let scale = min(targetWidth / Double(cg.width), 1.0)
        guard scale < 0.99 else { return cg }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        return ctx.createCGImage(ci, from: ci.extent) ?? cg
    }
}

#endif
