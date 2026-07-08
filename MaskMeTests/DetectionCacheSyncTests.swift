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
}
