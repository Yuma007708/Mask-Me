import CoreGraphics
import XCTest
@testable import MosaicCore

/// `TimelineState.freezing` / `canFreeze`（フリーズフレーム挿入）の振る舞いを固定する。
///
/// **`TimelineStateTests` から分離してある**のは、あちらのクラス本体が `type_body_length`
/// の上限（300 行）に張り付いているため（`TimelineStateDuplicatingTests` と同じ理由）。
final class TimelineStateFreezeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private let freezeSource = UUID()

    /// A(0-4) → B(10-16)。1 本構成のテストは `makeState(clipCount: 1)` を使う。
    private func makeState(clipCount: Int = 2, transitionDuration: Double? = nil) -> TimelineState {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        guard clipCount >= 2 else {
            return TimelineState(clips: [a], sources: [sourceA: TimelineSource(id: sourceA, kind: .video)])
        }
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 16)
        var transitions: [UUID: TransitionSpec] = [:]
        if let transitionDuration {
            transitions[a.id] = TransitionSpec(kind: .crossfade, duration: transitionDuration)
        }
        return TimelineState(clips: [a, b], transitions: transitions,
                             sources: [sourceA: TimelineSource(id: sourceA, kind: .video),
                                       sourceB: TimelineSource(id: sourceB, kind: .video)])
    }

    private func freezeClip(duration: Double = 1.0) -> TimelineClip {
        TimelineClip(sourceID: freezeSource, sourceStart: 0, sourceEnd: duration)
    }

    // MARK: - 分割が要る位置

    /// クリップの途中でフリーズすると、挿入位置は分割された前半と後半の**間**になる。
    func test_挿入位置が前半と後半の間になる() {
        let state = makeState()
        let clipA = state.clips[0]
        let clipB = state.clips[1]
        let frozen = state.freezing(clipID: clipA.id, atDisplayTime: 2.0, freezeClip: freezeClip())

        XCTAssertEqual(frozen.clips.count, 4, "A が前半・後半に割れ、間にフリーズクリップが挟まる")
        XCTAssertEqual(frozen.clips[0].id, clipA.id, "前半は元クリップの id を継承")
        XCTAssertEqual(frozen.clips[0].sourceEnd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(frozen.clips[1].sourceID, freezeSource, "前半の直後がフリーズクリップ")
        XCTAssertEqual(frozen.clips[2].sourceStart, 2.0, accuracy: 1e-9, "後半は分割点から始まる")
        XCTAssertEqual(frozen.clips[3].id, clipB.id, "B はそのまま後続に残る")
        XCTAssertTrue(frozen.validate())
    }

    /// 合計尺はフリーズクリップの尺だけ増える。
    func test_合計尺がフリーズの尺だけ増える() {
        let state = makeState()
        let before = state.mapping.totalDuration
        let clipA = state.clips[0]
        let clip = freezeClip(duration: 1.5)
        let frozen = state.freezing(clipID: clipA.id, atDisplayTime: 2.0, freezeClip: clip)

        XCTAssertEqual(frozen.mapping.totalDuration, before + clip.duration, accuracy: 1e-9)
    }

    /// フリーズ区間（写真クリップの適用区間）は `sourceStart == 0` の全域区間になり、
    /// `validate()` が通ること。
    func test_フリーズ区間はsourceStart0の全域区間でvalidateが通る() {
        let state = makeState()
        let clipA = state.clips[0]
        let clip = freezeClip(duration: 2.0)
        let frozen = state.freezing(clipID: clipA.id, atDisplayTime: 2.0, freezeClip: clip,
                                    source: TimelineSource(id: freezeSource, kind: .photo))

        guard let range = frozen.applyRanges.first(where: { $0.clipID == clip.id }) else {
            return XCTFail("フリーズクリップの適用区間が生成されていない")
        }
        XCTAssertEqual(range.sourceStart, 0, "写真クリップの区間は sourceStart == 0")
        XCTAssertEqual(range.sourceEnd, clip.sourceEnd, accuracy: 1e-9)
        XCTAssertTrue(frozen.validate())
    }

    /// 元クリップの `applyRanges` / `orientation` / `rate` は変わらない。
    func test_元クリップのapplyRangesとorientationとrateが不変() {
        var state = makeState()
        let clipA = state.clips[0]
        state.clips[0].orientation = ClipOrientation(rotation: .right90)
        state.clips[0].rate = 2.0
        state.applyRanges = [MosaicApplyRange(clipID: clipA.id, sourceID: sourceA,
                                             sourceStart: 0.5, sourceEnd: 3.0)]
        let originalOrientation = state.clips[0].orientation
        let originalRate = state.clips[0].rate

        // rate=2.0 で A の合成尺は 2.0 秒（= (4-0)/2）に縮む。表示時刻 1.0 秒は
        // 素材時刻換算で m=2.0（= 1.0 * rate）となり、分割点は変えずに済む。
        let frozen = state.freezing(clipID: clipA.id, atDisplayTime: 1.0, freezeClip: freezeClip())
        let front = frozen.clips[0]
        let back = frozen.clips[2]

        XCTAssertEqual(front.orientation, originalOrientation)
        XCTAssertEqual(back.orientation, originalOrientation)
        XCTAssertEqual(front.rate, originalRate, accuracy: 1e-9)
        XCTAssertEqual(back.rate, originalRate, accuracy: 1e-9)
        // 元の適用区間 [0.5, 3.0) は分割点 2.0 をまたぐので front/back へ振り分けられるが、
        // 消えたり値が変わったりはしない（既存の分割経路の契約）。
        XCTAssertTrue(frozen.applyRanges.contains {
            $0.clipID == front.id && $0.sourceStart == 0.5 && $0.sourceEnd == 2.0
        })
        XCTAssertTrue(frozen.applyRanges.contains {
            $0.clipID == back.id && $0.sourceStart == 2.0 && $0.sourceEnd == 3.0
        })
    }

    // MARK: - トランジションの重なり

    /// トランジションの重なりの中では `canFreeze == false` かつ状態が変わらない。
    func test_トランジションの重なりの中ではフリーズできない() {
        // A(0-4) → crossfade 2.0 → B(10-16)。表示タイムラインの重なりは [2, 4)。
        let state = makeState(transitionDuration: 2.0)
        let clipA = state.clips[0]

        XCTAssertFalse(state.canFreeze(clipID: clipA.id, atDisplayTime: 3.0))
        let frozen = state.freezing(clipID: clipA.id, atDisplayTime: 3.0, freezeClip: freezeClip())
        XCTAssertEqual(frozen, state, "重なりの中では状態が変わらない")
    }

    // MARK: - クリップ先頭ちょうど

    /// クリップ先頭ちょうどでは分割が起きない（クリップ本数は +1 で済む）。
    func test_クリップ先頭ちょうどでは分割が起きない() {
        let state = makeState()
        let clipB = state.clips[1]
        let displayStart = state.mapping.clipSpans[1].start

        XCTAssertTrue(state.canFreeze(clipID: clipB.id, atDisplayTime: displayStart))
        let frozen = state.freezing(clipID: clipB.id, atDisplayTime: displayStart,
                                    freezeClip: freezeClip())

        XCTAssertEqual(frozen.clips.count, 3, "分割は起きず、フリーズクリップが 1 本増えるだけ")
        XCTAssertEqual(frozen.clips[0].id, state.clips[0].id)
        XCTAssertEqual(frozen.clips[1].sourceID, freezeSource, "B の直前に挿入される")
        XCTAssertEqual(frozen.clips[2].id, clipB.id, "B 自体は無変更（id も sourceStart/sourceEnd も同じ）")
        XCTAssertEqual(frozen.clips[2].sourceStart, clipB.sourceStart, accuracy: 1e-9)
        XCTAssertEqual(frozen.clips[2].sourceEnd, clipB.sourceEnd, accuracy: 1e-9)
        XCTAssertTrue(frozen.validate())
    }

    // MARK: - 失敗系

    /// 存在しない clipID では `canFreeze` が false・状態も変わらない。
    func test_存在しないclipIDではフリーズできない() {
        let state = makeState()
        let unknown = UUID()
        XCTAssertFalse(state.canFreeze(clipID: unknown, atDisplayTime: 1.0))
        XCTAssertEqual(state.freezing(clipID: unknown, atDisplayTime: 1.0, freezeClip: freezeClip()),
                      state)
    }

    /// 分割後の最小尺を割る位置（クリップ末尾近く）ではフリーズできない。
    func test_最小尺を割る位置ではフリーズできない() {
        let state = makeState()
        let clipA = state.clips[0]
        // A は [0,4)。末尾 0.05 秒手前は分割後の後半が最小尺 0.1 を割る。
        let nearEnd = state.mapping.clipSpans[0].end - 0.05
        XCTAssertFalse(state.canFreeze(clipID: clipA.id, atDisplayTime: nearEnd))
        XCTAssertEqual(state.freezing(clipID: clipA.id, atDisplayTime: nearEnd, freezeClip: freezeClip()),
                      state)
    }
}
