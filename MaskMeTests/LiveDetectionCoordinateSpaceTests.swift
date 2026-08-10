import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// ライブ検出（プレビュー再生に相乗りする検出）が**合成フレームの座標**を
/// **素材フレームの座標**として検出キャッシュへ書いていた退行のガード。
///
/// プレビューは `item.videoComposition` を装着したフレームをデコードするので
/// （`MosaicPreviewController.swift` / `MosaicPreviewController+Rendering.swift` の
/// `detectionCGImage` は等倍縮小するだけで黒帯を戻さない）、検出結果は
/// **合成フレーム基準**である。それを逆写像せずに `cacheStore` / `liveFlowCache` へ
/// 書くと、描画（`displayFaces`）と書き出し（`VideoMosaicExporter`）が
/// `renderLayout.remap` をもう一度掛けて**二重にずれ、顔が素通しになる**。
///
/// ここでは「合成座標の顔を注入したら、描画の取り出し口が**同じ合成座標**を返す」
/// （＝往復が恒等）ことと、キャッシュの中身が**素材座標**であることの両方を固定する。
@MainActor
final class LiveDetectionCoordinateSpaceTests: XCTestCase {
    /// 240x320 の素材を 320x240 のフレームへアスペクトフィットした配置
    /// （x = 0.21875 / 幅 0.5625 / 縦は全面）。既存テストと同じ実測値。
    private let placement = AspectFit.placement(of: CGSize(width: 240, height: 320),
                                                in: CGSize(width: 320, height: 240))

    private func makeModel() -> MosaicEditorModel {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        model.faceMosaicOn = true
        return model
    }

    private func fakeFace(cx: Double, cy: Double = 0.5, size: Double = 0.1) -> FaceLandmarkSet {
        let half = size / 2
        return FaceLandmarkSet(points: [
            FaceLandmark(x: Float(cx - half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy - half)),
            FaceLandmark(x: Float(cx - half), y: Float(cy + half)),
            FaceLandmark(x: Float(cx + half), y: Float(cy + half))
        ], confidence: 1)
    }

    private func centroidX(_ face: FaceLandmarkSet) -> Double {
        Double(face.points.reduce(Float(0)) { $0 + $1.x }) / Double(face.points.count)
    }

    /// レターボックス付き（合成が装着される）1 クリップのモデル。
    /// - Returns: モデルと素材ID。
    private func makeLetterboxedModel() -> (MosaicEditorModel, UUID) {
        let model = makeModel()
        let sourceID = model.currentSourceID
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        model.setTimelineForTesting(TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [])))
        model.renderLayout = TimelineRenderLayout(placements: [clip.id: placement])
        return (model, sourceID)
    }

    // MARK: - 実検出（cacheStore 経路）

    /// **中核の番人**: 合成座標で注入した顔が、描画の取り出し口から**同じ合成座標**で
    /// 返ること。逆写像を外すと二重写像で 0.4 ほど外側へずれる。
    func test_storeLiveDetection_roundTripsCompositionCoordinates() {
        let (model, sourceID) = makeLetterboxedModel()
        // 素材 x=0.10 の顔は、合成フレームでは 0.21875 + 0.10*0.5625 = 0.275 に見える。
        let inComposition = 0.21875 + 0.10 * 0.5625
        model.storeLiveDetection([fakeFace(cx: inComposition)], at: 1.0, source: UIImage())

        // 1) キャッシュには**素材座標**が入っていること。
        let cached = model.cacheStore.faces(sourceID: sourceID, time: 1.0)
        XCTAssertEqual(cached?.count, 1, "検出がキャッシュに入っていない")
        XCTAssertEqual(centroidX(cached![0]), 0.10, accuracy: 1e-5,
                       "合成座標のまま検出キャッシュへ書かれている（素材座標へ逆写像していない）")

        // 2) 描画の取り出し口は、注入した合成座標をそのまま返すこと（往復が恒等）。
        let shown = model.displayFaces(at: 1.0)
        XCTAssertEqual(shown.count, 1, "描画経路に顔が出てこない")
        XCTAssertEqual(centroidX(shown[0]), inComposition, accuracy: 1e-5,
                       "displayFaces が二重写像でずれている（顔が素通しになる）")
    }

    /// `detectedFaces[].landmarks` も**素材座標**で更新され、選択顔の照合
    /// （`selecting` は素材座標で重心を比べる）が成立すること。
    /// 合成座標で入れると照合が外れ、**選択した顔にモザイクが乗らない**。
    func test_storeLiveDetection_keepsTargetLandmarksInSourceSpace() {
        let (model, sourceID) = makeLetterboxedModel()
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.10),
                       thumbnail: UIImage(), isSelected: true, sourceID: sourceID),
            FaceTarget(id: UUID(), landmarks: fakeFace(cx: 0.90),
                       thumbnail: UIImage(), isSelected: false, sourceID: sourceID)
        ]
        // 素材 0.12 / 0.88 に相当する合成座標の 2 顔。
        let a = 0.21875 + 0.12 * 0.5625
        let b = 0.21875 + 0.88 * 0.5625
        model.storeLiveDetection([fakeFace(cx: a), fakeFace(cx: b)], at: 1.0, source: UIImage())

        XCTAssertEqual(centroidX(model.detectedFaces[0].landmarks), 0.12, accuracy: 1e-5,
                       "ターゲットの位置が合成座標で更新されている")
        XCTAssertEqual(centroidX(model.detectedFaces[1].landmarks), 0.88, accuracy: 1e-5)

        let selected = model.selectedLandmarks(at: 1.0)
        XCTAssertEqual(selected.count, 1, "選択顔の照合が座標系の混在で壊れている")
        XCTAssertEqual(centroidX(selected[0]), a, accuracy: 1e-5,
                       "選択した顔ではなく、もう片方の顔が返っている")
    }

    /// 署名は**素材座標の顔**へ結ぶこと（`FaceSignatureSample.centroid` の契約）。
    /// 合成座標で結ぶと、`selecting` が素材座標の顔で引いたときに対応が付かず、
    /// 人物同定が丸ごと無効化される（位置追跡へ黙って劣化する）。
    func test_storeLiveDetection_bindsSignaturesInSourceSpace() throws {
        let (model, sourceID) = makeLetterboxedModel()
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[0] = 1
        let signature = try XCTUnwrap(FaceSignature(rawValues: values))
        let inComposition = 0.21875 + 0.10 * 0.5625
        let face = fakeFace(cx: inComposition)
        model.storeLiveDetection([face], at: 1.0, source: UIImage(), signatures: [signature])

        let sourceFace = try XCTUnwrap(model.cacheStore.faces(sourceID: sourceID, time: 1.0)?.first)
        let looked = model.signatureCache.signatures(for: [sourceFace],
                                                     sourceID: sourceID, time: 1.0)
        XCTAssertEqual(looked.count, 1)
        XCTAssertNotNil(looked[0],
                        "素材座標の顔で署名が引けない（署名が合成座標で結ばれている）")
    }

    // MARK: - フロー橋渡し（liveFlowCache 経路）

    /// フロー由来の追跡位置も同じ逆写像を通ること。`liveFlowCache` は `lookupFaces` が
    /// `cacheStore` と同列に返すので、片方だけ座標系が違うと描画がフレーム間で飛ぶ。
    func test_storeLiveDetection_flowBridgedFacesAreInSourceSpace() {
        let (model, _) = makeLetterboxedModel()
        let inComposition = 0.21875 + 0.10 * 0.5625
        let bridged = LiveDetectionResult(faces: [fakeFace(cx: inComposition)],
                                          bridgedByFlow: true)
        model.storeLiveDetection(bridged, at: 1.0, source: UIImage())

        let flow = model.nearestFlowFaces(at: 1.0)
        XCTAssertEqual(flow.count, 1, "フロー追跡位置が liveFlowCache に入っていない")
        XCTAssertEqual(centroidX(flow[0]), 0.10, accuracy: 1e-5,
                       "フロー由来の顔が合成座標のまま保存されている")

        // 実検出が無いバケットなので、描画はフローへフォールバックする。
        let shown = model.displayFaces(at: 1.0)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(centroidX(shown[0]), inComposition, accuracy: 1e-5,
                       "フロー経路が二重写像でずれている")
    }

    // MARK: - 従来挙動（恒等レイアウト）の不変

    /// 全面配置（単一クリップ・無変換＝現行の大半の構成）では値が一切変わらないこと。
    /// この修正が既存の挙動を動かしていないことの担保。
    func test_storeLiveDetection_isUnchangedForFullFrameLayout() {
        let model = makeModel()
        let sourceID = model.currentSourceID
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        model.setTimelineForTesting(TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [])))
        // renderLayout は .identity のまま（全面）。
        let face = fakeFace(cx: 0.42, cy: 0.37)
        model.storeLiveDetection([face], at: 1.0, source: UIImage())

        XCTAssertEqual(model.cacheStore.faces(sourceID: sourceID, time: 1.0), [face],
                       "全面配置なのに値が書き換わっている（再計算誤差を入れてはならない）")
        XCTAssertEqual(model.displayFaces(at: 1.0), [face])
    }
}
