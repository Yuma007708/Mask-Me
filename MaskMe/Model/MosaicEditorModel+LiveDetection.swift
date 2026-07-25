import AVFoundation
import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// `MosaicEditorModel` のライブ検出（再生フレームに相乗り）関連ロジック。
///
/// フェーズ2の地ならし（PR B Task B1）でロジックを変更せずにファイル分割したもの。
///
/// **注意（Swift の言語制約）**: `liveScanner` / `liveDetectionQueue` /
/// `liveDetectionInFlight` / `liveBucketFPS` / `liveMatchCounts` / `liveSampleCount` /
/// `liveFlowCache` は格納プロパティのため、この extension には物理的に移動できず
/// `MosaicEditorModel.swift`（本体）に残っている（Swift の extension は格納
/// インスタンスプロパティを持てない）。ここに移したのは、それらを参照する
/// 「振る舞い」（メソッド）だけである。
extension MosaicEditorModel {
    // MARK: - ライブ検出（再生フレームに相乗り）

    // 事前スキャンは廃止した。動画全編を先に検出するとフレーム数ぶんの MediaPipe 検出で
    // 実機で1〜2分待たされ、さらにスキャン用 AVAssetImageGenerator が再生用 AVPlayer と
    // ハードウェアデコーダを奪い合って途中で全滅していた（別デコーダの同時使用が原因）。
    // 代わりに、プレビューが既にデコード済みのフレームへ検出を相乗りさせ、再生しながら
    // detectionCache を埋める。検出は表示スレッドを塞がないよう常に1枚だけバックグラウンドで
    // 走らせ、再生中は最新フレームを間引く。エクスポートは未検出区間を自前でその場検出できる
    // ため、この変更で最終出力の品質は変わらない。
    // シークで時系列が巻き戻っても破綻しないよう、ライブ検出は IMAGE モードスキャナーを使う
    // （検出漏れフレームは DetectionBridge の両側補間でブリッジされる）。

    func liveBucket(_ timeSec: Double) -> Double {
        (timeSec * liveBucketFPS).rounded() / liveBucketFPS
    }

    /// プリスキャン（フル解像度・VIDEO モード）の 1 フレーム分の結果を検出キャッシュへ
    /// 記録する。`rawTime` は**合成時刻**で、入口で素材ID・素材時刻へ写像してから
    /// 記録する（丸めは写像の後。`resolveSourceTime` の doc 参照）。MainActor 上で呼ぶこと。
    ///
    /// - キーはライブ検出と同じ 15fps バケット（`DetectionCacheKey.init` の丸め）に
    ///   正規化される。プリスキャンループの `t += 1/15` 累積値をそのままキーにすると、
    ///   丸めで得たバケット値と最下位ビットで食い違い、ライブ検出が先に書いた低解像度
    ///   エントリ（誤検知含む）を上書きできずプレビュー・エクスポート両方に残り続ける。
    /// - 空結果も上書き記録する。フル解像度パイプラインの「顔なし」判定でライブ検出
    ///   （480px 簡易経路）の誤検知を消すため。空エントリは DetectionBridge が
    ///   無視するので追従率には影響せず、nearestCachedFaces のホールド抑止
    ///   （体への貼り付き防止）には効く。
    func storePreScanResult(_ faces: [FaceLandmarkSet], at rawTime: Double) {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: rawTime)
        cacheStore.store(faces, sourceID: sourceID, time: sourceTime)
    }

    /// テスト専用: 「この時刻（合成時刻）をスキャンしたが顔は無かった」状態を再現する。
    /// ライブ検出の空エントリ記録（storeLiveDetection）と同じ意味のキャッシュ状態を作る。
    func recordScannedEmptyForTesting(at timeSec: Double) {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: timeSec)
        cacheStore.store([], sourceID: sourceID, time: sourceTime)
    }

    /// 動画読み込み・顔追加時にライブ検出の集計状態をリセットする。
    ///
    /// **アクセスレベル変更**: 元は `private func` だったが、
    /// `load(videoURL:)` / `detectInRegion(_:)`（いずれも `MosaicEditorModel.swift`
    /// 本体側）から呼ばれるため `internal`（無印）にした。
    func resetLiveDetection() {
        liveMatchCounts = []
        liveSampleCount = 0
        liveDetectionInFlight = false
        // 意図的に scoped-clear（現在の sourceID だけ削除）にしない: `cacheStore` は
        // 素材ロードのたびにクリアされない設計だが、`liveFlowCache` は動画切替のたびに
        // フロー追跡状態ごと全消去する非対称は既存仕様。他素材のエントリが万一残っていても
        // 一緒に破棄して構わない。
        liveFlowCache.removeAll()
        // 別動画の時系列を追跡しないよう、scanner 側の track / flow 状態も破棄する
        liveDetectionQueue.async { [liveScanner] in
            liveScanner.resetLiveTracking()
        }
    }

    /// プレビューがこの**合成時刻**のフレームを検出すべきか（表示スレッドから安価に判定する）。
    /// 素材ID・素材時刻へ写像してからバケットの有無を見る。
    /// 既に同バケットを検出済み・検出中・顔タブOFF・写真モードのときはスキップ。
    func shouldDetectPreviewFrame(at timeSec: Double) -> Bool {
        guard mode == .video, faceMosaicOn, !liveDetectionInFlight else { return false }
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: timeSec)
        return !cacheStore.hasEntry(sourceID: sourceID, time: sourceTime)
    }

    /// プレビューのデコード済みフレーム（検出用に縮小済み CGImage）を受け取り、
    /// バックグラウンドで顔検出して detectionCache を埋める。
    /// `timeSec` は合成時刻。素材キーへの写像は書き込み側（`storeLiveDetection`）が
    /// 行うため、ここでは丸めも写像もせず生の合成時刻を持ち回る
    /// （合成時刻で先に丸めると rate≠1 でキーが分裂する。`resolveSourceTime` の doc 参照）。
    func submitPreviewFrameForDetection(_ cgImage: CGImage, at timeSec: Double) {
        guard !liveDetectionInFlight else { return }
        liveDetectionInFlight = true
        // submit 時点の世代トークンを閉じ込める。検出中にタイムライン編集が入ると、
        // この合成時刻は**旧タイムライン**のフレームを指しており、新しい写像で
        // 素材キーへ落とすと誤った素材時刻に正規の検出として記録されてしまう
        // （S3 レビューの観測事項）。書き込み側（世代チェック付き storeLiveDetection）
        // が照合して不一致なら破棄する。
        let generation = timelineGeneration
        liveDetectionQueue.async { [weak self, liveScanner] in
            let img = UIImage(cgImage: cgImage)
            // liveLandmarks は IMAGE 検出に加えてテンポラル ROI 再検出・フロー橋渡しで
            // 横顔・急な頭部回転を追跡する（再生ストリームの時系列＝合成時刻の生値を渡す:
            // 丸めると adapter 側のシーク不連続検知が鈍る）。
            let detection = liveScanner.liveLandmarks(in: img, atMediaSeconds: timeSec)
            Task { @MainActor in
                self?.storeLiveDetection(detection, at: timeSec, source: img, generation: generation)
            }
        }
    }

    /// 世代チェック付きの記録入口。`generation`（submit 時点の世代トークン）が現在の
    /// `timelineGeneration` と一致しない場合、結果を破棄する（旧タイムラインの合成時刻を
    /// 新しい写像で解釈すると誤った素材キーに落ちるため）。in-flight ガードだけは解除して
    /// 次のフレームの検出を止めない。
    @MainActor
    func storeLiveDetection(_ detection: LiveDetectionResult, at t: Double,
                            source: UIImage, generation: Int) {
        guard generation == timelineGeneration else {
            liveDetectionInFlight = false
            return
        }
        storeLiveDetection(detection, at: t, source: source)
    }

    /// シーク時にライブ追跡状態（ROI track / フロー）を破棄する。adapter 側の
    /// 時刻不連続の自動検知に対する明示リセットの二段構え。追跡状態は検出キュー上で
    /// しか触らない invariant を守るため、キュー経由で直列に実行する。
    func notifyLiveSeek() {
        liveDetectionQueue.async { [liveScanner] in
            liveScanner.resetLiveTracking()
        }
    }

    /// ライブ検出 1 フレーム分の結果を記録する。`t` は**合成時刻**で、素材キーへの
    /// 写像はここ（書き込みの入口）で行う。フロー橋渡し由来（bridgedByFlow）は
    /// 「実検出は無かった」事実を detectionCache に空で残しつつ、追跡位置を
    /// `liveFlowCache` に別置きする（エクスポート非汚染・検出率バッジ非算入・
    /// nearestCachedFaces の体貼り付き防止の意味論をすべて維持するため）。
    /// 両キャッシュとも**同じ写像済み素材キー**を使う（片方だけ合成時刻キーだと、
    /// lookupFaces の素材時刻検索から取り残される）。
    @MainActor
    func storeLiveDetection(_ detection: LiveDetectionResult, at t: Double, source: UIImage) {
        guard detection.bridgedByFlow else {
            storeLiveDetection(detection.faces, at: t, source: source)
            return
        }
        liveDetectionInFlight = false
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: t)
        cacheStore.store([], sourceID: sourceID, time: sourceTime)
        liveFlowCache[DetectionCacheKey(sourceID: sourceID, time: sourceTime, bucketFPS: liveBucketFPS)] =
            detection.faces
        #if DEBUG
        print("[MMLIVE] t=\(String(format: "%.2f", t)) flow faces=\(detection.faces.count)")
        #endif
        // 描画の重心マッチングが追跡位置と乖離しないよう位置だけ追従させる
        // （検出率 liveMatchCounts / liveSampleCount には算入しない）。
        updateFacePositions(with: detection.faces)
        previewController?.invalidate()
    }

    /// `detectedFaces` の位置を検出/追跡結果へ追従させる（検出率には触らない）。
    /// マッチング規則は storeLiveDetection の検出率ループと同一。
    @MainActor
    private func updateFacePositions(with faces: [FaceLandmarkSet]) {
        guard !faces.isEmpty else { return }
        for (i, target) in detectedFaces.enumerated() {
            let tc = normalizedCentroid(of: target.landmarks)
            guard let matched = faces.min(by: { a, b in
                let ac = normalizedCentroid(of: a), bc = normalizedCentroid(of: b)
                return hypot(ac.x - tc.x, ac.y - tc.y) < hypot(bc.x - tc.x, bc.y - tc.y)
            }) else { continue }
            let mc = normalizedCentroid(of: matched)
            let isSoleFacePair = detectedFaces.count == 1 && faces.count == 1
            if isSoleFacePair || hypot(mc.x - tc.x, mc.y - tc.y) < 0.5 {
                detectedFaces[i].landmarks = matched
            }
        }
    }

    /// internal: シナリオテスト（フレームアウト→イン・後ろ向き→正面・冒頭顔なし等）が
    /// ライブ検出の1フレーム分を直接注入して選択層まで含めて検証するための可視性。
    /// `t` は**合成時刻**（クリップ未構築のテスト注入では恒等フォールバックにより
    /// 従来どおり素材時刻と同値）。
    @MainActor
    func storeLiveDetection(_ faces: [FaceLandmarkSet], at t: Double, source: UIImage) {
        liveDetectionInFlight = false
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: t)
        #if DEBUG
        // 実機デバッグ用: ライブ検出が「どの時刻に・何件」乗ったかの証跡。
        // 「途中スタートでモザイクなし」等の報告時に、検出が走っていないのか
        // （このログ自体が出ない）、走ったが空なのか（faces=0）を切り分ける。
        print("[MMLIVE] t=\(String(format: "%.2f", t)) src=\(String(format: "%.2f", sourceTime)) "
              + "faces=\(faces.count) "
              + "targets=\(detectedFaces.count) sel=\(detectedFaces.filter(\.isSelected).count)")
        #endif
        // 空の結果も保存する。「スキャン済みで顔なし」という事実が残らないと、
        // lookupFaces のホールドフォールバックが古い顔位置をこのフレームに描き続けて
        // 「体にモザイクが乗る／モザイクがずれる」誤描画になる。また、空を記録する
        // ことで shouldDetectPreviewFrame が同じ顔なしフレームを再スキャンし続ける
        // 無駄も止まる（DetectionBridge / nearestCachedFaces は空エントリを無視する）。
        cacheStore.store(faces, sourceID: sourceID, time: sourceTime)
        // ポーズ中のシーク先で検出が終わったとき、次の displayLink を待たずに
        // モザイクを反映する（再生中は毎フレーム描画されるので実質無害）。
        previewController?.invalidate()
        guard !faces.isEmpty else { return }

        // 先頭フレーム検出が失敗して顔候補が空だった場合の安全網。
        // load(videoURL:) の初期スキャンと同じ自動選択規則を適用する: 顔が 1 つなら
        // タップ不要で即モザイク。isSelected: false のままだと「冒頭に顔が写らない
        // 動画（後ろ向きスタート等）では最後まで一切モザイクが掛からない」になる。
        if detectedFaces.isEmpty {
            detectedFaces = faces.enumerated().map { idx, lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           thumbnail: generateThumbnail(for: lm, from: source),
                           isSelected: faces.count == 1 && idx == 0,
                           sourceID: sourceID)
            }
        }

        // 検出率%を再生しながら育てる（各顔が見つかったフレームの割合）。
        liveSampleCount += 1
        while liveMatchCounts.count < detectedFaces.count { liveMatchCounts.append(0) }
        for (i, target) in detectedFaces.enumerated() {
            let tc = normalizedCentroid(of: target.landmarks)
            if let matched = faces.min(by: { a, b in
                let ac = normalizedCentroid(of: a), bc = normalizedCentroid(of: b)
                return hypot(ac.x - tc.x, ac.y - tc.y) < hypot(bc.x - tc.x, bc.y - tc.y)
            }) {
                let mc = normalizedCentroid(of: matched)
                // 単一ターゲット × 単一検出のときは距離条件を課さない（同一人物とみなす）。
                // フレームアウト→反対側から再インすると距離 0.5 を超え、位置追従だけでは
                // 永久に再マッチできないため、この再捕捉規則が無いと「一度外れたら戻らない」。
                let isSoleFacePair = detectedFaces.count == 1 && faces.count == 1
                if isSoleFacePair || hypot(mc.x - tc.x, mc.y - tc.y) < 0.5 {
                    liveMatchCounts[i] += 1
                    // ターゲット位置を最新の検出位置へ追従させる。顔追加時の初期位置の
                    // まま固定すると、selectedLandmarks の重心マッチングが「移動した顔・
                    // フレームアウト→別位置で再インした顔」と永久にマッチしなくなる。
                    detectedFaces[i].landmarks = matched
                }
            }
            detectedFaces[i].detectionRate =
                Double(liveMatchCounts[i]) / Double(liveSampleCount) * 100
        }
    }

    /// `nearestFlowFaces(sourceID:sourceTime:)` の合成時刻版。入口で素材ID・素材時刻へ
    /// 写像する（テストの直接呼び出しはクリップ未構築の恒等フォールバックで従来と同値）。
    func nearestFlowFaces(at time: Double) -> [FaceLandmarkSet] {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: time)
        return nearestFlowFaces(sourceID: sourceID, sourceTime: sourceTime)
    }

    /// `liveFlowCache` のうち素材時刻 `sourceTime` から±1バケット強（0.1s）以内で
    /// 最も近い顔リスト。指定素材のエントリのみを対象にする（他素材混入防止）。
    ///
    /// **アクセスレベル**: `lookupFaces`（`MosaicEditorModel+DetectionCache.swift`）
    /// から写像済みの素材ID・素材時刻で呼ばれるため `internal`（無印）。
    func nearestFlowFaces(sourceID: UUID, sourceTime: Double) -> [FaceLandmarkSet] {
        var best: (dist: Double, faces: [FaceLandmarkSet])?
        for (key, faces) in liveFlowCache where key.sourceID == sourceID && !faces.isEmpty {
            let d = abs(key.bucket - sourceTime)
            if d > 1.5 / liveBucketFPS { continue }
            if best == nil || d < best!.dist { best = (d, faces) }
        }
        return best?.faces ?? []
    }

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
