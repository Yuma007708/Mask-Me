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
        badRange.applyRanges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 2, sourceEnd: 2)]
        XCTAssertFalse(badRange.validate(), "sourceStart >= sourceEnd の applyRange")

        var goodRange = state
        goodRange.applyRanges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
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
        nanRange.applyRanges = [MosaicApplyRange(sourceID: sourceA, sourceStart: .nan, sourceEnd: .nan)]
        XCTAssertFalse(nanRange.validate(), "NaN の applyRange")

        var infiniteRange = state
        infiniteRange.applyRanges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: .infinity)]
        XCTAssertFalse(infiniteRange.validate(), "無限大 sourceEnd の applyRange")
    }

    // MARK: - Codable

    /// transitions・applyRanges 込みのエンコード→デコード round-trip が一致すること。
    func test_codableRoundTrip() throws {
        var state = makeState()
        state.applyRanges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0.5, sourceEnd: 2.5)]
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
}
