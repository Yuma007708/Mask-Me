import XCTest
@testable import MosaicCore

final class TimelineStateTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private let sourceC = UUID()

    /// A(0-4) → B(10-14) → C(20-24)、A→B と B→C にトランジション。
    private func makeState(durationAB: Double = 1.0, durationBC: Double = 1.0) -> TimelineState {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let c = TimelineClip(sourceID: sourceC, sourceStart: 20, sourceEnd: 24)
        return TimelineState(clips: [a, b, c],
                             transitions: [a.id: TransitionSpec(kind: .crossfade, duration: durationAB),
                                           b.id: TransitionSpec(kind: .wipeLeft, duration: durationBC)])
    }

    // MARK: - splitting

    /// 分割対象が先行側だったトランジションは後半クリップの id に付け替えられ、
    /// 前半と後半の間には新規トランジションが付かないこと。
    func test_splittingRekeysTransitionToBackHalf() {
        let state = makeState()
        let clipA = state.clips[0]
        let split = state.splitting(at: 2.0)  // A を [0,2) + [2,4) に分割

        XCTAssertEqual(split.clips.count, 4)
        let backID = split.clips[1].id
        XCTAssertNil(split.transitions[clipA.id], "前半（元 id）にトランジションが残ってはいけない")
        XCTAssertEqual(split.transitions[backID]?.kind, .crossfade)
        XCTAssertEqual(split.transitions[backID]?.duration ?? -1, 1.0, accuracy: 1e-9)
        // B→C のトランジションは影響を受けない。
        XCTAssertEqual(split.transitions[state.clips[1].id]?.kind, .wipeLeft)
        XCTAssertEqual(split.transitions.count, 2)
        XCTAssertTrue(split.validate())
    }

    /// 分割で短くなったクリップの duration 制約を破るトランジションはクランプされること。
    func test_splittingClampsTransitionDuration() {
        let state = makeState(durationAB: 2.0)  // cap = min(4,4)/2 = 2 で有効
        let split = state.splitting(at: 1.0)    // A を [0,1) + [1,4) に分割 → 後半 3 秒
        let backID = split.clips[1].id
        // cap = min(3, 4)/2 = 1.5 に縮む。
        XCTAssertEqual(split.transitions[backID]?.duration ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertTrue(split.validate())
    }

    /// 分割できない位置では self がそのまま返ること（透過契約）。
    func test_splittingFailureReturnsSelf() {
        let state = makeState()
        XCTAssertEqual(state.splitting(at: -1.0), state)
        XCTAssertEqual(state.splitting(at: 0.0), state)
        XCTAssertEqual(state.splitting(at: 99.0), state)
        XCTAssertEqual(state.splitting(atDisplayTime: -1.0), state)
        XCTAssertEqual(state.splitting(atDisplayTime: state.mapping.totalDuration), state)
    }

    /// splitting(atDisplayTime:) は重なり込みの表示時刻を編集時刻へ変換してから分割すること。
    /// レビュー再現ケース: A(4s)→B(4s)・crossfade D=1 で表示 5.0 は B の先頭から 2 秒
    /// （編集時刻では 6.0）であり、B が素材 12.0 で割れる。重なりなし解釈のままだと 1 秒ズレる。
    func test_splittingAtDisplayTimeUsesOverlapTimeline() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let state = TimelineState(clips: [a, b],
                                  transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 1.0)])

        let split = state.splitting(atDisplayTime: 5.0)
        XCTAssertEqual(split.clips.count, 3)
        XCTAssertEqual(split.clips[1].id, b.id)
        XCTAssertEqual(split.clips[1].sourceEnd, 12.0, accuracy: 1e-9)
        XCTAssertEqual(split.clips[2].sourceStart, 12.0, accuracy: 1e-9)

        // 重なり内の表示時刻は incoming（B）側に帰属して分割される: 表示 3.5 → B の素材 10.5。
        let inOverlap = state.splitting(atDisplayTime: 3.5)
        XCTAssertEqual(inOverlap.clips.count, 3)
        XCTAssertEqual(inOverlap.clips[1].sourceEnd, 10.5, accuracy: 1e-9)
        XCTAssertTrue(inOverlap.validate())
    }

    // MARK: - removing

    /// 削除クリップが先行側・後続側だったトランジションは両方破棄されること。
    func test_removingDropsBothSidesTransitions() {
        let state = makeState()
        let removed = state.removing(clipID: state.clips[1].id)  // B を削除
        XCTAssertEqual(removed.clips.map(\.id), [state.clips[0].id, state.clips[2].id])
        XCTAssertTrue(removed.transitions.isEmpty, "A→B と B→C の両方が破棄されるべき")
        XCTAssertTrue(removed.validate())
    }

    /// 末尾クリップの削除では、そのクリップを後続側とするトランジションだけが破棄されること。
    func test_removingTailClipDropsOnlyItsPair() {
        let state = makeState()
        let removed = state.removing(clipID: state.clips[2].id)  // C を削除
        XCTAssertEqual(removed.clips.count, 2)
        XCTAssertNil(removed.transitions[state.clips[1].id], "B→C は破棄")
        XCTAssertEqual(removed.transitions[state.clips[0].id]?.kind, .crossfade, "A→B は残る")
        XCTAssertTrue(removed.validate())
    }

    /// 削除できない場合（未知 id・最後の 1 本）は self がそのまま返ること。
    func test_removingFailureReturnsSelf() {
        let state = makeState()
        XCTAssertEqual(state.removing(clipID: UUID()), state)
        let single = TimelineState(clips: [state.clips[0]])
        XCTAssertEqual(single.removing(clipID: state.clips[0].id), single)
    }

    // MARK: - moving

    /// 移動で隣接ペアが分離したトランジションは破棄され、隣接が保たれたものだけ残ること。
    func test_movingKeepsOnlySurvivingAdjacency() {
        let state = makeState()
        // C を先頭へ: [C, A, B] → A→B は隣接維持で残り、B→C は分離で破棄。
        let moved = state.moving(clipID: state.clips[2].id, toIndex: 0)
        XCTAssertEqual(moved.clips.map(\.id),
                       [state.clips[2].id, state.clips[0].id, state.clips[1].id])
        XCTAssertEqual(moved.transitions.count, 1)
        XCTAssertEqual(moved.transitions[state.clips[0].id]?.kind, .crossfade)
        XCTAssertTrue(moved.validate())
    }

    /// 全ペアが分離する移動では全トランジションが破棄されること。
    func test_movingDropsAllWhenAllPairsSeparate() {
        let state = makeState()
        // A を中央へ: [B, A, C] → A→B・B→C とも分離。
        let moved = state.moving(clipID: state.clips[0].id, toIndex: 1)
        XCTAssertTrue(moved.transitions.isEmpty)
        XCTAssertTrue(moved.validate())
    }

    /// 移動できない場合（未知 id・同一位置）は self がそのまま返ること。
    func test_movingFailureReturnsSelf() {
        let state = makeState()
        XCTAssertEqual(state.moving(clipID: UUID(), toIndex: 0), state)
        XCTAssertEqual(state.moving(clipID: state.clips[0].id, toIndex: 0), state)
    }

    // MARK: - 並べ替え後の再生位置

    /// 掴んだクリップの中にいた再生位置が、移動先の同じ相対位置へ写ること。
    func test_compositionTimeFollowsMovedClip() throws {
        let state = makeState()
        let cID = state.clips[2].id
        let before = try XCTUnwrap(state.mapping.clipStartTime(clipID: cID)) + 1.5  // C の 1.5 秒目

        // C を先頭へ移す。移動後 C は 0 秒始まりなので、写った先は 1.5 秒。
        let moved = state.moving(clipID: cID, toIndex: 0)
        let movedStart = try XCTUnwrap(moved.mapping.clipStartTime(clipID: cID))
        let after = TimelineState.compositionTime(
            following: cID, from: state, to: moved, time: before)

        XCTAssertEqual(movedStart, 0, accuracy: 1e-9, "移動後の C は先頭にいるはず")
        XCTAssertEqual(after, 1.5, accuracy: 1e-9,
                       "掴んだクリップ内の相対位置（1.5 秒目）が保たれていない")
        // 相対位置が保たれている＝写した先でも同じ素材の同じ時刻を指す、が本質。
        let sourceBefore = try XCTUnwrap(state.mapping.sourceLocation(at: before))
        let sourceAfter = try XCTUnwrap(moved.mapping.sourceLocation(at: after))
        XCTAssertEqual(sourceBefore.clipID, cID)
        XCTAssertEqual(sourceAfter.clipID, cID, "写した先が別のクリップを指している")
        XCTAssertEqual(sourceBefore.time, sourceAfter.time, accuracy: 1e-6,
                       "写した先が別の素材時刻を指している")
    }

    /// 再生位置が掴んだクリップの外にいたときは、時刻を据え置くこと
    /// （写す先が定義できないため。据え置きは従来どおりの挙動）。
    func test_compositionTimeStaysWhenPlayheadIsOutsideMovedClip() {
        let state = makeState()
        let cID = state.clips[2].id
        let moved = state.moving(clipID: cID, toIndex: 0)
        // A の中（0.5 秒）を見ている状態で C を動かす。
        let after = TimelineState.compositionTime(
            following: cID, from: state, to: moved, time: 0.5)
        XCTAssertEqual(after, 0.5, accuracy: 1e-9)
    }

    /// 未知のクリップ id では時刻を据え置くこと（クラッシュも 0 への飛びもしない）。
    func test_compositionTimeStaysForUnknownClip() {
        let state = makeState()
        let after = TimelineState.compositionTime(
            following: UUID(), from: state, to: state, time: 2.0)
        XCTAssertEqual(after, 2.0, accuracy: 1e-9)
    }

    // MARK: - trimming / settingRate のクランプと破棄

    /// トリムで縮んだクリップの duration 制約を破るトランジションはクランプされること。
    func test_trimmingClampsTransitionDuration() {
        let state = makeState()
        // A を 1 秒に: A→B の cap = min(1, 4)/2 = 0.5 → 1.0 から 0.5 へクランプ。
        let trimmed = state.trimming(clipID: state.clips[0].id, sourceStart: 0, sourceEnd: 1)
        XCTAssertEqual(trimmed.transitions[state.clips[0].id]?.duration ?? -1, 0.5, accuracy: 1e-9)
        // B→C は影響なし。
        XCTAssertEqual(trimmed.transitions[state.clips[1].id]?.duration ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertTrue(trimmed.validate())
    }

    /// クランプ結果が最小尺（0.1 秒）ちょうどになるトランジションは破棄されず保持されること。
    func test_trimmingKeepsTransitionAtExactMinimum() {
        let state = makeState()
        // A を 0.2 秒に: cap = min(0.2, 4)/2 = 0.1 ちょうど → 0.1 へクランプして保持。
        let trimmed = state.trimming(clipID: state.clips[0].id, sourceStart: 0, sourceEnd: 0.2)
        XCTAssertEqual(trimmed.transitions[state.clips[0].id]?.duration ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertTrue(trimmed.validate())
    }

    /// クランプ結果が 0.1 秒未満になるトランジションは破棄されること。
    func test_trimmingDiscardsTooShortTransition() {
        let state = makeState()
        // A を 0.15 秒に: cap = 0.075 < 0.1 → 破棄。
        let trimmed = state.trimming(clipID: state.clips[0].id, sourceStart: 0, sourceEnd: 0.15)
        XCTAssertNil(trimmed.transitions[state.clips[0].id])
        XCTAssertEqual(trimmed.transitions.count, 1)
        XCTAssertTrue(trimmed.validate())
    }

    /// 速度変更で縮んだクリップでも同じクランプ/破棄規則が適用されること。
    func test_settingRateClampsAndDiscards() {
        let state = makeState()
        let clipB = state.clips[1]
        // B を 10x に: 合成尺 0.4 秒 → A→B と B→C の cap = 0.2 → 両方 0.2 へクランプ。
        let fast = state.settingRate(clipID: clipB.id, rate: 10)
        XCTAssertEqual(fast.transitions[state.clips[0].id]?.duration ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(fast.transitions[clipB.id]?.duration ?? -1, 0.2, accuracy: 1e-9)
        // A を 10x に（合成尺 0.4 → cap 0.2）した上で A をさらに縮める代わりに、
        // トリムで cap < 0.1 を作るケースは test_trimmingDiscardsTooShortTransition が担う。
        XCTAssertTrue(fast.validate())
    }

    /// 変更のない設定（未知 id）は self がそのまま返り、トランジションも保存されること。
    func test_editFailuresPreserveTransitions() {
        let state = makeState()
        XCTAssertEqual(state.trimming(clipID: UUID(), sourceStart: 0, sourceEnd: 1), state)
        XCTAssertEqual(state.settingRate(clipID: UUID(), rate: 2), state)
    }

    // MARK: - validate

    /// 正常な状態は validate を通り、各不変条件の違反は検出されること。
    func test_validateDetectsViolations() {
        let state = makeState()
        XCTAssertTrue(state.validate())

        var unknownKey = state
        unknownKey.transitions[UUID()] = TransitionSpec(kind: .crossfade, duration: 0.5)
        XCTAssertFalse(unknownKey.validate(), "実在しないクリップ id のキー")

        var tailKey = state
        tailKey.transitions[state.clips[2].id] = TransitionSpec(kind: .crossfade, duration: 0.5)
        XCTAssertFalse(tailKey.validate(), "末尾クリップのキー")

        var tooLong = state
        tooLong.transitions[state.clips[0].id] = TransitionSpec(kind: .crossfade, duration: 2.5)
        XCTAssertFalse(tooLong.validate(), "duration > min(両クリップ尺)/2")

        var zeroDuration = state
        zeroDuration.transitions[state.clips[0].id] = TransitionSpec(kind: .crossfade, duration: 0)
        XCTAssertFalse(zeroDuration.validate(), "duration = 0")

        var badRange = state
        badRange.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                                sourceStart: 2, sourceEnd: 2)]
        XCTAssertFalse(badRange.validate(), "sourceStart >= sourceEnd の applyRange")

        var goodRange = state
        goodRange.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                                 sourceStart: 1, sourceEnd: 2)]
        XCTAssertTrue(goodRange.validate())
    }

    /// NaN・無限大は比較を素通りして下流を黙って壊すため、validate が明示的に弾くこと。
    /// （NaN の applyRange は isActive を全時刻 false にし、モザイクが黙って消える。）
    func test_validateRejectsNonFiniteValues() {
        let state = makeState()

        var nanTransition = state
        nanTransition.transitions[state.clips[0].id] = TransitionSpec(kind: .crossfade, duration: .nan)
        XCTAssertFalse(nanTransition.validate(), "NaN duration のトランジション")

        var infiniteTransition = state
        infiniteTransition.transitions[state.clips[0].id] = TransitionSpec(kind: .crossfade, duration: .infinity)
        XCTAssertFalse(infiniteTransition.validate(), "無限大 duration のトランジション")

        var nanRange = state
        nanRange.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                                sourceStart: .nan, sourceEnd: .nan)]
        XCTAssertFalse(nanRange.validate(), "NaN の applyRange")

        var infiniteRange = state
        infiniteRange.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                                     sourceStart: 0, sourceEnd: .infinity)]
        XCTAssertFalse(infiniteRange.validate(), "無限大 sourceEnd の applyRange")
    }

    // MARK: - Codable

    /// transitions・applyRanges 込みのエンコード→デコード round-trip が一致すること。
    func test_codableRoundTrip() throws {
        var state = makeState()
        state.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                             sourceStart: 0.5, sourceEnd: 2.5)]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    /// mapping プロパティがトランジションの重なりを反映すること。
    func test_mappingIncludesTransitions() {
        let state = makeState()
        // 合成尺 4+4+4 − (1+1) = 10 秒。
        XCTAssertEqual(state.mapping.totalDuration, 10.0, accuracy: 1e-9)
    }

    // MARK: - トランジションの編集 API（S9）

    /// 上限は min(両クリップ合成尺)/2。末尾クリップ・不在 id では nil。
    func test_maximumTransitionDuration() {
        let short = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let long = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [short, long])

        XCTAssertEqual(state.maximumTransitionDuration(afterClipID: short.id) ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertNil(state.maximumTransitionDuration(afterClipID: long.id), "末尾クリップには継ぎ目が無い")
        XCTAssertNil(state.maximumTransitionDuration(afterClipID: UUID()))
    }

    /// 上限が最小尺を下回る境界では設定できない（設定 API も nil 判定と一致する）。
    func test_maximumTransitionDuration_tooShortClipsCannotHost() {
        let tiny = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 0.15)
        let next = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 5)
        let state = TimelineState(clips: [tiny, next])

        XCTAssertNil(state.maximumTransitionDuration(afterClipID: tiny.id))
        let attempted = state.settingTransition(afterClipID: tiny.id, kind: .crossfade, duration: 0.5)
        XCTAssertEqual(attempted, state, "設定不可な境界では self を返す")
    }

    func test_settingTransition_addsAndReplaces() {
        let state = makeState(durationAB: 1.0, durationBC: 1.0)
        let clipA = state.clips[0]

        let changed = state.settingTransition(afterClipID: clipA.id, kind: .slideLeft, duration: 1.5)
        XCTAssertEqual(changed.transitions[clipA.id]?.kind, .slideLeft)
        XCTAssertEqual(changed.transitions[clipA.id]?.duration ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(changed.transitions.count, 2, "他の境界は変わらない")
        XCTAssertTrue(changed.validate())
        // 合成尺は重なり長ぶんだけ縮む: 12 − (1.5 + 1) = 9.5
        XCTAssertEqual(changed.mapping.totalDuration, 9.5, accuracy: 1e-9)
    }

    /// duration は min(両クリップ合成尺)/2 へクランプされる（`validate` を破らない）。
    func test_settingTransition_clampsDuration() {
        let state = makeState()
        let clipA = state.clips[0]
        let clamped = state.settingTransition(afterClipID: clipA.id, kind: .fadeToBlack, duration: 99)

        XCTAssertEqual(clamped.transitions[clipA.id]?.duration ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertTrue(clamped.validate())
    }

    /// 最小尺未満・非有限の duration は最小尺へ持ち上げる／拒否する。
    func test_settingTransition_rejectsNonFiniteAndLiftsBelowMinimum() {
        let state = makeState()
        let clipA = state.clips[0]

        let lifted = state.settingTransition(afterClipID: clipA.id, kind: .crossfade, duration: 0.001)
        XCTAssertEqual(lifted.transitions[clipA.id]?.duration ?? -1,
                       TransitionSpec.minimumDuration, accuracy: 1e-9)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(state.settingTransition(afterClipID: clipA.id, kind: .crossfade, duration: value),
                           state, "非有限の duration は設定しない（self を返す）")
        }
    }

    func test_removingTransition() {
        let state = makeState()
        let clipA = state.clips[0]
        let removed = state.removingTransition(afterClipID: clipA.id)

        XCTAssertNil(removed.transitions[clipA.id])
        XCTAssertEqual(removed.transitions.count, 1)
        XCTAssertEqual(removed.mapping.totalDuration, 11.0, accuracy: 1e-9)
        XCTAssertEqual(removed.removingTransition(afterClipID: clipA.id), removed, "無ければ self")
    }

    /// applyRanges / sources は トランジション編集で失われないこと。
    func test_transitionEditsPreserveApplyRangesAndSources() {
        var state = makeState()
        state.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: sourceA,
                                             sourceStart: 0, sourceEnd: 1)]
        state.sources = [sourceA: TimelineSource(id: sourceA, kind: .photo)]

        let changed = state.settingTransition(afterClipID: state.clips[0].id, kind: .slideRight, duration: 0.5)
        XCTAssertEqual(changed.applyRanges, state.applyRanges)
        XCTAssertEqual(changed.sources, state.sources)
        XCTAssertEqual(changed.removingTransition(afterClipID: state.clips[0].id).applyRanges, state.applyRanges)
    }

}
