import AVFoundation
import XCTest
import MosaicCore
@testable import MaskMe

/// プリスキャンとライブ検出の検出キャッシュ整合性テスト。
///
/// ライブ検出（480px 簡易経路）とプリスキャン（フル解像度）は同じ
/// `detectionCache` を共有する。プリスキャンの書き込みキーがライブ検出の
/// 15fps バケットと一致しない・空結果を記録しないと、ライブ側の低品質
/// エントリ（誤検知含む）が本スキャン後も残り続け、プレビューと
/// エクスポートの精度低下として現れる（回帰: 累積加算キーのビットずれ）。
@MainActor
final class DetectionCacheSyncTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

    /// `AVAsset` は抽象クラスなので `AVAsset()` は実行時クラッシュする
    /// （`AVURLAsset` 等の具象サブクラスが要る）。実素材へアクセスしないテストでは
    /// これをダミーとして使い回す。
    private func dummyAsset() -> AVAsset {
        AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
    }

    private func fakeFace(cx: Double, cy: Double, size: Double = 0.2) -> FaceLandmarkSet {
        let half = size / 2
        let points = [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    /// プリスキャンループの `t += 1/15` 累積値は浮動小数の丸めで
    /// バケット値と最下位ビットがずれる。storePreScanResult がキーを
    /// 正規化しないと「ライブの空エントリ」と「プリスキャンの顔」が
    /// 別キーで共存し、そのバケットの exact 参照が空を返し続ける。
    func test_preScanResultOverwritesLiveEntry_despiteAccumulatedKeyDrift() {
        let model = makeModel()
        // 100 ステップぶん加算を累積した「プリスキャンの生の t」
        var accumulated = 0.0
        let interval = 1.0 / 15.0
        for _ in 0..<100 { accumulated += interval }
        let bucketTime = model.liveBucket(accumulated)

        // ライブ検出が先に「スキャン済み・顔なし」を記録している状況
        model.recordScannedEmptyForTesting(at: bucketTime)
        // プリスキャンが同じ時刻をフル解像度で走査して顔を見つけた
        model.storePreScanResult([fakeFace(cx: 0.5, cy: 0.3)], at: accumulated)

        XCTAssertEqual(model.cacheStore.count, 1,
                       "キーが正規化されず別エントリとして共存している")
        XCTAssertFalse(model.lookupFaces(at: bucketTime).isEmpty,
                       "プリスキャンの顔がライブの空エントリを上書きできていない")
    }

    /// フル解像度パイプラインの「顔なし」判定は、ライブ検出（480px）の
    /// 誤検知エントリを空で上書きして消せること。消せないと誤検知の
    /// モザイクが本スキャン後もプレビュー・エクスポートに残る。
    func test_preScanEmptyResultClearsLiveFalsePositive() {
        let model = makeModel()
        let bucketTime = model.liveBucket(2.0)

        // ライブ検出の誤検知（体を顔として拾った想定）が先に入っている
        model.storePreScanResult([fakeFace(cx: 0.5, cy: 0.8, size: 0.6)], at: bucketTime)
        XCTAssertFalse(model.lookupFaces(at: bucketTime).isEmpty)

        // プリスキャン（累積 t、同一バケット）は「顔なし」と判定した
        model.storePreScanResult([], at: bucketTime + 1e-12)

        XCTAssertTrue(model.lookupFaces(at: bucketTime).isEmpty,
                      "空結果で誤検知エントリを消せていない")
        // 0.75 秒ホールドも空エントリで止まること（体への貼り付き防止）
        XCTAssertTrue(model.lookupFaces(at: bucketTime + 0.3).isEmpty,
                      "近傍ホールドが消したはずの誤検知を復活させている")
    }

    /// 瞬き・モーションブラーで 1〜2 バケットだけ検出が落ちたとき、再生 1 周目
    /// （未来側の検出が無く DetectionBridge が効かない状態）でもモザイクが
    /// 消えないこと。実機報告の「瞬きでモザイクが外れる」の回帰テスト。
    func test_blinkDropoutIsBridgedOnFirstPlaythrough() {
        let model = makeModel()
        let t0 = model.liveBucket(1.0)
        let step = 1.0 / 15.0

        // t0 で顔検出 → 直後 2 バケットが瞬きで「スキャン済み・顔なし」
        model.storePreScanResult([fakeFace(cx: 0.5, cy: 0.3)], at: t0)
        model.recordScannedEmptyForTesting(at: t0 + step)
        model.recordScannedEmptyForTesting(at: t0 + 2 * step)

        XCTAssertFalse(model.lookupFaces(at: t0 + step).isEmpty,
                       "瞬きの単発検出落ちでモザイクが消えている")
        XCTAssertFalse(model.lookupFaces(at: t0 + 2 * step).isEmpty,
                       "瞬き 2 バケット目でモザイクが消えている")
    }

    /// 瞬きホールドは短時間限定であること。顔が本当にフレームアウトした長い
    /// 顔なし区間では従来どおり空を返し、体・背景への貼り付きを起こさない。
    func test_blinkHoldDoesNotStickAfterFaceLeavesFrame() {
        let model = makeModel()
        let t0 = model.liveBucket(1.0)
        let step = 1.0 / 15.0

        model.storePreScanResult([fakeFace(cx: 0.5, cy: 0.3)], at: t0)
        // 0.067s 〜 1.0s まで顔なしが続く（フレームアウト想定）
        for i in 1...15 {
            model.recordScannedEmptyForTesting(at: t0 + Double(i) * step)
        }

        XCTAssertTrue(model.lookupFaces(at: t0 + 0.5).isEmpty,
                      "ホールド窓（0.25s）を超えても古い顔位置を描き続けている")
        XCTAssertTrue(model.lookupFaces(at: t0 + 1.0).isEmpty)
    }

    // MARK: - mapping（TimelineMapping。S3 で lookupFaces 等の経路に配線済み）
    //
    // `mapping` は `clips` から再構築される合成時刻⇔素材時刻の変換層。
    // まず `clips` の変更を `mapping` が正しく追随することを確認する。

    /// フェーズ1と同じ単一クリップ（素材全体を1本使う）状態では、
    /// 合成時刻と素材時刻が一致する恒等写像になること。
    func test_mapping_singleClip_isIdentityMappingToCurrentSource() {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        let location = model.mapping.sourceLocation(at: 3.0)

        XCTAssertEqual(location?.sourceID, model.currentSourceID)
        XCTAssertEqual(location?.time ?? -1, 3.0, accuracy: 1e-9)
    }

    /// 2クリップ（うち1本は別素材）を `clips` に直接セットしたとき、
    /// 合成時刻がどちらのクリップに属するかで正しい素材IDと素材内時刻を返すこと。
    func test_mapping_twoClips_resolvesEachClipsSourceAndTime() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        // 合成タイムライン: [0,5) が clipA（sourceA の 0...5）、
        //                   [5,11) が clipB（sourceB の 2...8、オフセット+2）
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 2, sourceEnd: 8)
        model.setClipsForTesting([clipA, clipB])

        let front = model.mapping.sourceLocation(at: 1.0)
        XCTAssertEqual(front?.sourceID, sourceA, "前半クリップの区間で素材IDを取り違えている")
        XCTAssertEqual(front?.time ?? -1, 1.0, accuracy: 1e-9)

        let back = model.mapping.sourceLocation(at: 6.0)
        XCTAssertEqual(back?.sourceID, sourceB, "後半クリップの区間で素材IDを取り違えている")
        XCTAssertEqual(back?.time ?? -1, 3.0, accuracy: 1e-9,
                       "後半クリップの素材内時刻（sourceStart オフセット込み）がずれている")
    }

    // MARK: - S3: 分割・並べ替え状態での写像配線（読み・書き・丸め順序）

    /// 1素材を2クリップに分割して並べ替えた状態（合成 [0,4)←素材 6...10、
    /// 合成 [4,8)←素材 0...4）を作る共通セットアップ。
    private func makeSplitReorderedModel() -> MosaicEditorModel {
        let model = makeModel()
        let source = model.currentSourceID
        model.setClipsForTesting([
            TimelineClip(sourceID: source, sourceStart: 6, sourceEnd: 10),
            TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4)
        ])
        return model
    }

    /// 分割＋並べ替え後の合成時刻の lookupFaces が、そのクリップが使う
    /// 素材区間のバケットの顔を引くこと（合成時刻のままキャッシュを引く誤実装だと
    /// 別クリップ・別区間の顔を返す）。
    func test_lookupFaces_afterSplitAndReorder_readsCorrectSourceBucket() {
        let model = makeSplitReorderedModel()
        let source = model.currentSourceID
        let lateFace = fakeFace(cx: 0.8, cy: 0.2)    // 素材 7.0s に居る顔
        let earlyFace = fakeFace(cx: 0.2, cy: 0.8)   // 素材 1.0s に居る顔
        model.cacheStore.store([lateFace], sourceID: source, time: 7.0)
        model.cacheStore.store([earlyFace], sourceID: source, time: 1.0)

        // 合成 1.0 は並べ替え後の前半クリップ → 素材 7.0 の顔
        let front = model.lookupFaces(at: 1.0)
        XCTAssertEqual(front.count, 1)
        XCTAssertEqual(Double(model.normalizedCentroid(of: front[0]).x), 0.8, accuracy: 0.01,
                       "並べ替え後の前半クリップが素材後半（7.0s）の顔を引けていない")

        // 合成 5.0 は後半クリップ → 素材 1.0 の顔
        let back = model.lookupFaces(at: 5.0)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(Double(model.normalizedCentroid(of: back[0]).x), 0.2, accuracy: 0.01,
                       "並べ替え後の後半クリップが素材前半（1.0s）の顔を引けていない")
    }

    /// ライブ検出の書き込みが、合成時刻ではなく写像後の素材時刻キーに落ちること。
    func test_storeLiveDetection_afterSplitAndReorder_writesToMappedSourceKey() {
        let model = makeSplitReorderedModel()
        let source = model.currentSourceID

        // 合成 1.0（＝素材 7.0）のフレームをライブ検出した想定
        model.storeLiveDetection([fakeFace(cx: 0.5, cy: 0.4)], at: 1.0, source: UIImage())

        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: 7.0)?.count, 1,
                       "写像後の素材キー（7.0s バケット）に書けていない")
        XCTAssertNil(model.cacheStore.faces(sourceID: source, time: 1.0),
                     "合成時刻をそのまま素材キーにしてしまっている")
    }

    /// フロー橋渡し（liveFlowCache）の書き込みも同じ写像済み素材キーに落ちること。
    /// detectionCache 側には「実検出なし」の空エントリが同じ素材キーで残ること。
    func test_flowBridgedWrite_afterSplitAndReorder_usesMappedSourceKey() {
        let model = makeSplitReorderedModel()
        let source = model.currentSourceID

        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.5, cy: 0.4)], bridgedByFlow: true),
            at: 1.0, source: UIImage())

        let mappedKey = DetectionCacheKey(sourceID: source, time: 7.0, bucketFPS: model.liveBucketFPS)
        XCTAssertEqual(model.liveFlowCache[mappedKey]?.count, 1,
                       "フロー由来の書き込みが写像後の素材キーに落ちていない")
        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: 7.0), [],
                       "実検出なしの空エントリが写像後の素材キーに残っていない")
        // 参照側も合成時刻から同じフロー位置を引けること
        XCTAssertFalse(model.lookupFaces(at: 1.0).isEmpty,
                       "合成時刻の lookup が写像済みフロー位置を引けていない")
    }

    /// 丸め順序の契約: 「写像 → 素材時刻でバケット丸め」であること。
    /// 合成時刻で先に丸めてから写像する誤実装は rate≠1 でバケットがずれる
    /// （2x クリップでは合成側の丸め誤差が素材側で2倍に拡大される）。
    func test_liveWrite_withRate_bucketsAfterMappingNotBefore() {
        let model = makeModel()
        let source = model.currentSourceID
        // 2x クリップ: 合成 [0,2) ← 素材 [0,4)
        model.setClipsForTesting([
            TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4, rate: 2.0)
        ])

        // 合成 1.03 → 素材 2.06 → バケット round(2.06*15)/15 = 31/15 ≒ 2.067
        model.storeLiveDetection([fakeFace(cx: 0.5, cy: 0.4)], at: 1.03, source: UIImage())

        XCTAssertNotNil(model.cacheStore.faces(sourceID: source, time: 2.06),
                        "写像後の素材時刻バケット（31/15）に書けていない")
        // 丸め→写像の誤実装: liveBucket(1.03)=1.0 → 素材 2.0 → バケット 30/15
        XCTAssertNil(model.cacheStore.faces(sourceID: source, time: 2.0),
                     "合成時刻で先に丸めてから写像している（rate≠1 でバケットずれ）")
    }

    /// 範囲外の合成時刻（合成尺ちょうどの終端＝半開区間の外。再生終端や AVPlayer の
    /// 実測時刻の揺らぎで発生する）は恒等フォールバックせず、タイムライン端へ
    /// クランプして写像すること。恒等フォールバックだと分割・並べ替え状態で
    /// 「合成時刻＝同一素材の使用区間内の別バケット」となり、誤フレームの顔が
    /// 正規の検出としてキャッシュを汚染する。
    func test_liveWriteAtTimelineEnd_clampsIntoLastClipInsteadOfPollutingSourceBucket() {
        // 合成 [0,4)←素材 6...10、合成 [4,8)←素材 0...4（totalDuration = 8）
        let model = makeSplitReorderedModel()
        let source = model.currentSourceID

        // 合成 8.0 は半開区間 [0,8) の外。恒等フォールバックだと素材 8.0s
        // （前半クリップの使用区間内バケット）へ誤った顔が書き込まれる。
        model.storeLiveDetection([fakeFace(cx: 0.5, cy: 0.4)], at: 8.0, source: UIImage())

        XCTAssertNil(model.cacheStore.faces(sourceID: source, time: 8.0),
                     "範囲外の合成時刻が恒等フォールバックして使用区間内バケットを汚染している")
        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: 4.0.nextDown)?.count, 1,
                       "終端の書き込みが最終クリップの素材終端バケットへクランプされていない")
        // 読み出し側も同じクランプで、終端ちょうどの lookup が最終クリップの顔を引けること
        XCTAssertFalse(model.lookupFaces(at: 8.0).isEmpty,
                       "終端ちょうどの lookup がクランプされず空になっている")
    }

    // MARK: - 矩形サーチ（`detectInRegion` / `resolveRegion`）のキャッシュ「マージ」書き込み
    //
    // 動画モードで範囲指定して見つけた顔は、`detectedFaces` に足すだけでは画面にもエクスポートにも
    // 反映されない（描画は検出キャッシュしか見ない）。`mergeDetection` がその書き込み口。

    /// **マージは同じバケットの既存の顔を消さない。** `cacheStore.store` を素で呼ぶ実装に
    /// 戻すと、範囲サーチが見つけた 1 人のために同じバケットにいた別人の顔が消えてしまう
    /// （プライバシーアプリとしては露出が増える方向の回帰）。
    func test_mergeDetection_preservesExistingFaceInSameBucket() {
        let model = makeModel()
        let source = model.currentSourceID
        model.cacheStore.store([fakeFace(cx: 0.2, cy: 0.2)], sourceID: source, time: 3.0)

        model.mergeDetection([fakeFace(cx: 0.8, cy: 0.8)], sourceID: source, sourceTime: 3.0)

        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: 3.0)?.count, 2,
                       "マージが既存の顔を消してしまっている（store を素で呼ぶ実装に戻すと1件になる）")
    }

    /// 重複判定（`FaceLandmarkSet.hasCounterpart`、IoU > 0.3）で同一人物とみなせる顔は
    /// 追記しないこと。同じ顔を毎回積み増すと、そのバケットが本来 1 人のところ
    /// 複数人として描画・選択候補に出てしまう。
    func test_mergeDetection_doesNotDuplicateSameFace() {
        let model = makeModel()
        let source = model.currentSourceID
        model.cacheStore.store([fakeFace(cx: 0.5, cy: 0.5)], sourceID: source, time: 2.0)

        // ほぼ同じ位置（IoU > 0.3）の「見つけた顔」
        model.mergeDetection([fakeFace(cx: 0.51, cy: 0.5)], sourceID: source, sourceTime: 2.0)

        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: 2.0)?.count, 1,
                       "同一人物とみなせる顔を二重に追加している")
    }

    /// 写真モード（`sourceID` が nil）は書き込まない。写真は素材ID・検出キャッシュの
    /// 概念自体が無いため（`FaceTarget.sourceID` の doc 参照）。
    func test_mergeDetection_noOpForNilSourceID() {
        let model = makeModel()
        model.mergeDetection([fakeFace(cx: 0.5, cy: 0.5)], sourceID: nil, sourceTime: 0)
        XCTAssertEqual(model.cacheStore.count, 0, "写真モード（sourceID nil）で書き込んでしまっている")
    }

    /// `resolveRegion` がキャッシュへ書くのは**ヒットした実測時刻**でなければならない
    /// （`findFaceInVideo` の 1fps サーチは要求時刻と実際にコピーできたフレーム時刻が
    /// ずれることがある）。`mergeDetection` は渡された時刻をそのまま使うことを確認する
    /// （呼び出し側が実測時刻ではなく要求時刻を渡す退行が起きても、この境界で検出できる）。
    func test_mergeDetection_writesToPassedSourceTimeNotSomeOtherTime() {
        let model = makeModel()
        let source = model.currentSourceID
        let actualHitTime = 4.2 // 例: 4.0 を要求してコピーできたのは 4.2 だった、を模す

        model.mergeDetection([fakeFace(cx: 0.5, cy: 0.5)], sourceID: source, sourceTime: actualHitTime)

        XCTAssertNotNil(model.cacheStore.faces(sourceID: source, time: actualHitTime),
                        "渡された実測時刻のバケットに書けていない")
        XCTAssertNil(model.cacheStore.faces(sourceID: source, time: 4.0),
                    "実測時刻ではなく別時刻（要求時刻相当）に書いてしまっている")
    }

    /// 丸め順序の契約は `mergeDetection` にも及ぶ: 呼び出し側（`detectInRegion`）は
    /// `resolveSourceLocation(atComposition:)` で**素材時刻へ写像した後の生の値**を渡し、
    /// バケットへの丸めは `DetectionCacheKey.init` に任せる。合成時刻で先に丸めてから
    /// 写像する誤実装は rate≠1 のクリップでバケットがずれる
    /// （`test_liveWrite_withRate_bucketsAfterMappingNotBefore` と同型）。
    func test_mergeDetection_withRate_bucketsAfterMappingNotBefore() {
        let model = makeModel()
        let source = model.currentSourceID
        // 2x クリップ: 合成 [0,2) ← 素材 [0,4)
        model.setClipsForTesting([
            TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 4, rate: 2.0)
        ])

        // detectInRegion と同じ手順: 合成時刻を resolveSourceLocation で素材時刻へ写像
        // してから mergeDetection へ渡す（ここで丸めない）。
        let resolved = model.resolveSourceLocation(atComposition: 1.03)
        XCTAssertEqual(resolved.time, 2.06, accuracy: 1e-9)
        model.mergeDetection([fakeFace(cx: 0.5, cy: 0.4)],
                             sourceID: resolved.sourceID, sourceTime: resolved.time)

        XCTAssertNotNil(model.cacheStore.faces(sourceID: source, time: 2.06),
                        "写像後の素材時刻バケット（31/15）に書けていない")
        XCTAssertNil(model.cacheStore.faces(sourceID: source, time: 2.0),
                    "合成時刻で先に丸めてから写像している（rate≠1 でバケットずれ）")
    }

    // MARK: - 範囲指定は「まず矩形で確実に隠す」（顔が見つかっても見つからなくても）

    /// `appendObjectMask` は呼ぶたびに矩形マスクをちょうど 1 個だけ追加し、
    /// 第2段（顔追跡への差し替え）が後から見分けられるよう `isRegionPlaceholder` を
    /// 立てること。`detectInRegion` / `resolveRegion` はこの関数を「見つかった」
    /// 「見つからなかった」のどちらの結末でも呼ぶ（二重には呼ばない）契約になっている。
    func test_appendObjectMask_addsExactlyOnePlaceholderMaskPerCall() {
        let model = makeModel()

        model.appendObjectMask(compositionRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(model.objectMasks.count, 1)
        XCTAssertEqual(model.objectMasks.first?.isRegionPlaceholder, true,
                       "矩形サーチが置いたマスクに暫定マーカーが立っていない")

        model.appendObjectMask(compositionRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
        XCTAssertEqual(model.objectMasks.count, 2, "2回目の呼び出しでマスクが1個だけ増えていない")
    }

    /// 範囲指定で何も見つからない結末（素材が何も読み込まれていない状態）でも、
    /// `detectInRegion` が矩形マスクをちょうど 1 個だけ追加すること。
    /// `sourceImage` も `videoAsset` も nil の状態は「矩形内クロップも動画サーチも
    /// 失敗する」経路を MediaPipe 無しで決定的に再現できる
    /// （`detectInRegion` → `resolveRegion` → 非動画フォールバック）。
    func test_detectInRegion_addsExactlyOneObjectMask_whenNothingIsLoaded() async {
        let model = makeModel()
        XCTAssertTrue(model.objectMasks.isEmpty)

        await model.detectInRegion(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

        XCTAssertEqual(model.objectMasks.count, 1,
                       "見つからなかった結末で矩形マスクがちょうど1個増えていない")
        XCTAssertEqual(model.objectMasks.first?.isRegionPlaceholder, true)
    }

    // MARK: - `detectInRegion` の参照フレーム選択（先頭フレーム固定バグの回帰）
    //
    // `seekTo` はスクラブ時に `sourceTexture` のみ更新し `sourceImage` は更新しない
    // （`loadFirstFrame` で入った先頭フレームのまま）。`detectInRegion` が
    // `sourceImage` を無条件に検出入力へ使う実装に戻すと、動画をスクラブしてから
    // 矩形サーチしたとき、常に先頭フレーム（素材時刻 0）を検出・クロップしてしまい、
    // 見つかった顔の座標を現在の再生位置のバケットへ誤って書き込む
    // （`mergeDetection` 経由のキャッシュ汚染）。
    //
    // 実素材・MediaPipe なしではピクセル出力までは検証できないため、
    // `detectInRegion` が「検出入力に使うつもりの素材内時刻」として記録する
    // 内部フック `lastDetectInRegionReferenceSourceTime` で、再生位置に追随して
    // いること（＝先頭フレーム固定=0 に張り付いていないこと）を確認する。
    func test_detectInRegion_referenceFrameTime_followsPlaybackPositionNotFirstFrame() async {
        let model = makeModel()
        // 素材 10 秒ぶんの単一クリップ。`setClipsForTesting` 後は `videoDuration` が
        // `mapping.totalDuration`（=10）に追随する。
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        // `playbackPosition` は 0...1 の正規化位置（`compositionTime(forPosition:)`
        // の doc 参照）。0.6 → 合成時刻 6.0 秒。
        model.playbackPosition = 0.6
        await model.detectInRegion(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

        XCTAssertEqual(model.lastDetectInRegionReferenceSourceTime ?? -1, 6.0, accuracy: 1e-9,
                       "スクラブ後の再生位置ではなく先頭フレーム（0）を検出入力にしている")
    }

    /// 再生位置を変えるたびに参照フレームの時刻も追随して変わること
    /// （1回だけ現在時刻を捕まえて以降固定、という半端な実装の回帰）。
    func test_detectInRegion_referenceFrameTime_updatesAcrossMultipleSeeks() async {
        let model = makeModel()
        let clip = TimelineClip(sourceID: model.currentSourceID, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        model.playbackPosition = 0.2
        await model.detectInRegion(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(model.lastDetectInRegionReferenceSourceTime ?? -1, 2.0, accuracy: 1e-9)

        model.playbackPosition = 0.8
        await model.detectInRegion(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(model.lastDetectInRegionReferenceSourceTime ?? -1, 8.0, accuracy: 1e-9,
                       "2回目のシーク後も1回目の時刻に張り付いている")
    }

    /// 写真モードは `sourceImage` の概念しかないため、参照フレームフックは常に nil
    /// （動画モード専用の写像を持ち込まないこと）。
    func test_detectInRegion_referenceFrameTime_isNilInPhotoMode() async {
        let model = MosaicEditorModel(mode: .photo, recents: RecentItemsStore())

        await model.detectInRegion(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

        XCTAssertNil(model.lastDetectInRegionReferenceSourceTime,
                     "写真モードで素材時刻の写像フックに値が入ってしまっている")
    }

    // MARK: - 第2段: 範囲指定シードの前後走査（`MosaicEditorModel+RegionSeeding.swift`）
    //
    // `RegionSeedTracker`（MosaicCore）は公開イニシャライザを持つが `Step` / `Outcome` は
    // 持たないため（MosaicCore モジュール外からは構築できない）、実際の `nextStep()` /
    // `accept(candidates:similarities:)` を回して本物の `Step` / `Outcome` を得てから
    // `recordRegionSeedFinding` へ渡す。

    /// テスト用の走査 1 歩ぶんを組み立てる。`RegionSeedTracker` を 1 歩だけ進め、
    /// 渡した `candidates` で `accept` した結果と、書き戻しに使う `RegionFaceSeeder.StepResult`
    /// を返す。
    private func makeRegionSeedStep(
        seedFace: FaceLandmarkSet, seedTime: Double, range: ClosedRange<Double>,
        candidates: [FaceLandmarkSet]
    ) -> (result: RegionFaceSeeder.StepResult, outcome: RegionSeedTracker.Outcome)? {
        var tracker = RegionSeedTracker(seedTime: seedTime, seedBox: seedFace.boundingBox,
                                        range: range, direction: .forward)
        guard let step = tracker.nextStep() else { return nil }
        let outcome = tracker.accept(candidates: candidates, similarities: nil)
        let result = RegionFaceSeeder.StepResult(candidates: candidates, roi: step.roi,
                                                 sourceTime: step.sourceTime,
                                                 isFullFrame: step.isFullFrame, frame: UIImage())
        return (result, outcome)
    }

    /// 3 回連続でミスさせ、4 回目（全画面フォールバック）の `Step` / `Outcome` を得る。
    private func makeFullFrameMissStep(
        seedFace: FaceLandmarkSet, seedTime: Double, range: ClosedRange<Double>
    ) -> (result: RegionFaceSeeder.StepResult, outcome: RegionSeedTracker.Outcome)? {
        var tracker = RegionSeedTracker(seedTime: seedTime, seedBox: seedFace.boundingBox,
                                        range: range, direction: .forward)
        var lastStep: RegionSeedTracker.Step?
        var lastOutcome: RegionSeedTracker.Outcome?
        for _ in 0..<4 {
            guard let step = tracker.nextStep() else { return nil }
            lastStep = step
            lastOutcome = tracker.accept(candidates: [], similarities: nil)
        }
        guard let step = lastStep, let outcome = lastOutcome, step.isFullFrame else { return nil }
        let result = RegionFaceSeeder.StepResult(candidates: [], roi: step.roi,
                                                 sourceTime: step.sourceTime,
                                                 isFullFrame: step.isFullFrame, frame: UIImage())
        return (result, outcome)
    }

    /// **最重要**: ROI ミス（顔なし・全画面フォールバックではない）に空エントリを書くと、
    /// `shouldDetectPreviewFrame` の `hasEntry` 判定でそのバケットのライブ検出が永久に
    /// スキップされ、全編の一部が素通しのまま固定される。`recordRegionSeedFinding` はこの
    /// ケースで一切書き込んではならない。
    func test_regionSeed_doesNotWriteEmptyEntryOnROIMiss() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 2.0,
                                                          range: 0...10, candidates: []) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        XCTAssertFalse(result.isFullFrame, "テスト前提が崩れている: 1歩目なのに全画面フォールバックになっている")
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 2.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertEqual(model.cacheStore.count, 0,
                       "ROI ミスで空エントリを書いてしまっている（該当バケットのライブ検出が永久停止する）")
    }

    /// 規則の単純化（親の裁定）: 連続ミス3回目の**全画面**フォールバックで顔ゼロであっても、
    /// そのバケットのライブ検出を永久停止させる空エントリは一切書かない。全画面を見た上での
    /// ミスであっても「検出の退行は誤モザイクより重い」という原則の方を優先する。
    func test_regionSeed_doesNotWriteEmptyEntryEvenOnFullFrameMiss() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        guard let (result, outcome) = makeFullFrameMissStep(seedFace: seedFace, seedTime: 2.0, range: 0...10) else {
            return XCTFail("全画面フォールバックのステップまで到達できなかった（テストの前提が崩れている）")
        }
        XCTAssertTrue(result.isFullFrame, "テスト前提が崩れている: 4歩目なのに全画面フォールバックになっていない")
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 2.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertEqual(model.cacheStore.count, 0,
                       "全画面フォールバックの顔なしで空エントリを書いてしまっている（該当バケットのライブ検出が永久停止する）")
    }

    /// `recordRegionSeedFinding` は `mergeDetection` 経由なので、同バケットの既存の顔を消さない。
    func test_regionSeed_mergeDetectionPreservesExistingFaceInSameBucket() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        let newFace = fakeFace(cx: 0.8, cy: 0.8)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 3.0,
                                                          range: 0...10, candidates: [newFace]) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        // 既存の顔は「書き込み先と同じバケット」へ置く。シード時刻（3.0）ではなく
        // ステップの実時刻（`result.sourceTime`＝3.0 から 1 歩進んだ時刻）で置かないと、
        // 別バケットを見ることになりマージの検査にならない。
        model.cacheStore.store([fakeFace(cx: 0.2, cy: 0.2)], sourceID: source, time: result.sourceTime)
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 3.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertEqual(model.cacheStore.faces(sourceID: source, time: result.sourceTime)?.count, 2,
                       "マージが既存の顔を消してしまっている（素の store を呼ぶ実装に戻すと1件になる）")
    }

    /// `liveFlowCache` はオプティカルフロー専用。シード走査由来の書き込みは一切触れないこと。
    func test_regionSeed_doesNotTouchLiveFlowCache() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        let newFace = fakeFace(cx: 0.8, cy: 0.8)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 3.0,
                                                          range: 0...10, candidates: [newFace]) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 3.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertTrue(model.liveFlowCache.isEmpty,
                      "シード走査の書き込みが liveFlowCache に触れている（実検出ではないため禁止）")
    }

    /// 世代が進んだ（`cancelRegionSeeding` 相当）後の書き込みは、生きた走査の結果でも
    /// 捨てられること。
    func test_regionSeed_discardsWriteAfterGenerationAdvances() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        let newFace = fakeFace(cx: 0.6, cy: 0.6)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 4.0,
                                                          range: 0...10, candidates: [newFace]) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 4.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)
        model.regionSeedGeneration += 1 // cancelRegionSeeding 相当

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertEqual(model.cacheStore.count, 0, "世代が進んだ後の書き込みが捨てられていない")
    }

    /// `sources` から素材が消えた（クリップの入れ替え等）後の書き込みも捨てられること。
    func test_regionSeed_discardsWriteWhenSourceRemoved() {
        let model = makeModel()
        let source = UUID() // 意図的に `sources` へ登録しない
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        let newFace = fakeFace(cx: 0.6, cy: 0.6)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 1.0,
                                                          range: 0...10, candidates: [newFace]) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 1.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)

        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)

        XCTAssertEqual(model.cacheStore.count, 0, "素材が消えた後の書き込みが捨てられていない")
    }

    /// キュー上限は 8 件の FIFO。溢れたら最も古いものから捨てる（新しいユーザー操作を優先）。
    func test_regionSeed_queueDropsOldestBeyondLimit() {
        let model = makeModel()
        let targetIDs = (0..<9).map { _ in UUID() }
        for targetID in targetIDs {
            model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
                sourceID: model.currentSourceID, asset: dummyAsset(), sourceRange: 0...1, clipID: UUID(),
                seedTime: 0, seedLandmarks: fakeFace(cx: 0.5, cy: 0.5),
                targetID: targetID, personID: nil))
        }

        XCTAssertEqual(model.regionSeedQueue.count, 8, "キューが上限8件にトリムされていない")
        XCTAssertFalse(model.regionSeedQueue.contains { $0.targetID == targetIDs[0] },
                       "最も古いシードが捨てられていない")
        XCTAssertEqual(model.regionSeedQueue.last?.targetID, targetIDs[8],
                       "最新のシードが残っていない")
    }

    /// `awaitRegionSeeding()` は `while` の無限待ちではなく回数上限（8）で必ず戻ること
    /// （`awaitObjectTracking()` と同じ形。書き出しボタンが固まる事故を防ぐ）。
    func test_regionSeed_awaitRegionSeedingReturnsWithoutHanging() async {
        let model = makeModel()
        // `sources` に登録していない素材IDなので `processRegionSeed` は即 return する。
        for _ in 0..<3 {
            model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
                sourceID: UUID(), asset: dummyAsset(), sourceRange: 0...1, clipID: UUID(), seedTime: 0,
                seedLandmarks: fakeFace(cx: 0.5, cy: 0.5), targetID: UUID(), personID: nil))
        }

        await model.awaitRegionSeeding()

        XCTAssertNil(model.regionSeedTask, "待ち終えたのにタスクが残っている（固まる兆候）")
    }

    /// 回帰: `cancelRegionSeeding()` 直後に新しいシードを積んで新タスクを起動したとき、
    /// cancel された旧タスクが遅れて自分の `while` を抜けても新タスクの参照
    /// （`regionSeedTask`）を消してはいけない。消えると `awaitRegionSeeding()` が
    /// 新タスクを待たずに即座に返り、書き出しが走査完了前に進んでしまう
    /// （さらに次の `enqueueRegionSeed` で 3 本目が起動し、デコーダの二重使用にもなる）。
    func test_regionSeed_cancelThenEnqueue_doesNotLoseNewTaskReference() async {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        // `runDirection` の協調的譲りループ（`shouldYieldTrackingDecoder`）へ旧タスクを
        // 足止めする。`isPlaying` を立てるだけで実デコードなしに 200ms スリープへ入る。
        model.isPlaying = true
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(), seedTime: 2.0,
            seedLandmarks: seedFace, targetID: UUID(), personID: nil))
        // 旧タスクが起動しスリープループへ入るまで少し待つ。
        try? await Task.sleep(nanoseconds: 50_000_000)

        model.cancelRegionSeeding()
        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(), seedTime: 2.0,
            seedLandmarks: seedFace, targetID: UUID(), personID: nil))
        XCTAssertNotNil(model.regionSeedTask, "新しいシードを積んだ直後にタスクが起動していない")

        // 旧タスクが自分のスリープから抜けて `while` を抜けるまで待つ。旧実装では
        // ここで無条件の `regionSeedTask = nil` が新タスクの参照を消してしまう。
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(model.regionSeedTask, "古いタスクの終了処理が新しいタスクの参照を消してしまっている")

        model.isPlaying = false
        await model.awaitRegionSeeding()
    }

    // MARK: - 第2段 Step 3: 配線（起動元・待ち合わせ・進捗）

    /// `apply(_:)`（undo）でタイムラインが差し替わるとき、走行中のシード走査が
    /// 打ち切られてキューが空・進捗が nil に戻ること。
    func test_apply_undo_cancelsRegionSeeding_queueEmptyAndProgressNil() async {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        model.commitEdit()
        model.objectMosaicOn.toggle()
        model.commitEdit()

        // `isPlaying` で協調的な譲りループへ足止めし、走査中の状態を作る
        // （`test_regionSeed_cancelThenEnqueue_doesNotLoseNewTaskReference` と同じ手口）。
        model.isPlaying = true
        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(), seedTime: 2.0,
            seedLandmarks: fakeFace(cx: 0.5, cy: 0.5), targetID: UUID(), personID: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(model.regionSeedTask, "テスト前提: シード走査タスクが起動していない")

        model.undo()

        XCTAssertTrue(model.regionSeedQueue.isEmpty, "undo でキューが空になっていない")
        XCTAssertNil(model.regionSeedProgress, "undo でシード進捗が nil に戻っていない")

        model.isPlaying = false
        await model.awaitRegionSeeding()
    }

    /// `load(videoURL:)`（素材入れ替え）は冒頭で `cancelRegionSeeding()` を同期的に
    /// 呼ぶ。タスク・キュー・進捗が打ち切られ、かつ**配線経由で**進んだ世代により
    /// 旧世代の書き戻しが捨てられること（世代不一致の判定自体は
    /// `test_regionSeed_discardsWriteAfterGenerationAdvances` で直接検証済み。
    /// ここでは配線が実際にそれを引き起こすかを見る）。
    func test_load_videoURL_cancelsRegionSeeding_atMaterialSwap() {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        let seedFace = fakeFace(cx: 0.5, cy: 0.5)
        let newFace = fakeFace(cx: 0.6, cy: 0.6)
        guard let (result, outcome) = makeRegionSeedStep(seedFace: seedFace, seedTime: 4.0,
                                                          range: 0...10, candidates: [newFace]) else {
            return XCTFail("シードから1ステップも進められなかった（テストの前提が崩れている）")
        }
        let state = MosaicEditorModel.RegionSeedScanState(generation: model.regionSeedGeneration)
        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(), seedTime: 2.0,
            seedLandmarks: seedFace, targetID: UUID(), personID: nil))
        XCTAssertNotNil(model.regionSeedTask, "テスト前提: シード走査タスクが起動していない")

        model.load(videoURL: URL(fileURLWithPath: "/dev/null"))

        XCTAssertNil(model.regionSeedTask, "素材入れ替えでシード走査タスクが打ち切られていない")
        XCTAssertTrue(model.regionSeedQueue.isEmpty, "素材入れ替えでキューが空になっていない")
        XCTAssertNil(model.regionSeedProgress, "素材入れ替えでシード進捗が nil に戻っていない")

        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(),
                                                seedTime: 4.0, seedLandmarks: seedFace,
                                                targetID: UUID(), personID: nil)
        model.recordRegionSeedFinding(result, seed: seed, outcome: outcome, signatures: nil, state: state)
        XCTAssertEqual(model.cacheStore.count, 0,
                       "load(videoURL:) 配線の cancelRegionSeeding が効いておらず、旧世代の書き戻しが入っている")
    }

    /// `awaitRegionSeeding()` は走査が実際に走っている（協調的な譲りループで
    /// 足止めされている）最中に呼んでも固まらず戻ること。あわせて
    /// `regionSeedProgress` が走査中は非 nil、終了後は nil に戻ることも見る。
    func test_regionSeed_awaitReturnsDuringActiveScan_andProgressResetsAfter() async {
        let model = makeModel()
        let source = model.currentSourceID
        model.sources[source] = dummyAsset()
        model.isPlaying = true
        model.enqueueRegionSeed(MosaicEditorModel.RegionSeed(
            sourceID: source, asset: dummyAsset(), sourceRange: 0...10, clipID: UUID(), seedTime: 2.0,
            seedLandmarks: fakeFace(cx: 0.5, cy: 0.5), targetID: UUID(), personID: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(model.regionSeedTask, "テスト前提: シード走査タスクが起動していない")
        XCTAssertNotNil(model.regionSeedProgress, "走査中なのに regionSeedProgress が nil のまま")

        // 足止めを裏で解除しつつ、awaitRegionSeeding が固まらず戻ることを見る
        // （`while` の無限待ちではなく回数上限で戻る設計の実地確認）。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            model.isPlaying = false
        }
        await model.awaitRegionSeeding()

        XCTAssertNil(model.regionSeedTask, "awaitRegionSeeding から戻ったのにタスクが残っている")
        XCTAssertNil(model.regionSeedProgress, "走査終了後も regionSeedProgress が nil に戻っていない")
    }

    // MARK: - クリップ変形（拡大）と再検出（被覆台帳）

    // `ClipTransform.scale > 1` はこのアプリで初めて「フレーム外への切り取り」を作る
    // （従来の `AspectFit` は必ず内接で素材が切れなかった）。拡大中のライブ検出は
    // フレーム外の顔を見られないので、そのバケットを素材全体まで「検出済み」と記録すると、
    // 縮小に戻したときに `shouldDetectPreviewFrame` が永久にスキップし、端にいた顔が
    // 素通しのまま固定される。判定は「記録済み可視領域 ⊇ いま見えている領域」で行う。

    /// 拡大率 `scale` のクリップ変形が掛かった状態のレイアウト（配置は変形後の配置矩形）。
    private func transformedLayout(clipID: UUID, scale: Double) -> TimelineRenderLayout {
        TimelineRenderLayout(placements: [
            clipID: ClipTransform(scale: scale).applied(to: TimelineRenderLayout.unitRect)
        ])
    }

    /// **最重要（プライバシー）**: 拡大中に埋めたバケットは、縮小に戻したら再検出されること。
    func test_拡大中に検出したバケットは縮小後に再検出される() {
        let model = makeModel()
        // `faceMosaicOn` は初期化直後 false（宣言時の既定 true とは別に init が倒す）。
        // `shouldDetectPreviewFrame` の最初の guard で弾かれるので、明示的に立てる。
        model.faceMosaicOn = true
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 2)

        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 3.0), "前提が崩れている: まだ未検出のはず")
        // 2 倍に拡大した状態でライブ検出が走り、そのバケットが埋まる
        // （見えているのは素材中央の 1/2 × 1/2 だけ）。
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.5, cy: 0.5)], bridgedByFlow: false),
            at: 3.0, source: UIImage(), generation: model.timelineGeneration)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 3.0),
                       "同じ拡大率のままなのに再検出が走っている（毎フレーム再走査の退行）")

        // 等倍へ戻す＝素材の端が新しく見えるようになった。
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 1)
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 3.0),
                      "縮小して新しく見えた領域が再検出されない（端の顔が素通しのまま固定される）")
    }

    /// 空エントリ（検出したが顔なし）でも同じであること。
    /// 空エントリは `hasEntry` を真にしてライブ検出を永久停止させる力を持つので、
    /// 被覆を無視すると最も重い形で穴になる。
    func test_拡大中の空エントリも縮小後に再検出される() {
        let model = makeModel()
        // `faceMosaicOn` は初期化直後 false（宣言時の既定 true とは別に init が倒す）。
        // `shouldDetectPreviewFrame` の最初の guard で弾かれるので、明示的に立てる。
        model.faceMosaicOn = true
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 3)

        model.recordScannedEmptyForTesting(at: 3.0)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 3.0), "前提が崩れている: 空エントリが入っていない")

        model.renderLayout = transformedLayout(clipID: clip.id, scale: 1)
        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 3.0),
                      "拡大中の空エントリが縮小後も検出済み扱いされている（永久スキップ）")
    }

    /// **性能の回帰防止**: 拡大していく方向（可視領域が縮む方向）では再検出を要求しない。
    /// ここが false にならないと、ピンチのたびに全編の再走査が走る。
    func test_縮小方向への変形は再検出を要求しない() {
        let model = makeModel()
        // `faceMosaicOn` は初期化直後 false（宣言時の既定 true とは別に init が倒す）。
        // `shouldDetectPreviewFrame` の最初の guard で弾かれるので、明示的に立てる。
        model.faceMosaicOn = true
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])

        // 等倍（素材全体が見えている）で検出済みにする。
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 1)
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.5, cy: 0.5)], bridgedByFlow: false),
            at: 4.0, source: UIImage(), generation: model.timelineGeneration)

        for scale in [1.5, 2.0, 4.0] {
            model.renderLayout = transformedLayout(clipID: clip.id, scale: scale)
            XCTAssertFalse(model.shouldDetectPreviewFrame(at: 4.0),
                           "scale=\(scale)（可視領域が縮む方向）で再検出が走っている")
        }

        // 拡大中に書いたエントリも、さらに拡大する方向では再検出を要求しない。
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 2)
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.5, cy: 0.5)], bridgedByFlow: false),
            at: 5.0, source: UIImage(), generation: model.timelineGeneration)
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 4)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 5.0),
                       "拡大 → さらに拡大で再検出が走っている（ピンチのたびに全再走査になる）")
    }

    /// 既存挙動の不変: 無変形（従来のタイムライン）なら、一度検出したバケットは
    /// 何度問い合わせても再検出しない。
    func test_無変形のままなら従来どおり一度検出したら再検出しない() {
        let model = makeModel()
        // `faceMosaicOn` は初期化直後 false（宣言時の既定 true とは別に init が倒す）。
        // `shouldDetectPreviewFrame` の最初の guard で弾かれるので、明示的に立てる。
        model.faceMosaicOn = true
        let source = model.currentSourceID
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)
        model.setClipsForTesting([clip])
        // renderLayout は `.identity`（＝装着なし・全面）のまま＝従来のタイムライン。

        XCTAssertTrue(model.shouldDetectPreviewFrame(at: 6.0))
        model.storeLiveDetection(
            LiveDetectionResult(faces: [fakeFace(cx: 0.5, cy: 0.5)], bridgedByFlow: false),
            at: 6.0, source: UIImage(), generation: model.timelineGeneration)
        for _ in 0..<5 {
            XCTAssertFalse(model.shouldDetectPreviewFrame(at: 6.0),
                           "無変形なのに再検出が走っている（毎フレーム全再走査の退行）")
        }
        // 明示的に無変形の配置（単位矩形）を入れても同じ。
        model.renderLayout = transformedLayout(clipID: clip.id, scale: 1)
        XCTAssertFalse(model.shouldDetectPreviewFrame(at: 6.0),
                       "無変形の配置矩形を入れただけで再検出が走っている")
    }
}
