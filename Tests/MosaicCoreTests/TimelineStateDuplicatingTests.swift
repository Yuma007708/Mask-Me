import XCTest
@testable import MosaicCore

/// `TimelineState.duplicating(clipID:)` の振る舞いを固定する。
///
/// **`TimelineStateTests` から分離してある**のは、あちらのクラス本体が
/// `type_body_length` の上限（300 行）に張り付いており、ここへ足すと超えるため
/// （`TimelineEditOperationsTests` 内の分割コメントと同じ理由）。
final class TimelineStateDuplicatingTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private let sourceC = UUID()

    /// A(0-4) → B(10-14) → C(20-24)、A→B と B→C にトランジション。
    /// `TimelineStateTests.makeState` と同じ構成（意図的に揃えてある）。
    private func makeState(durationAB: Double = 1.0, durationBC: Double = 1.0) -> TimelineState {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let c = TimelineClip(sourceID: sourceC, sourceStart: 20, sourceEnd: 24)
        return TimelineState(clips: [a, b, c],
                             transitions: [a.id: TransitionSpec(kind: .crossfade, duration: durationAB),
                                           b.id: TransitionSpec(kind: .wipeLeft, duration: durationBC)])
    }

    /// 複製先は元クリップの直後に挿入され、素材使用範囲・速度・音量を引き継ぐこと。
    func test_duplicatingInsertsCopyRightAfterOriginal() {
        let state = makeState()
        let clipA = state.clips[0]
        let duplicated = state.duplicating(clipID: clipA.id)

        XCTAssertEqual(duplicated.clips.count, 4)
        XCTAssertEqual(duplicated.clips[0], clipA, "元クリップは無変更")
        let copy = duplicated.clips[1]
        XCTAssertNotEqual(copy.id, clipA.id)
        XCTAssertEqual(copy.sourceID, clipA.sourceID)
        XCTAssertEqual(copy.sourceStart, clipA.sourceStart, accuracy: 1e-9)
        XCTAssertEqual(copy.sourceEnd, clipA.sourceEnd, accuracy: 1e-9)
        XCTAssertEqual(copy.rate, clipA.rate, accuracy: 1e-9)
        XCTAssertEqual(copy.originalAudioVolume, clipA.originalAudioVolume)
        // B・C はそのまま後続に残る。
        XCTAssertEqual(duplicated.clips[2].id, state.clips[1].id)
        XCTAssertEqual(duplicated.clips[3].id, state.clips[2].id)
        XCTAssertTrue(duplicated.validate())
    }

    /// 元クリップが後続との間に持っていた outgoing トランジションは複製先へ付け替えられ、
    /// 元クリップと複製先の新しい境界にはトランジションが追加されないこと。
    func test_duplicatingMovesOutgoingTransitionToCopyAndAddsNoneAtNewBoundary() {
        let state = makeState()  // A→B: crossfade 1.0, B→C: wipeLeft 1.0
        let clipA = state.clips[0]
        let duplicated = state.duplicating(clipID: clipA.id)
        let copy = duplicated.clips[1]

        XCTAssertNil(duplicated.transitions[clipA.id], "元クリップ→複製先の新しい境界にはトランジションを追加しない")
        XCTAssertEqual(duplicated.transitions[copy.id]?.kind, .crossfade, "A→B にあった設定が複製先→B へ移る")
        XCTAssertEqual(duplicated.transitions[copy.id]?.duration ?? -1, 1.0, accuracy: 1e-9)
        // B→C のトランジションは影響を受けない。
        XCTAssertEqual(duplicated.transitions[duplicated.clips[2].id]?.kind, .wipeLeft)
        XCTAssertEqual(duplicated.transitions.count, 2)
        XCTAssertTrue(duplicated.validate())
    }

    /// 元クリップに紐づくモザイク適用区間は、複製先の clipID で複製され、
    /// 元クリップの区間はそのまま残ること（適用区間は clipID スコープなので
    /// 複製しないと複製先にモザイクが一切効かない）。
    func test_duplicatingCopiesApplyRangesToNewClipID() {
        var state = makeState()
        let clipA = state.clips[0]
        state.applyRanges = [MosaicApplyRange(clipID: clipA.id, sourceID: sourceA,
                                             sourceStart: 0.5, sourceEnd: 2.0)]
        let duplicated = state.duplicating(clipID: clipA.id)
        let copy = duplicated.clips[1]

        XCTAssertEqual(duplicated.applyRanges.count, 2)
        XCTAssertTrue(duplicated.applyRanges.contains {
            $0.clipID == clipA.id && $0.sourceStart == 0.5 && $0.sourceEnd == 2.0
        }, "元クリップの区間は残る")
        XCTAssertTrue(duplicated.applyRanges.contains {
            $0.clipID == copy.id && $0.sourceID == sourceA && $0.sourceStart == 0.5 && $0.sourceEnd == 2.0
        }, "複製先にも同じ素材時刻の区間が複製される")
        XCTAssertTrue(duplicated.validate())
    }

    /// 適用区間が無いクリップを複製しても区間は増えないこと。
    func test_duplicatingWithoutApplyRangesAddsNone() {
        let state = makeState()
        let duplicated = state.duplicating(clipID: state.clips[0].id)
        XCTAssertTrue(duplicated.applyRanges.isEmpty)
    }

    /// 複製は BGM・テキスト（合成時刻アンカー）に触れないこと
    /// （`trimming` が尺を伸縮させても追従させていないのと同じ規則）。
    func test_duplicatingDoesNotShiftAudioOrTextItems() {
        var state = makeState()
        let audio = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2, compositionStart: 5.0)
        let text = TextItem(text: "hello", compositionStart: 6.0, duration: 1.0)
        state.audioItems = [audio]
        state.textItems = [text]

        let duplicated = state.duplicating(clipID: state.clips[0].id)
        XCTAssertEqual(duplicated.audioItems, state.audioItems)
        XCTAssertEqual(duplicated.textItems, state.textItems)
    }

    /// 未知の id では変更なし（他の編集操作と同じ「失敗時は self」契約）。
    func test_duplicatingFailureReturnsSelf() {
        let state = makeState()
        XCTAssertEqual(state.duplicating(clipID: UUID()), state)
    }
}
