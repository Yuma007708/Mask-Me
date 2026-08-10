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
    ///
    /// **トランジションの重なり区間では検出しない**（S8）。プレビューが持っている
    /// フレームは 2 クリップを合成した画（フェード・スライド・ワイプの途中）であり、
    /// そこで検出した顔位置は素材フレームのどちらの座標系にも属さない。素材キーで
    /// 書き込むと検出キャッシュが汚染され、エクスポート（キャッシュヒットで検出を
    /// スキップする）まで巻き添えになる。重なり区間の顔は両側のキャッシュを
    /// `displayFaces(at:)` が写像・union して賄う。
    ///
    /// **モザイク適用区間のゲートをここに入れてはならない（S10）。** 区間外でもライブ検出は
    /// 継続して検出キャッシュを埋めるのが設計であり、止めると「後から区間を広げたときに
    /// 再検出が要る」ことになる。この契約は
    /// `TimelineEditingModelTests.test_shouldDetectPreviewFrame_ignoresApplyRangeGate` が
    /// 固定している（冒頭に `guard isMosaicActive(...)` を足すと落ちる）。
    func shouldDetectPreviewFrame(at timeSec: Double) -> Bool {
        guard mode == .video, faceMosaicOn, !liveDetectionInFlight else { return false }
        guard mapping.sourceLocations(at: timeSec).count < 2 else { return false }
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: timeSec)
        return !cacheStore.hasEntry(sourceID: sourceID, time: sourceTime)
    }

    /// プレビューのデコード済みフレーム（検出用に縮小済み CGImage）を受け取り、
    /// バックグラウンドで顔検出して detectionCache を埋める。
    /// `timeSec` は合成時刻。素材キーへの写像は書き込み側（`storeLiveDetection`）が
    /// 行うため、ここでは丸めも写像もせず生の合成時刻を持ち回る
    /// （合成時刻で先に丸めると rate≠1 でキーが分裂する。`resolveSourceTime` の doc 参照）。
    ///
    /// - Parameter signatureSource: 原寸フレームの取り出し口。**署名を測るフレームだけ**
    ///   評価され、評価は `liveSignatureQueue`（検出とは別のキュー）で行う。
    ///   なぜ原寸が要るかは
    ///   `FaceSignatureProvider.signatures(for:detection:native:)` の doc、
    ///   なぜ検出キューから外すかは `liveSignatureQueue` の doc 参照。
    func submitPreviewFrameForDetection(_ cgImage: CGImage, at timeSec: Double,
                                        signatureSource: (() -> CGImage?)? = nil) {
        guard !liveDetectionInFlight else { return }
        liveDetectionInFlight = true
        // submit 時点の世代トークンを閉じ込める。検出中にタイムライン編集が入ると、
        // この合成時刻は**旧タイムライン**のフレームを指しており、新しい写像で
        // 素材キーへ落とすと誤った素材時刻に正規の検出として記録されてしまう
        // （S3 レビューの観測事項）。書き込み側（世代チェック付き storeLiveDetection）
        // が照合して不一致なら破棄する。
        let generation = timelineGeneration
        // 署名を計算するかは**この時点**で決める（推論はバックグラウンドで走るので、
        // 判断を後ろへ回すと間引きが効かない）。フロー橋渡し由来の顔は実検出ではないため、
        // 計算するかどうかは検出結果を見てから最終判断する（下の `wantsSignatures &&`）。
        let wantsSignatures = beginSignatureIntervalIfDue(atComposition: timeSec)
        liveDetectionQueue.async { [weak self, liveScanner] in
            let img = UIImage(cgImage: cgImage)
            // liveLandmarks は IMAGE 検出に加えてテンポラル ROI 再検出・フロー橋渡しで
            // 横顔・急な頭部回転を追跡する（再生ストリームの時系列＝合成時刻の生値を渡す:
            // 丸めると adapter 側のシーク不連続検知が鈍る）。
            let detection = liveScanner.liveLandmarks(in: img, atMediaSeconds: timeSec)
            // 検出結果は**署名を待たずに**記録する。in-flight ガードもここで下りるので、
            // 次のフレームの検出は署名の完了に引っ張られない（`liveSignatureQueue` の doc）。
            Task { @MainActor in
                self?.storeLiveDetection(detection, at: timeSec, source: img,
                                         generation: generation)
            }
            // 署名（原寸の取り出し + SFace 推論）は別キューで後から追いつく。
            guard wantsSignatures, !detection.bridgedByFlow, !detection.faces.isEmpty
            else { return }
            self?.liveSignatureQueue.async { [weak self] in
                let signatures = FaceSignatureProvider.shared.signatures(
                    for: detection.faces, detection: img, native: { signatureSource?() })
                Task { @MainActor in
                    self?.storeLiveSignatures(signatures, for: detection.faces,
                                              at: timeSec, frame: img, generation: generation)
                }
            }
        }
    }

    /// 世代チェック付きの記録入口。`generation`（submit 時点の世代トークン）が現在の
    /// `timelineGeneration` と一致しない場合、結果を破棄する（旧タイムラインの合成時刻を
    /// 新しい写像で解釈すると誤った素材キーに落ちるため）。in-flight ガードだけは解除して
    /// 次のフレームの検出を止めない。
    @MainActor
    func storeLiveDetection(_ detection: LiveDetectionResult, at t: Double,
                            source: UIImage, signatures: [FaceSignature?]? = nil,
                            generation: Int) {
        guard generation == timelineGeneration else {
            liveDetectionInFlight = false
            return
        }
        storeLiveDetection(detection, at: t, source: source, signatures: signatures)
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
    ///
    /// **座標系（最重要）**: 引数の顔は**合成フレーム基準**（プレビューは
    /// `videoComposition` 装着済みフレームをデコードする）。キャッシュは素材基準なので、
    /// 書く前に `renderLayout.inverseRemap` で必ず戻す。戻さないと描画・書き出しで
    /// `remap` がもう一度掛かって二重にずれ、顔が素通しになる。
    @MainActor
    func storeLiveDetection(_ detection: LiveDetectionResult, at t: Double, source: UIImage,
                            signatures: [FaceSignature?]? = nil) {
        guard detection.bridgedByFlow else {
            storeLiveDetection(detection.faces, at: t, source: source, signatures: signatures)
            return
        }
        liveDetectionInFlight = false
        let resolved = resolveSourceLocation(atComposition: t)
        let sourceID = resolved.sourceID
        let sourceTime = resolved.time
        // 合成 → 素材。`liveFlowCache` も `cacheStore` と同じ座標系でなければならない
        // （`lookupFaces` は両者を同列に返し、呼び出し側は区別せず `remap` を掛ける）。
        let sourceFaces = renderLayout.inverseRemap(detection.faces, clipID: resolved.clipID)
        cacheStore.store([], sourceID: sourceID, time: sourceTime)
        liveFlowCache[DetectionCacheKey(sourceID: sourceID, time: sourceTime, bucketFPS: liveBucketFPS)] =
            sourceFaces
        #if DEBUG
        print("[MMLIVE] t=\(String(format: "%.2f", t)) flow faces=\(detection.faces.count)")
        #endif
        // 描画の重心マッチングが追跡位置と乖離しないよう位置だけ追従させる
        // （検出率 liveMatchCounts / liveSampleCount には算入しない）。**素材座標**を渡す。
        updateFacePositions(with: sourceFaces)
        previewController?.invalidate()
    }

    /// `detectedFaces` の位置を検出/追跡結果へ追従させる（検出率には触らない）。
    /// マッチング規則は storeLiveDetection の検出率ループと同一。
    ///
    /// **`faces` は素材フレーム基準で渡すこと。** `displayFaces(at:matching:)`
    /// （`MosaicEditorModel+DetectionCache.swift`）が「絞り込みは素材座標のまま、写像より
    /// 前に行う」と定めている。合成座標を混ぜるとレターボックスぶん（実測で最大 0.175）
    /// ずれ、選択した顔が照合できず**モザイクが乗らない**。
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
    ///
    /// **`faces` は合成フレーム基準**（`source` 画像と同じ座標系）。素材基準への逆写像は
    /// ここで行う。恒等レイアウトでは `inverseRemap` が値をそのまま返す（挙動不変）。
    @MainActor
    func storeLiveDetection(_ faces: [FaceLandmarkSet], at t: Double, source: UIImage,
                            signatures: [FaceSignature?]? = nil) {
        liveDetectionInFlight = false
        let resolved = resolveSourceLocation(atComposition: t)
        let sourceID = resolved.sourceID
        let sourceTime = resolved.time
        // 合成 → 素材。**キャッシュ・署名・`detectedFaces` はすべて素材座標**で、
        // サムネイル生成だけが `source`（合成フレーム）座標を要る。`inverseRemap` は
        // 件数も順序も変えないので `faces` / `signatures` と添字は一致する。
        let sourceFaces = renderLayout.inverseRemap(faces, clipID: resolved.clipID)
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
        cacheStore.store(sourceFaces, sourceID: sourceID, time: sourceTime)
        // 署名は顔と**同じ瞬間・同じキー**でしか書かない（添字がずれると別人の署名で
        // 判定してしまう）。件数が合わない呼び出しは `FaceSignatureCache` 側が弾く。
        // 署名は**素材座標の顔**に結ぶ（`FaceSignatureSample.centroid` の doc どおり）。
        if let signatures {
            signatureCache.store(signatures, for: sourceFaces, sourceID: sourceID, time: sourceTime)
        }
        // ポーズ中のシーク先で検出が終わったとき、次の displayLink を待たずに
        // モザイクを反映する（再生中は毎フレーム描画されるので実質無害）。
        previewController?.invalidate()
        guard !sourceFaces.isEmpty else { return }

        // 先頭フレーム検出が失敗して顔候補が空だった場合の安全網。
        // load(videoURL:) の初期スキャンと同じ自動選択規則を適用する: 顔が 1 つなら
        // タップ不要で即モザイク。isSelected: false のままだと「冒頭に顔が写らない
        // 動画（後ろ向きスタート等）では最後まで一切モザイクが掛からない」になる。
        if detectedFaces.isEmpty {
            detectedFaces = sourceFaces.enumerated().map { idx, lm in
                FaceTarget(id: UUID(), landmarks: lm,
                           // サムネイルは `source`（**合成フレーム**）から切り出すので
                           // 逆写像**前**の顔を渡す（素材座標だとずれた場所を切り出す）。
                           thumbnail: generateThumbnail(for: faces[idx], from: source),
                           isSelected: sourceFaces.count == 1 && idx == 0,
                           sourceID: sourceID)
            }
        }

        // 検出率%を再生しながら育てる（各顔が見つかったフレームの割合）。
        liveSampleCount += 1
        while liveMatchCounts.count < detectedFaces.count { liveMatchCounts.append(0) }
        for (i, target) in detectedFaces.enumerated() {
            let tc = normalizedCentroid(of: target.landmarks)
            // 照合は**素材座標同士**（閾値 0.5 は素材座標で調整されてきた値）。
            if let matchedIndex = sourceFaces.indices.min(by: { a, b in
                let ac = normalizedCentroid(of: sourceFaces[a]), bc = normalizedCentroid(of: sourceFaces[b])
                return hypot(ac.x - tc.x, ac.y - tc.y) < hypot(bc.x - tc.x, bc.y - tc.y)
            }) {
                let matched = sourceFaces[matchedIndex]
                let mc = normalizedCentroid(of: matched)
                // 単一ターゲット × 単一検出のときは距離条件を課さない（同一人物とみなす）。
                // フレームアウト→反対側から再インすると距離 0.5 を超え、位置追従だけでは
                // 永久に再マッチできないため、この再捕捉規則が無いと「一度外れたら戻らない」。
                let isSoleFacePair = detectedFaces.count == 1 && sourceFaces.count == 1
                if isSoleFacePair || hypot(mc.x - tc.x, mc.y - tc.y) < 0.5 {
                    liveMatchCounts[i] += 1
                    // ターゲット位置を最新の検出位置へ追従させる。顔追加時の初期位置の
                    // まま固定すると、selectedLandmarks の重心マッチングが「移動した顔・
                    // フレームアウト→別位置で再インした顔」と永久にマッチしなくなる。
                    detectedFaces[i].landmarks = matched
                    // マッチした顔の署名だけを人物 ID へ育てる。マッチしなかった
                    // （距離 0.5 以上離れた）顔の署名をここで混ぜると、隣の人の
                    // 手本がこの人物に混入する。
                    if let signature = signatures?[matchedIndex] {
                        assignPerson(signature, toTargetAt: i)
                    }
                }
            }
            detectedFaces[i].detectionRate =
                Double(liveMatchCounts[i]) / Double(liveSampleCount) * 100
        }
    }

    /// 署名を台帳へ入れ、ターゲットに人物 ID を結び付ける。
    ///
    /// - 既に人物 ID が付いているターゲットは、その人物へ手本を足すだけにする
    ///   （`register` に任せると、向きが変わって類似度が落ちた瞬間に**別人として
    ///   新規登録**され、同じ人が一覧で 2 人に割れる）。
    /// - まだ付いていないターゲットだけ `register` に判断させる。判断保留の帯
    ///   （`distinct` 〜 `match`）では nil が返り、人物 ID は付かないまま
    ///   ＝位置追跡と安全側（隠す）に委ねられる。
    ///
    /// 初期スキャンのシードは対応する `seedPersonIDs`
    /// （`MosaicEditorModel+TimelineMedia.swift`）を使う。あちらは `detectedFaces` へ
    /// 載せる前に人物 ID を決める必要があり、ターゲットの添字を取れない。
    @MainActor
    private func assignPerson(_ signature: FaceSignature, toTargetAt index: Int) {
        if let existing = detectedFaces[index].personID {
            personRegistry.addExemplar(signature, toPersonWith: existing)
            return
        }
        detectedFaces[index].personID = personRegistry.register(signature)
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
}

#endif
