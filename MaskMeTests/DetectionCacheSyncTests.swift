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

        XCTAssertEqual(model.detectionCache.count, 1,
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
}
