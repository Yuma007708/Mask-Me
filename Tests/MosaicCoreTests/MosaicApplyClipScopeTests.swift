import XCTest
@testable import MosaicCore

/// S11: モザイク適用区間の `clipID` アンカー化と、新しいセマンティクス
/// （区間 0 本 = 全区間 OFF / 全体を覆う区間の自動生成 / 永続化 v1→v2 変換）。
///
/// `MosaicApplyRangeTests` から分けているのは `file_length` / `type_body_length` に
/// 収めるためで、対象は同じ `MosaicApplyRange.swift` / `TimelineState.swift`。
final class MosaicApplyClipScopeTests: XCTestCase {
    private let sourceA = UUID()

    private func range(_ clip: TimelineClip, _ start: Double, _ end: Double,
                       id: UUID = UUID()) -> MosaicApplyRange {
        MosaicApplyRange(id: id, clipID: clip.id, sourceID: clip.sourceID,
                         sourceStart: start, sourceEnd: end)
    }

    // MARK: - 本件の再現（同一素材の隣接クリップへの染み出し）

    /// **同一素材を分割した A/B で、A にだけ置いた区間が B に効かないこと。**
    ///
    /// これが S11 で直したバグそのものである。旧仕様（素材アンカーのみ）では
    /// B の左端を A の区間へ被る位置までトリムした瞬間、B にもモザイクが乗った。
    func test_rangeOnClipA_doesNotLeakIntoClipB_afterTrimmingBIntoItsSourceRange() {
        // 同一素材 [0,8) を A=[0,4) / B=[4,8) に分割。
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var clipB = TimelineClip(sourceID: sourceA, sourceStart: 4, sourceEnd: 8)
        let onlyA = [range(clipA, 1, 2)]

        // B の左端を素材 1.0 までトリム = A の区間 [1,2) と素材時刻が重なる。
        clipB.sourceStart = 1.0
        let mapping = TimelineMapping(clips: [clipA, clipB])
        let effective = MosaicApplyGate.effectiveRanges(onlyA, mapping: mapping)

        // B のセグメントは帯にも出ない（I1・I2）。
        let spans = TimelineBandLayout.applySpans(ranges: onlyA, mapping: mapping)
        XCTAssertEqual(spans.count, 1, "1 本の区間が 2 セグメントに写っている（I2 違反）")
        XCTAssertEqual(spans[0].clipID, clipA.id)

        // B の素材時刻 1.5 は区間の素材範囲に入るが、clipID が違うので OFF のまま。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: effective, clipID: clipB.id,
                                                sourceID: sourceA, sourceTime: 1.5),
                       "A の区間が B に染み出している")
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: clipA.id,
                                               sourceID: sourceA, sourceTime: 1.5))

        // 合成時刻でも同じ: A の合成 [1,2) だけ ON、B 側（合成 4 以降）は全部 OFF。
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, mapping: mapping,
                                               compositionTime: 1.5, photoSourceIDs: []))
        for t in stride(from: 4.0, to: mapping.totalDuration, by: 0.25) {
            XCTAssertFalse(MosaicApplyGate.isActive(ranges: effective, mapping: mapping,
                                                    compositionTime: t, photoSourceIDs: []),
                           "B 側の合成時刻 \(t) で ON になっている")
        }
    }

    /// `merged` が clipID をまたいでマージしないこと（グループキーが sourceID だと壊れる）。
    ///
    /// 隣接した 2 クリップの区間が素材時刻で連続していても、別の区間として残ること。
    func test_merged_doesNotMergeAcrossClipIDs() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [front, back])
        // 素材時刻でぴったり隣接する 2 本（[1,2) と [2,3)）を別クリップに置く。
        let existing = [range(front, 1, 2), range(back, 2, 3)]
        // front の素材 [0.5,1) を足す（既存 [1,2) と隣接するので front 内ではマージされる）。
        let merged = MosaicApplyGate.ranges(addingCompositionInterval: 0.5, to: 1.0,
                                            mapping: mapping, existing: existing)
        XCTAssertEqual(merged.count, 2, "clipID をまたいでマージされている")
        XCTAssertEqual(merged.filter { $0.clipID == front.id }.count, 1)
        XCTAssertEqual(merged.filter { $0.clipID == back.id }.count, 1)
        let frontRange = merged.first { $0.clipID == front.id }
        XCTAssertEqual(frontRange?.sourceStart ?? .nan, 0.5, accuracy: 1e-9, "front 側は [0.5,2) へ結合")
        XCTAssertEqual(frontRange?.sourceEnd ?? .nan, 2.0, accuracy: 1e-9)
        let backRange = merged.first { $0.clipID == back.id }
        XCTAssertEqual(backRange?.sourceStart ?? .nan, 2.0, accuracy: 1e-9, "back 側は独立のまま")
        XCTAssertEqual(backRange?.sourceEnd ?? .nan, 3.0, accuracy: 1e-9)
    }

    /// 並べ替え（mapping の変化）後も素材アンカーが追従し、合成時刻ゲートの結果が
    /// 「その合成時刻に写るクリップと素材時刻」だけで決まること。
    func test_compositionGate_followsSourceAcrossReorder() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)
        let ranges = [range(back, 2, 4)]
        // back の素材 [2,4) は元の並びでは合成 [2,4)、並べ替え後は合成 [0,2)。
        let original = TimelineMapping(clips: [front, back])
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: original,
                                                compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: original,
                                               compositionTime: 3.0, photoSourceIDs: []))
        let reordered = TimelineMapping(clips: [back, front])
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: reordered,
                                               compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: reordered,
                                                compositionTime: 3.0, photoSourceIDs: []))
    }

    // MARK: - 全体を覆う区間のファクトリ

    func test_fullCoverRange_coversClipSourceRangeAndRejectsBrokenClips() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 1.5, sourceEnd: 6)
        let covered = try XCTUnwrap(MosaicApplyGate.fullCoverRange(for: clip))
        XCTAssertEqual(covered.clipID, clip.id)
        XCTAssertEqual(covered.sourceID, sourceA)
        XCTAssertEqual(covered.sourceStart, 1.5, accuracy: 1e-12)
        XCTAssertEqual(covered.sourceEnd, 6.0, accuracy: 1e-12)

        XCTAssertNil(MosaicApplyGate.fullCoverRange(
            for: TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 2)))
        XCTAssertNil(MosaicApplyGate.fullCoverRange(
            for: TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: .infinity)))

        let clips = [clip, TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 2)]
        XCTAssertEqual(MosaicApplyGate.fullCoverRanges(for: clips).count, 1, "壊れたクリップは飛ばす")
        XCTAssertTrue(MosaicApplyGate.fullCoverRanges(for: []).isEmpty)
    }

    /// 全体を覆う区間 1 本だけの状態は、そのクリップの全合成時刻で ON になること。
    func test_fullCoverRange_gatesOnForEveryCompositionTime() {
        let clips = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3),
                     TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 2, rate: 2.0)]
        let mapping = TimelineMapping(clips: clips)
        let ranges = MosaicApplyGate.fullCoverRanges(for: clips)
        XCTAssertEqual(ranges.count, 2)
        var samples = 0
        for index in 0..<401 {
            let t = mapping.totalDuration * Double(index) / 400
            guard t < mapping.totalDuration else { continue }
            samples += 1
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                   compositionTime: t, photoSourceIDs: []),
                          "compositionTime \(t) で OFF になっている")
        }
        XCTAssertEqual(samples, 400)
    }

    // MARK: - 分割・削除の追従

    /// 分割の振り分け規則（またぐ / 前半のみ / 後半のみ / はみ出し / id 継承）。
    func test_ranges_splittingDistributesAroundSplitPoint() {
        let original = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let frontID = original.id
        let backID = UUID()
        let other = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let frontOnly = range(original, 0.5, 1.5)
        let backOnly = range(original, 4, 5)
        let straddling = range(original, 2, 4)
        let outsideBefore = range(original, -3, -1)   // トリム由来のはみ出し（前方）
        let outsideAfter = range(original, 8, 9)      // トリム由来のはみ出し（後方）
        let untouched = range(other, 1, 2)

        let result = MosaicApplyGate.ranges(
            splittingClipID: original.id, atSourceTime: 3,
            frontClipID: frontID, backClipID: backID,
            existing: [frontOnly, backOnly, straddling, outsideBefore, outsideAfter, untouched])

        XCTAssertEqual(result.count, 7, "またぐ 1 本が 2 本に割れて 6 → 7 本")
        // 前半のみ・後半のみは id 据え置きで clipID だけ変わる。
        XCTAssertEqual(result[0].id, frontOnly.id)
        XCTAssertEqual(result[0].clipID, frontID)
        XCTAssertEqual(result[1].id, backOnly.id)
        XCTAssertEqual(result[1].clipID, backID)
        // またぐ区間: 前半片が元 id を継承し、後半片は新規 id。
        XCTAssertEqual(result[2].id, straddling.id)
        XCTAssertEqual(result[2].clipID, frontID)
        XCTAssertEqual(result[2].sourceEnd, 3.0, accuracy: 1e-12)
        XCTAssertNotEqual(result[3].id, straddling.id)
        XCTAssertEqual(result[3].clipID, backID)
        XCTAssertEqual(result[3].sourceStart, 3.0, accuracy: 1e-12)
        XCTAssertEqual(result[3].sourceEnd, 4.0, accuracy: 1e-12)
        // はみ出しも m を基準に前後へ振り分けて温存される。
        XCTAssertEqual(result[4].clipID, frontID)
        XCTAssertEqual(result[4].sourceStart, -3.0, accuracy: 1e-12)
        XCTAssertEqual(result[5].clipID, backID)
        XCTAssertEqual(result[5].sourceStart, 8.0, accuracy: 1e-12)
        // 他クリップの区間は素通し。
        XCTAssertEqual(result[6], untouched)

        // 非有限の分割点では無変更（他の編集操作と同じ「失敗時は無変更」契約）。
        XCTAssertEqual(MosaicApplyGate.ranges(splittingClipID: original.id, atSourceTime: .nan,
                                              frontClipID: frontID, backClipID: backID,
                                              existing: [frontOnly]),
                       [frontOnly])
    }

    /// クリップ削除でそのクリップの区間だけが消えること。
    func test_ranges_removingClipDropsOnlyItsRanges() {
        let doomed = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let kept = TimelineClip(sourceID: sourceA, sourceStart: 4, sourceEnd: 8)
        let ranges = [range(doomed, 1, 2), range(kept, 5, 6), range(doomed, 3, 4)]
        let result = MosaicApplyGate.ranges(removingClipID: doomed.id, from: ranges)
        XCTAssertEqual(result, [ranges[1]])
        XCTAssertEqual(MosaicApplyGate.ranges(removingClipID: UUID(), from: ranges), ranges)
    }

    /// `TimelineState.splitting` / `removing` が上の純関数を通していること（配線の確認）。
    func test_timelineState_splitAndRemoveKeepRangesConsistent() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        var state = TimelineState(clips: [clip])
        state.applyRanges = [range(clip, 2, 4)]

        let split = state.splitting(at: 3.0)
        XCTAssertEqual(split.clips.count, 2)
        XCTAssertEqual(split.applyRanges.count, 2, "またぐ区間が分割されていない")
        XCTAssertEqual(split.applyRanges[0].clipID, split.clips[0].id)
        XCTAssertEqual(split.applyRanges[1].clipID, split.clips[1].id)
        XCTAssertTrue(split.validate(), "分割後に clipID が実在クリップを指していない")
        // 帯とゲートは分割前後で一致し、ON になる合成時刻も変わらない（素材アンカーの効能）。
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: split.applyRanges,
                                                     mapping: split.mapping).count, 2)
        for t in stride(from: 0.0, to: 6.0, by: 0.1) {
            let before = MosaicApplyGate.isActive(ranges: state.applyRanges, mapping: state.mapping,
                                                  compositionTime: t, photoSourceIDs: [])
            let after = MosaicApplyGate.isActive(ranges: split.applyRanges, mapping: split.mapping,
                                                 compositionTime: t, photoSourceIDs: [])
            XCTAssertEqual(before, after, "分割でゲートが変わった（compositionTime \(t)）")
        }

        let removed = split.removing(clipID: split.clips[1].id)
        XCTAssertEqual(removed.applyRanges.count, 1, "削除したクリップの区間が残っている")
        XCTAssertEqual(removed.applyRanges[0].clipID, split.clips[0].id)
        XCTAssertTrue(removed.validate())
    }

    /// `moving` / `trimming` / `settingRate` は区間を**意図的に書き換えない**こと。
    func test_timelineState_moveTrimRateDoNotRewriteRanges() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clipA, clipB])
        state.applyRanges = [range(clipA, 1, 2)]

        XCTAssertEqual(state.moving(clipID: clipA.id, toIndex: 1).applyRanges, state.applyRanges)
        XCTAssertEqual(state.trimming(clipID: clipA.id, sourceStart: 0.5, sourceEnd: 3).applyRanges,
                       state.applyRanges)
        XCTAssertEqual(state.settingRate(clipID: clipA.id, rate: 2.0).applyRanges, state.applyRanges)
    }

    /// `appending` が追加クリップに「全体を覆う区間」を 1 本足すこと（既定 true）。
    func test_timelineState_appendingAddsFullCoverRange() {
        let base = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [base],
                                  applyRanges: MosaicApplyGate.fullCoverRanges(for: [base]))
        let added = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)

        let appended = state.appending(clip: added)
        XCTAssertEqual(appended.applyRanges.count, 2)
        XCTAssertEqual(appended.applyRanges[1].clipID, added.id)
        XCTAssertEqual(appended.applyRanges[1].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(appended.applyRanges[1].sourceEnd, 3, accuracy: 1e-12)
        XCTAssertTrue(appended.validate())

        XCTAssertEqual(state.appending(clip: added, coveringWithApplyRange: false).applyRanges,
                       state.applyRanges)
    }

    /// `validate` が clipID の不整合（不在クリップ・素材食い違い）を弾くこと。
    func test_validate_rejectsDanglingClipIDAndSourceMismatch() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clip])
        state.applyRanges = [range(clip, 1, 2)]
        XCTAssertTrue(state.validate())

        var dangling = state
        dangling.applyRanges = [MosaicApplyRange(clipID: UUID(), sourceID: sourceA,
                                                 sourceStart: 1, sourceEnd: 2)]
        XCTAssertFalse(dangling.validate(), "実在しない clipID の区間")

        var mismatched = state
        mismatched.applyRanges = [MosaicApplyRange(clipID: clip.id, sourceID: UUID(),
                                                   sourceStart: 1, sourceEnd: 2)]
        XCTAssertFalse(mismatched.validate(), "clipID と sourceID が食い違う区間")
    }

    /// 絞り込みのコスト実測（50 クリップ × 100 区間）。
    /// 描画ごとに回すには重すぎるが、タイムライン変更時 1 回なら無視できることを固定する。
    func test_effectiveRanges_costIsNegligiblePerTimelineChange() {
        let sources = (0..<50).map { _ in UUID() }
        let clips = sources.map { TimelineClip(sourceID: $0, sourceStart: 0, sourceEnd: 2) }
        let mapping = TimelineMapping(clips: clips)
        let ranges = (0..<100).map { index -> MosaicApplyRange in
            range(clips[index % clips.count], 0.5, 1.5)
        }
        let start = Date()
        var total = 0
        for _ in 0..<100 { total += MosaicApplyGate.effectiveRanges(ranges, mapping: mapping).count }
        let msPerCall = Date().timeIntervalSince(start) * 1000 / 100
        XCTAssertEqual(total, 100 * 100)
        XCTAssertLessThan(msPerCall, 5.0, "effectiveRanges が \(msPerCall)ms/回 と重すぎる")
        print("[S11-perf] effectiveRanges 50 clips x 100 ranges: \(msPerCall) ms/call")
    }

    /// 写真素材は素材時刻を 0 へ clamp してから判定すること
    /// （`MosaicApplyRange` 型の doc: 写真の適用区間は素材 [0, sourceEnd) を覆う）。
    func test_compositionGate_photoSourceClampsToZero() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let mapping = TimelineMapping(clips: [photo])
        let ranges = [range(photo, 0, 3)]
        for t in stride(from: 0.0, to: 3.0, by: 0.5) {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                   compositionTime: t, photoSourceIDs: [sourceA]),
                          "compositionTime \(t)")
        }
        // 素材 0 を含まない区間は写真では絶対にヒットしない（clamp 後が 0 のため）。
        let notCoveringZero = [range(photo, 1, 2)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: notCoveringZero, mapping: mapping,
                                                compositionTime: 1.5, photoSourceIDs: [sourceA]))
    }
}
