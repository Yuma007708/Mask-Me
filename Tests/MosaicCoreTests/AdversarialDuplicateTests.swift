import XCTest
@testable import MosaicCore

/// C（検証）担当・敵対的テスト: 「複製」機能で壊れる操作列を探す。
/// 対象: `TimelineState.duplicating(clipID:)` / `TimelineEditOperations.duplicate`。
/// 最重要観点: 複製したクリップと元クリップでモザイクの掛かり方が食い違わないか
/// （`MosaicApplyGate` の実ゲート判定を通して確認する。フィールド値の一致だけでは
/// 「ゲートが実際に開くか」までは分からないため）。
final class AdversarialDuplicateTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private let sourceC = UUID()
    private let photoSource = UUID()

    // MARK: - 1. ゲート実判定でのモザイク食い違い

    /// 部分適用（クリップの一部だけにモザイク区間がある）クリップを複製したとき、
    /// 複製先の同じ相対素材時刻でも同じ ON/OFF になること。
    func test_gateParity_partialApplyRange() {
        var state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)])
        let original = state.clips[0]
        // 素材時刻 [2, 6) だけモザイクON。
        state.applyRanges = [MosaicApplyRange(clipID: original.id, sourceID: sourceA,
                                              sourceStart: 2, sourceEnd: 6)]
        XCTAssertTrue(state.validate())

        let duplicated = state.duplicating(clipID: original.id)
        XCTAssertTrue(duplicated.validate())
        let copy = duplicated.clips[1]
        XCTAssertNotEqual(copy.id, original.id)

        let effective = MosaicApplyGate.effectiveRanges(duplicated.applyRanges, mapping: duplicated.mapping)
        for t in stride(from: 0.0, through: 9.9, by: 0.5) {
            let onOriginal = MosaicApplyGate.isActive(ranges: effective, clipID: original.id,
                                                       sourceID: sourceA, sourceTime: t)
            let onCopy = MosaicApplyGate.isActive(ranges: effective, clipID: copy.id,
                                                  sourceID: sourceA, sourceTime: t)
            XCTAssertEqual(onOriginal, onCopy, "sourceTime=\(t) で元クリップと複製先のゲートが食い違う")
        }
    }

    /// rate != 1（倍速/スロー）のクリップを複製したとき、素材時刻ベースのゲートは
    /// rate に依存しないので一致するはず。
    func test_gateParity_withNonUnitRate() {
        var state = TimelineState(clips: [
            TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10, rate: 3.0)
        ])
        let original = state.clips[0]
        state.applyRanges = [MosaicApplyRange(clipID: original.id, sourceID: sourceA,
                                              sourceStart: 1, sourceEnd: 9)]
        let duplicated = state.duplicating(clipID: original.id)
        XCTAssertTrue(duplicated.validate())
        let copy = duplicated.clips[1]
        XCTAssertEqual(copy.rate, 3.0, accuracy: 1e-9)

        let effective = MosaicApplyGate.effectiveRanges(duplicated.applyRanges, mapping: duplicated.mapping)
        for t in stride(from: 0.0, through: 9.9, by: 0.3) {
            let onOriginal = MosaicApplyGate.isActive(ranges: effective, clipID: original.id,
                                                       sourceID: sourceA, sourceTime: t)
            let onCopy = MosaicApplyGate.isActive(ranges: effective, clipID: copy.id,
                                                  sourceID: sourceA, sourceTime: t)
            XCTAssertEqual(onOriginal, onCopy, "rate=3.0 sourceTime=\(t) で食い違う")
        }
    }

    /// 写真クリップを複製しても、写真の `sourceStart == 0` 不変条件を保ったまま
    /// ゲートが一致すること。
    func test_gateParity_photoClip() {
        var state = TimelineState(clips: [
            TimelineClip(sourceID: photoSource, sourceStart: 0, sourceEnd: 3)
        ], sources: [photoSource: TimelineSource(id: photoSource, kind: .photo)])
        let original = state.clips[0]
        state.applyRanges = [MosaicApplyRange(clipID: original.id, sourceID: photoSource,
                                              sourceStart: 0, sourceEnd: 3)]
        let duplicated = state.duplicating(clipID: original.id)
        XCTAssertTrue(duplicated.validate(), "写真の複製後も validate() を満たす（sourceStart==0 不変条件含む）")
        let copy = duplicated.clips[1]
        let copyRange = duplicated.applyRanges.first { $0.clipID == copy.id }
        XCTAssertEqual(copyRange?.sourceStart, 0)
    }

    // MARK: - 2. 合成時刻ゲート（トランジション込み）での食い違い

    /// 両隣にトランジションがある「真ん中のクリップ」を複製したとき、
    /// 複製先の合成時刻ゲートが元クリップと矛盾しないこと。
    func test_middleClipWithBothTransitions_duplicate() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let c = TimelineClip(sourceID: sourceC, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [a, b, c],
                                  transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 1.0),
                                                b.id: TransitionSpec(kind: .wipeLeft, duration: 1.0)])
        state.applyRanges = [MosaicApplyRange(clipID: b.id, sourceID: sourceB, sourceStart: 0, sourceEnd: 4)]
        XCTAssertTrue(state.validate())

        let duplicated = state.duplicating(clipID: b.id)
        XCTAssertTrue(duplicated.validate())
        XCTAssertEqual(duplicated.clips.count, 4)
        let copy = duplicated.clips[2] // A, B, copy, C の順のはず
        XCTAssertEqual(copy.sourceID, sourceB)

        // A→B の crossfade は残る、B→copy には何もない、copy→C に wipeLeft が付け替わる。
        XCTAssertEqual(duplicated.transitions[a.id]?.kind, .crossfade)
        XCTAssertNil(duplicated.transitions[b.id])
        XCTAssertEqual(duplicated.transitions[copy.id]?.kind, .wipeLeft)

        // モザイクは B にも copy にも及んでいるはず（両方 sourceB の全区間を覆う）。
        let effective = MosaicApplyGate.effectiveRanges(duplicated.applyRanges, mapping: duplicated.mapping)
        for t in stride(from: 0.0, through: 3.9, by: 0.4) {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: b.id,
                                                    sourceID: sourceB, sourceTime: t))
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: copy.id,
                                                    sourceID: sourceB, sourceTime: t))
        }

        // 合成時刻ゲート（gateState）でも、B・copy が画面に映っている区間では
        // モザイクが有効であること（A のみの区間はそもそも区間の対象外なので除く）。
        guard let bSpan = duplicated.mapping.clipSpans.first(where: { $0.clip.id == b.id }),
              let copySpan = duplicated.mapping.clipSpans.first(where: { $0.clip.id == copy.id })
        else { return XCTFail("span not found") }
        for span in [bSpan, copySpan] {
            var t = span.start + 0.01
            while t < span.end - 0.01 {
                let active = MosaicApplyGate.isActive(ranges: effective, mapping: duplicated.mapping,
                                                      compositionTime: t, photoSourceIDs: [])
                XCTAssertTrue(active, "compositionTime=\(t) でモザイクが外れている（B/copy 区間のはず）")
                t += 0.25
            }
        }
    }

    // MARK: - 3. 繰り返し複製

    /// 複製を何十回も繰り返しても id の一意性・尺・不変条件が破綻しないこと。
    func test_repeatedDuplication_50Times() {
        var state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)])
        let originalID = state.clips[0].id
        state.applyRanges = [MosaicApplyRange(clipID: originalID, sourceID: sourceA,
                                              sourceStart: 0, sourceEnd: 2)]
        var current = state
        var lastInserted = originalID
        for i in 0..<50 {
            let before = Set(current.clips.map(\.id))
            current = current.duplicating(clipID: lastInserted)
            XCTAssertTrue(current.validate(), "50回中\(i)回目で不変条件が破れた")
            guard let newID = current.clips.first(where: { !before.contains($0.id) })?.id else {
                XCTFail("\(i)回目で複製が失敗した")
                return
            }
            lastInserted = newID
        }
        XCTAssertEqual(current.clips.count, 51)
        XCTAssertEqual(Set(current.clips.map(\.id)).count, 51, "id が衝突した")
        XCTAssertEqual(current.applyRanges.count, 51, "各複製にモザイク区間が1本ずつ付いているはず")

        // 全クリップ、全域でモザイクが有効であること。
        let effective = MosaicApplyGate.effectiveRanges(current.applyRanges, mapping: current.mapping)
        for clip in current.clips {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: clip.id,
                                                    sourceID: sourceA, sourceTime: 1.0),
                          "clip \(clip.id) にモザイクが効いていない")
        }
        XCTAssertEqual(current.mapping.totalDuration, 2.0 * 51, accuracy: 1e-6)
    }

    // MARK: - 4. 複製→分割→複製

    /// 複製したクリップをさらに分割し、その前半をまた複製する、という操作列で
    /// モザイク区間が消失・二重化しないこと。
    func test_duplicateThenSplitThenDuplicate() {
        var state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)])
        let original = state.clips[0]
        state.applyRanges = [MosaicApplyRange(clipID: original.id, sourceID: sourceA,
                                              sourceStart: 0, sourceEnd: 10)]

        let afterDup = state.duplicating(clipID: original.id)
        XCTAssertTrue(afterDup.validate())
        let copy = afterDup.clips[1]

        // copy を合成時刻 15 (= 10 + 5) で分割 = 素材時刻 5 で分割。
        let afterSplit = afterDup.splitting(at: 15.0)
        XCTAssertTrue(afterSplit.validate())
        XCTAssertEqual(afterSplit.clips.count, 3, "分割で3クリップになっているはず")

        let front = afterSplit.clips[1]
        let back = afterSplit.clips[2]
        XCTAssertEqual(front.id, copy.id, "分割前半は元の複製先 id を引き継ぐ")

        let afterDup2 = afterSplit.duplicating(clipID: front.id)
        XCTAssertTrue(afterDup2.validate())
        XCTAssertEqual(afterDup2.clips.count, 4)

        // 全区間で有効性を確認（元クリップ0-10、分割前半0-5とその複製、分割後半5-10）。
        let effective = MosaicApplyGate.effectiveRanges(afterDup2.applyRanges, mapping: afterDup2.mapping)
        for clip in afterDup2.clips {
            let mid = (clip.sourceStart + clip.sourceEnd) / 2
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: clip.id,
                                                    sourceID: sourceA, sourceTime: mid),
                          "clip \(clip.id) [\(clip.sourceStart),\(clip.sourceEnd)) にモザイクが効いていない")
        }
        _ = back
    }

    // MARK: - 5. 最初/最後/単独クリップの複製

    func test_duplicateOnlyClip() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        var state = TimelineState(clips: [clip])
        state.applyRanges = [MosaicApplyRange(clipID: clip.id, sourceID: sourceA, sourceStart: 0, sourceEnd: 5)]
        let duplicated = state.duplicating(clipID: clip.id)
        XCTAssertTrue(duplicated.validate())
        XCTAssertEqual(duplicated.clips.count, 2)
        XCTAssertEqual(duplicated.applyRanges.count, 2)
    }

    func test_duplicateFirstClip() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [a, b])
        state.applyRanges = [MosaicApplyRange(clipID: a.id, sourceID: sourceA, sourceStart: 0, sourceEnd: 4)]
        let duplicated = state.duplicating(clipID: a.id)
        XCTAssertTrue(duplicated.validate())
        XCTAssertEqual(duplicated.clips.map(\.sourceID), [sourceA, sourceA, sourceB])
    }

    func test_duplicateLastClip() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [a, b])
        state.applyRanges = [MosaicApplyRange(clipID: b.id, sourceID: sourceB, sourceStart: 0, sourceEnd: 4)]
        let duplicated = state.duplicating(clipID: b.id)
        XCTAssertTrue(duplicated.validate())
        XCTAssertEqual(duplicated.clips.map(\.sourceID), [sourceA, sourceB, sourceB])
    }

    // MARK: - 6. 複製→並べ替え→削除

    func test_duplicateReorderThenRemoveOriginal() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [a, b])
        state.applyRanges = [MosaicApplyRange(clipID: a.id, sourceID: sourceA, sourceStart: 0, sourceEnd: 4)]

        let afterDup = state.duplicating(clipID: a.id) // [A, A', B]
        let copy = afterDup.clips[1]
        XCTAssertTrue(afterDup.validate())

        // A' を末尾へ移動: [A, B, A']
        let afterMove = afterDup.moving(clipID: copy.id, toIndex: 2)
        XCTAssertTrue(afterMove.validate())

        // 元の A を削除: [B, A'] のはず。A' のモザイクは生き残るべき。
        let afterRemove = afterMove.removing(clipID: a.id)
        XCTAssertTrue(afterRemove.validate())
        XCTAssertEqual(afterRemove.clips.map(\.id), [b.id, copy.id])

        let effective = MosaicApplyGate.effectiveRanges(afterRemove.applyRanges, mapping: afterRemove.mapping)
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: copy.id,
                                                sourceID: sourceA, sourceTime: 2.0),
                      "元クリップを消したら複製先のモザイクまで消えた")
    }

    // MARK: - 7. トランジション付きクリップの複製（末尾複製→末尾に新境界）

    // MARK: - 8. 複製が ObjectMask を壊す件（**修正済み**。ここに再現テストは置かない）
    //
    // この観点で書いた `test_CRITICAL_duplicateCorruptsOriginalClipObjectMask` は、
    // 「`followClipEdit` が『同じ sourceID の新規クリップ』を見て分割と推測する」という
    // 当時の実装を前提にしていた。現在の `followClipEdit` は推測をやめ、編集操作の側から
    // `ClipLineage` を受け取って分割と複製を区別する（`MosaicEditorModel+ObjectMask`）。
    //
    // そのテストは分割用の純関数 `ObjectMaskEditOperations.masks(splittingClip:...)` を
    // 直接叩いて「分割のように振る舞うな」と主張する形になっていて、いまや
    // **分割の規則そのものを不合格にする**ので取り込まない。複製時にマスクが壊れないことは
    // 実経路（`duplicatingEdit` → `masks(following:)`）で
    // `ObjectMaskFollowClipEditTests.test_duplicate_keepsOriginalKeyframesAndCopiesThemToTheCopy`
    // が守っている。

    func test_duplicateLastClipWithIncomingTransition_untouched() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [a, b],
                                  transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 1.0)])
        let duplicated = state.duplicating(clipID: b.id)
        XCTAssertTrue(duplicated.validate())
        // A→B の transition は変わらないはず(Bは最後尾でoutgoingが無いので付け替え対象なし)。
        XCTAssertEqual(duplicated.transitions[a.id]?.kind, .crossfade)
        XCTAssertEqual(duplicated.transitions.count, 1)
    }
}
