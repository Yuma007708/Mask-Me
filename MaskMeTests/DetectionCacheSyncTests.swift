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
}
