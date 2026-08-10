import AVFoundation
import XCTest
import MosaicCore
@testable import MaskMe

/// 第3段: 範囲指定サーチが置いた暫定矩形（`ObjectMask.isRegionPlaceholder == true`）を、
/// 第2段のシード走査結果の台帳（`regionPlaceholderLedgers`）に基づいて外す（または残す）機能。
///
/// `MosaicEditorModel+RegionPlaceholder.swift`（判定・反映・台帳）を対象にする。
///
/// この環境には MediaPipe pod が無く `makeFaceLandmarker` は常に候補ゼロの
/// `NullFaceLandmarker` を返すため、`detectInRegion` / `resolveRegion` の「見つかった」
/// 分岐を経由した実シードは作れない。そのため台帳（`regionPlaceholderLedgers`）を
/// 直接組み立てて `finalizeRegionPlaceholder(maskID:)` を呼ぶ形に統一する。
@MainActor
final class RegionPlaceholderFinalizeTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .video, recents: RecentItemsStore())
    }

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

    /// 素材時刻 `span` を `step` 刻みでちょうど覆う被覆時刻列（両端含む）。
    private func fullCoverage(_ span: ClosedRange<Double>, step: Double = 0.5) -> [Double] {
        var times: [Double] = []
        var t = span.lowerBound
        while t <= span.upperBound + 1e-9 {
            times.append(t)
            t += step
        }
        return times
    }

    /// 全区間を被覆したシナリオを組み立てる。矩形内に顔がある状態で、対応する
    /// `RegionSeed` / `FaceTarget` / 台帳（`RegionPlaceholderLedger`）を用意する。
    private func makeFullyCoveredScenario(span: ClosedRange<Double> = 0...3, rate: Double = 1.0)
        -> (model: MosaicEditorModel, maskID: UUID, seed: MosaicEditorModel.RegionSeed) {
        let model = makeModel()
        let source = model.currentSourceID
        let asset = dummyAsset()
        model.sources[source] = asset
        let clip = TimelineClip(sourceID: source,
                               sourceStart: span.lowerBound, sourceEnd: span.upperBound, rate: rate)
        model.setClipsForTesting([clip])
        model.faceMosaicOn = true

        let seedFace = fakeFace(cx: 0.2, cy: 0.2)
        guard let maskID = model.appendObjectMask(
            compositionRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)) else {
            fatalError("テスト前提: appendObjectMask がマスクを作れなかった")
        }
        let targetID = UUID()
        model.detectedFaces = [FaceTarget(id: targetID, landmarks: seedFace, thumbnail: UIImage(),
                                          isSelected: true, sourceID: source)]
        let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: asset, sourceRange: span,
                                                clipID: clip.id, seedTime: span.lowerBound,
                                                seedLandmarks: seedFace, targetID: targetID,
                                                personID: nil, maskID: maskID)
        installLedger(model, maskID: maskID, seed: seed,
                      coveredSourceTimes: fullCoverage(span))
        return (model, maskID, seed)
    }

    /// 台帳（`RegionPlaceholderLedger`）を1シードぶん組み立てて `regionPlaceholderLedgers` へ入れる。
    private func installLedger(_ model: MosaicEditorModel, maskID: UUID,
                               seed: MosaicEditorModel.RegionSeed,
                               coveredSourceTimes: [Double],
                               identityConfirmations: Int = 0,
                               isComplete: Bool = true,
                               generation: Int? = nil,
                               expectedSeeds: Int = 1,
                               isDisqualified: Bool = false) {
        guard let mask = model.objectMasks.first(where: { $0.id == maskID }) else {
            fatalError("テスト前提: maskID に対応するマスクが無い")
        }
        let result = MosaicEditorModel.RegionSeedScanResult(
            seed: seed, generation: generation ?? model.regionSeedGeneration,
            coveredSourceTimes: coveredSourceTimes, identityConfirmations: identityConfirmations,
            isComplete: isComplete)
        model.regionPlaceholderLedgers[maskID] = MosaicEditorModel.RegionPlaceholderLedger(
            clipID: seed.clipID, sourceID: seed.sourceID, snapshot: mask,
            seedTargetIDs: [seed.targetID], expectedSeeds: expectedSeeds,
            finished: [result], isDisqualified: isDisqualified)
    }

    // MARK: - ハッピーパス

    func test_finalize_removesMaskWhenScanCoveredWholeClip() {
        let (model, maskID, _) = makeFullyCoveredScenario()

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertFalse(model.objectMasks.contains { $0.id == maskID },
                       "全区間を被覆しているのに暫定矩形が残っている")
    }

    // MARK: - 被覆時刻の出所は台帳だけ

    /// 台帳の被覆は冒頭の 1 点だけ。矩形内に別人がいて `detectedFaces` /
    /// 検出キャッシュに全区間その別人の顔が乗っていても、台帳が見ていない以上
    /// 被覆と数えてはいけない。
    func test_finalize_keepsMaskWhenOtherPersonCoversHole() {
        let span = 0.0...3.0
        let (model, maskID, seed) = makeFullyCoveredScenario(span: span)
        // 台帳の被覆をシード時刻 1 点だけに絞る（穴だらけ）。
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: [seed.seedTime])
        // 別人の顔を検出キャッシュ・選択顔へ全区間分置く。
        let otherFace = fakeFace(cx: 0.8, cy: 0.8)
        var t = span.lowerBound
        while t <= span.upperBound + 1e-9 {
            model.cacheStore.store([otherFace], sourceID: seed.sourceID, time: t)
            t += 0.1
        }
        model.detectedFaces.append(FaceTarget(id: UUID(), landmarks: otherFace, thumbnail: UIImage(),
                                              isSelected: true, sourceID: seed.sourceID))

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "別人の顔で穴が埋まったかのように矩形を外してしまっている")
    }

    /// 穴の区間を `liveFlowCache`（フロー由来。書き出しは通らない）にだけ入れても、
    /// 台帳の被覆判定には一切影響しないこと。
    func test_finalize_keepsMaskWhenOnlyFlowCacheFillsHole() {
        let span = 0.0...3.0
        let (model, maskID, seed) = makeFullyCoveredScenario(span: span)
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: [seed.seedTime])
        let flowFace = fakeFace(cx: 0.2, cy: 0.2)
        var t = span.lowerBound
        while t <= span.upperBound + 1e-9 {
            model.liveFlowCache[DetectionCacheKey(sourceID: seed.sourceID, time: t,
                                                  bucketFPS: model.liveBucketFPS)] = [flowFace]
            t += 0.1
        }

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "liveFlowCache だけで埋まった穴を被覆と誤認して矩形を外してしまっている")
    }

    // MARK: - 台帳の整合性

    func test_finalize_twoSeedsOneStillRunning_keepsMask() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        // 2 本のシードが積まれる想定だが、1 本目しか完走していない。
        installLedger(model, maskID: maskID, seed: seed,
                      coveredSourceTimes: fullCoverage(seed.sourceRange), expectedSeeds: 2)

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "まだ走査中のシードが残っているのに矩形を外してしまっている")
    }

    /// 同じ maskID に 2 本積んだ後 `cancelRegionSeeding()` を挟み、遅延して届いた
    /// （中止前の）走査結果が台帳を復活させないこと。
    func test_finalize_abortedScanDoesNotResurrect() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        installLedger(model, maskID: maskID, seed: seed,
                      coveredSourceTimes: fullCoverage(seed.sourceRange), expectedSeeds: 2)
        let staleGeneration = model.regionSeedGeneration

        model.cancelRegionSeeding() // 台帳を空にし、世代を進める

        let staleResult = MosaicEditorModel.RegionSeedScanResult(
            seed: seed, generation: staleGeneration,
            coveredSourceTimes: fullCoverage(seed.sourceRange),
            identityConfirmations: 0, isComplete: true)
        model.recordRegionSeedScanResult(staleResult)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "中止した走査の遅延結果でマスクが復活してしまっている")
    }

    /// 走査が**完走しなかった**（途中でキャンセルされた／世代が進んで打ち切られた）結果は、
    /// 世代が現在と一致していても採用してはならない。
    ///
    /// 途中までしか検出キャッシュを埋めていない走査の被覆時刻は、その時点までの区間しか
    /// 意味を持たない。それを完走した走査と同じに扱うと、走り切っていない区間を
    /// 「覆えた」と誤認して矩形を外す（＝素通しになる）。
    ///
    /// `test_finalize_abortedScanDoesNotResurrect` は**世代の食い違い**を見ており、
    /// `isComplete` の門番は素通ししていた（実際、`recordRegionSeedScanResult` から
    /// `result.isComplete` を落としても全テストが通ってしまう状態だった）。
    func test_finalize_incompleteScanIsRejectedEvenAtCurrentGeneration() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        installLedger(model, maskID: maskID, seed: seed,
                      coveredSourceTimes: [], expectedSeeds: 1)
        model.regionPlaceholderLedgers[maskID]?.finished = []

        // 被覆は完璧（＝ `isComplete` 以外のすべての条件を満たす）だが、走り切っていない。
        let incomplete = MosaicEditorModel.RegionSeedScanResult(
            seed: seed, generation: model.regionSeedGeneration,
            coveredSourceTimes: fullCoverage(seed.sourceRange),
            identityConfirmations: 0, isComplete: false)
        model.recordRegionSeedScanResult(incomplete)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "完走していない走査の結果で矩形が外れている")
        XCTAssertTrue(model.regionPlaceholderLedgers[maskID]?.isDisqualified ?? false,
                      "完走していない走査を受けた台帳が失格になっていない")
    }

    func test_finalize_queueOverflowDisqualifiesMask() {
        let model = makeModel()
        let source = model.currentSourceID
        let asset = dummyAsset()
        model.sources[source] = asset
        let clip = TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 100)
        model.setClipsForTesting([clip])
        model.faceMosaicOn = true
        guard let maskID = model.appendObjectMask(
            compositionRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)) else {
            return XCTFail("appendObjectMask がマスクを作れなかった")
        }
        for i in 0..<9 {
            let seed = MosaicEditorModel.RegionSeed(sourceID: source, asset: asset, sourceRange: 0...100,
                                                    clipID: clip.id, seedTime: Double(i),
                                                    seedLandmarks: fakeFace(cx: 0.2, cy: 0.2),
                                                    targetID: UUID(), personID: nil, maskID: maskID)
            model.enqueueRegionSeed(seed)
        }

        XCTAssertEqual(model.regionPlaceholderLedgers[maskID]?.isDisqualified, true,
                       "FIFO 上限で捨てられたシードの maskID が失格になっていない")
    }

    func test_finalize_keepsMaskWhenSeedClipDiffersFromMaskClip() {
        let model = makeModel()
        let sourceA = model.currentSourceID
        let sourceB = UUID()
        model.sources[sourceA] = dummyAsset()
        model.sources[sourceB] = dummyAsset()
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 3)
        model.setClipsForTesting([clipA, clipB])
        model.faceMosaicOn = true
        guard let maskID = model.appendObjectMask(
            compositionRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)) else {
            return XCTFail("appendObjectMask がマスクを作れなかった")
        }
        // マスクはクリップ A にアンカーされているはず。シードはクリップ B。
        let targetID = UUID()
        model.detectedFaces = [FaceTarget(id: targetID, landmarks: fakeFace(cx: 0.2, cy: 0.2),
                                          thumbnail: UIImage(), isSelected: true, sourceID: sourceB)]
        let seed = MosaicEditorModel.RegionSeed(sourceID: sourceB, asset: dummyAsset(), sourceRange: 0...3,
                                                clipID: clipB.id, seedTime: 0,
                                                seedLandmarks: fakeFace(cx: 0.2, cy: 0.2),
                                                targetID: targetID, personID: nil, maskID: maskID)
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: fullCoverage(0...3))

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "シードのクリップとマスクのクリップが食い違うのに矩形を外してしまっている")
    }

    func test_finalize_keepsMaskWhenUserMovedRect() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        let mask = model.objectMasks.first { $0.id == maskID }!
        // ユーザーがキーフレームを足して矩形を動かした（＝もう「置いたままの暫定矩形」ではない）。
        model.setObjectMaskKeyframe(maskID, compositionRect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                                    angle: 0)
        XCTAssertNotEqual(model.objectMasks.first { $0.id == maskID }, mask,
                          "テスト前提: setObjectMaskKeyframe がマスクを変えていない")

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "ユーザーが編集した矩形を、被覆判定に基づいて外してしまっている")
    }

    func test_finalize_isIdempotentOnFailingVerdict() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        // 被覆をシード時刻 1 点だけに絞って不合格にする。
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: [seed.seedTime])

        model.finalizeRegionPlaceholder(maskID: maskID)
        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "1回目: 被覆できていないのに矩形を外してしまっている")
        XCTAssertNil(model.regionPlaceholderLedgers[maskID],
                    "1回目の呼び出し後も台帳が consume（削除）されていない")

        model.finalizeRegionPlaceholder(maskID: maskID)
        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "2回目: 状態が変わってしまっている（idempotent でない）")
    }

    func test_finalize_keepsMaskWhenSeedTargetDeselected() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        guard let index = model.detectedFaces.firstIndex(where: { $0.id == seed.targetID }) else {
            return XCTFail("テスト前提: シードの FaceTarget が detectedFaces に無い")
        }
        model.detectedFaces[index].isSelected = false

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "シードの FaceTarget の選択が外れているのに矩形を外してしまっている")
    }

    func test_finalize_keepsMaskWhenApplyRangeDoesNotCoverClip() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        let clip = model.clips[0]
        // 適用区間をクリップの前半だけに縮める（[1, 3) が未適用のまま残る）。
        let partial = MosaicApplyRange(clipID: clip.id, sourceID: clip.sourceID,
                                       sourceStart: clip.sourceStart, sourceEnd: 1)
        model.setTimelineForTesting(TimelineState(clips: model.clips, applyRanges: [partial]))

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "適用区間がクリップ全体を覆っていないのに矩形を外してしまっている")
    }

    func test_finalize_keepsMaskWhenClipParticipatesInTransition() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        let clip = model.clips[0]
        model.setTimelineForTesting(TimelineState(clips: model.clips,
                                                  transitions: [clip.id: TransitionSpec(kind: .crossfade,
                                                                                        duration: 0.5)],
                                                  applyRanges: model.timeline.applyRanges))

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "クリップがトランジションに関与しているのに矩形を外してしまっている")
    }

    func test_finalize_keepsMaskWhenMaskIsNotRegionPlaceholder() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        guard let index = model.objectMasks.firstIndex(where: { $0.id == maskID }) else {
            return XCTFail("テスト前提: マスクが無い")
        }
        let original = model.objectMasks[index]
        guard let flipped = ObjectMask(id: original.id, anchor: original.anchor,
                                       keyframes: original.keyframes, isRegionPlaceholder: false) else {
            return XCTFail("テスト前提: ObjectMask を作り直せなかった")
        }
        model.objectMasks[index] = flipped
        // snapshot は「現在のマスク」（flipped 後）と一致させる（指紋不一致ではなく
        // isRegionPlaceholder ガード単体を検証するため）。`installLedger` はこの時点の
        // マスクをそのままスナップショットとして使う。
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: fullCoverage(seed.sourceRange))

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "isRegionPlaceholder が false のマスクを処理してしまっている")
    }

    func test_finalize_keepsMaskOnSlowRateClip() {
        // rate=1 なら 0.5 秒刻みの被覆は合格するが、rate=0.1（スロー）では
        // 合成秒の穴が 10 倍に広がり不合格になる。
        let (model, maskID, _) = makeFullyCoveredScenario(rate: 0.1)

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "rate を評価に渡していない（低 rate クリップで不合格になるべき被覆を合格させている）")
    }

    func test_finalize_keepsMaskWhenSourceRemoved() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        model.sources[seed.sourceID] = nil

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "素材が消えた後に矩形を外してしまっている")
    }

    func test_finalize_keepsMaskAfterGenerationAdvances() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        model.regionSeedGeneration += 1 // cancelRegionSeeding を経由しない世代前進を模す

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "世代が進んだ後の古い評価で矩形を外してしまっている")
    }

    func test_finalize_keepsMaskWhenFaceMosaicOff() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        model.faceMosaicOn = false

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertTrue(model.objectMasks.contains { $0.id == maskID },
                      "faceMosaicOn が false なのに矩形を外してしまっている")
    }

    func test_finalize_doesNotReadOrWriteDetectionCache() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        let cacheCountBefore = model.cacheStore.count
        let signatureCountBefore = model.signatureCache.count

        model.finalizeRegionPlaceholder(maskID: maskID)

        XCTAssertEqual(model.cacheStore.count, cacheCountBefore,
                       "被覆判定・反映が検出キャッシュへ書き込んでしまっている")
        XCTAssertEqual(model.signatureCache.count, signatureCountBefore,
                       "被覆判定・反映が署名キャッシュへ書き込んでしまっている")

        // 巨大クリップでも検出キャッシュを読みに行かず即座に返ること。
        let (bigModel, bigMaskID, _) = makeFullyCoveredScenario(span: 0...3600)
        let bigCacheCountBefore = bigModel.cacheStore.count
        bigModel.finalizeRegionPlaceholder(maskID: bigMaskID)
        XCTAssertEqual(bigModel.cacheStore.count, bigCacheCountBefore,
                       "巨大クリップの判定で検出キャッシュに触れている")
    }

    func test_finalize_removalIsUndoable() {
        let (model, maskID, _) = makeFullyCoveredScenario()

        model.finalizeRegionPlaceholder(maskID: maskID)
        XCTAssertFalse(model.objectMasks.contains { $0.id == maskID })

        model.undo()

        XCTAssertEqual(model.objectMasks.first { $0.id == maskID }?.isRegionPlaceholder, true,
                       "undo で暫定矩形が isRegionPlaceholder のまま戻っていない")
    }

    func test_finalize_undoRestoresObjectTrack() {
        let (model, maskID, _) = makeFullyCoveredScenario()
        let mask = model.objectMasks.first { $0.id == maskID }!
        guard let segment = ObjectTrack.Segment(samples: [
            .init(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            .init(sourceTime: 1, rect: CGRect(x: 0.15, y: 0.15, width: 0.2, height: 0.2))
        ]) else { return XCTFail("テスト前提: ObjectTrack.Segment を作れなかった") }
        let track = ObjectTrack(maskID: maskID, clipID: mask.anchor.clipID!, sourceID: mask.anchor.sourceID!,
                                keyframes: mask.keyframes, segments: [segment])
        model.objectTracks[maskID] = track

        model.finalizeRegionPlaceholder(maskID: maskID)
        XCTAssertFalse(model.objectMasks.contains { $0.id == maskID })

        model.undo()

        XCTAssertEqual(model.objectMasks.first { $0.id == maskID }?.isRegionPlaceholder, true)
        XCTAssertNotNil(model.objectTracks[maskID],
                        "finalize が objectTracks[maskID] を nil にしたため undo で軌跡が失われている")
    }

    func test_cancelRegionSeeding_clearsLedgers() {
        let (model, maskID, seed) = makeFullyCoveredScenario()
        installLedger(model, maskID: maskID, seed: seed, coveredSourceTimes: fullCoverage(seed.sourceRange))

        model.cancelRegionSeeding()

        XCTAssertTrue(model.regionPlaceholderLedgers.isEmpty,
                      "cancelRegionSeeding が regionPlaceholderLedgers を空にしていない")
    }
}
