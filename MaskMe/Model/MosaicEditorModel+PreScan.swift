import AVFoundation
import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// 旧・事前スキャン（動画全編を先に検出する経路）。
///
/// **現在この関数を呼ぶ経路は無い**（ライブ検出＝再生フレームへの相乗りに置き換え済み。
/// 経緯は `MosaicEditorModel+LiveDetection.swift` 冒頭のコメント参照）。
/// `ObjectMaskTracker` が「再生中はハードウェアデコーダを AVPlayer へ明け渡す」
/// 待ち合わせの手本としてここを参照しているため、実装は残してある。
///
/// `MosaicEditorModel+LiveDetection.swift` が `file_length` を超えたため、
/// **ロジックを一切変えずに**そのまま切り出したもの。
extension MosaicEditorModel {
    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    nonisolated private func runPreScan(
        asset: AVAsset,
        scanner: FaceLandmarking,
        cropScanner: FaceLandmarking,
        expectedFaceCount: Int,
        cropRects: [CGRect] = []
    ) async {
        let dur: Double
        do { dur = try await asset.load(.duration).seconds } catch {
            print("[MMSCAN] EARLY-RETURN: duration load failed: \(error)")
            return
        }
        print("[MMSCAN] start dur=\(dur) expectedFaces=\(expectedFaceCount) cropRects=\(cropRects.count)")
        guard dur > 0 else {
            print("[MMSCAN] EARLY-RETURN: dur<=0 (\(dur))")
            return
        }

        let interval = 1.0 / 15.0   // 15fps（動きの速い顔と短時間アウトインの追従向上）
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval, preferredTimescale: 600)

        var sampleCount = 0
        var matchCounts = [Int](repeating: 0, count: max(expectedFaceCount, 1))

        var t = 0.0
        while t <= dur {
            guard !Task.isCancelled else { return }
            // 再生中はハードウェアデコーダをプレビュー(AVPlayer)に明け渡す。スキャン用
            // AVAssetImageGenerator と同時にデコーダを奪い合うと、実機では数秒後から
            // copyCGImage が nil を返し続けスキャンが全滅する（再生していなければ最後まで
            // 通ることを実機ログで確認済み）。再生が止まったら中断地点から自然に再開する。
            while await MainActor.run(body: { [weak self] in self?.isPlaying ?? false }) {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            // 各フレームで AVFoundation / MediaPipe が生成する autorelease 中間バッファを
            // 毎フレーム解放する。これが無いと full-res フレーム（例: 588×1280）と検出中間
            // バッファが蓄積し、実機のハードウェアデコーダがメモリ圧で失敗して copyCGImage が
            // 数秒後から nil を返し始め、スキャンが途中で全滅する（キャッシュが冒頭数秒しか
            // 埋まらず、再生時にほぼモザイクが出ない）。CI/DValidVideoTests は autoreleasepool を
            // 使っているためこの症状は再現しない。
            let frame: (faces: [FaceLandmarkSet], img: UIImage)? = autoreleasepool {
                let cg: CGImage
                do {
                    cg = try generator.copyCGImage(at: cmTime, actualTime: nil)
                } catch {
                    let ns = error as NSError
                    print("[MMSCAN] t=\(String(format: "%.2f", t)) copyCGImage=NIL domain=\(ns.domain) " +
                          "code=\(ns.code) desc=\(ns.localizedDescription)")
                    return nil
                }
                let img = UIImage(cgImage: cg)
                // video モードで temporal tracking を活用しながら検出
                var faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                if sampleCount < 10 || sampleCount % 15 == 0 {
                    print("[MMSCAN] t=\(String(format: "%.2f", t)) sample=\(sampleCount) faces=\(faces.count) " +
                          "imgPx=\(cg.width)x\(cg.height)")
                }

                // ManualRegion の矩形クロップでも検出を試みる（小さい顔や検出しにくい顔への対応）
                // クロップは image モードスキャナーを使用（video モードの timestamp 系列を保護）
                for rect in cropRects {
                    let pixelRect = CGRect(
                        x: rect.origin.x * CGFloat(cg.width),
                        y: rect.origin.y * CGFloat(cg.height),
                        width: rect.width  * CGFloat(cg.width),
                        height: rect.height * CGFloat(cg.height)
                    )
                    if let crop = cg.cropping(to: pixelRect) {
                        let cropFaces = cropScanner.allLandmarks(in: UIImage(cgImage: crop))
                        faces += cropFaces.map { $0.remapped(into: rect) }
                    }
                }
                return (faces, img)
            }
            guard let frame else { t += interval; continue }
            let faces = frame.faces
            let img = frame.img

            sampleCount += 1
            let facesForCache = faces
            let timeForCache = t
            let matchCountsCopy = matchCounts
            let updated = await MainActor.run { [weak self, img] () -> [Int] in
                self?.storePreScanResult(facesForCache, at: timeForCache)
                guard let self else { return matchCountsCopy }
                // 初期フレーム検出が失敗して detectedFaces が空のまま残っている場合、
                // プリスキャンで最初に見つかった顔を補完する（安全網）。
                if !facesForCache.isEmpty && self.detectedFaces.isEmpty {
                    // storeLiveDetection の安全網と同じ自動選択規則（単一顔なら即モザイク）。
                    // プリスキャンは現在ロード中の素材全体を舐める前提の旧経路なので
                    // 素材IDは currentSourceID 固定で良い。
                    self.detectedFaces = facesForCache.enumerated().map { idx, lm in
                        FaceTarget(id: UUID(), landmarks: lm,
                                   thumbnail: self.generateThumbnail(for: lm, from: img),
                                   isSelected: facesForCache.count == 1 && idx == 0,
                                   sourceID: self.currentSourceID)
                    }
                }
                var counts = matchCountsCopy
                // detectedFaces がプリスキャン中に安全網で追加された場合に備えて配列を拡張する
                while counts.count < self.detectedFaces.count { counts.append(0) }
                for (i, target) in self.detectedFaces.enumerated() {
                    let tc = self.normalizedCentroid(of: target.landmarks)
                    if facesForCache.contains(where: { face in
                        let fc = self.normalizedCentroid(of: face)
                        return hypot(fc.x - tc.x, fc.y - tc.y) < 0.5
                    }) {
                        counts[i] += 1
                    }
                }
                return counts
            }
            matchCounts = updated
            t += interval
        }

        let finalSampleCount = sampleCount
        let finalMatchCounts = matchCounts
        await MainActor.run { [weak self] in
            guard let self else { return }
            print("[MMSCAN] DONE samples=\(finalSampleCount) cacheEntries=\(self.cacheStore.count) " +
                  "detectedFaces=\(self.detectedFaces.count)")
            if finalSampleCount > 0 {
                for i in 0..<min(finalMatchCounts.count, self.detectedFaces.count) {
                    self.detectedFaces[i].detectionRate =
                        Double(finalMatchCounts[i]) / Double(finalSampleCount) * 100
                }
            }
            self.isScanning = false
        }
    }
}

#endif
