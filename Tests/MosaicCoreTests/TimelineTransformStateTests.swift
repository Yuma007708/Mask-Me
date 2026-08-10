import CoreGraphics
import XCTest
@testable import MosaicCore

/// `TimelineState.settingClipTransform`（クリップ単位の拡大縮小・位置）。
///
/// クランプは `ClipTransform` 自身が担うので、ここは「状態ラッパとしての契約」だけを
/// 固定する（`TimelineColorGradeStateTests` と同じ立て付け）。
final class TimelineTransformStateTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private func makeState() -> TimelineState {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        return TimelineState(
            clips: [clipA, clipB],
            transitions: [clipA.id: TransitionSpec(kind: .crossfade, duration: 1.0)],
            applyRanges: [MosaicApplyRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 3)],
            sources: [sourceA: TimelineSource(id: sourceA, kind: .video),
                      sourceB: TimelineSource(id: sourceB, kind: .video)])
    }

    /// 変形だけが変わり、他のクリップ・トランジション・適用区間・素材メタは変わらないこと。
    func test_settingClipTransform_preservesEverythingElse() {
        let state = makeState()
        let target = state.clips[0].id
        let transform = ClipTransform(scale: 1.5, offset: CGPoint(x: 0.2, y: -0.1))
        let updated = state.settingClipTransform(clipID: target, transform: transform)

        XCTAssertEqual(updated.clips[0].transform, transform)
        XCTAssertEqual(updated.clips[1].transform, .identity, "他クリップの変形まで書き換わっている")
        XCTAssertEqual(updated.transitions, state.transitions, "トランジションが壊れた")
        XCTAssertEqual(updated.applyRanges, state.applyRanges, "モザイク適用区間が壊れた")
        XCTAssertEqual(updated.sources, state.sources, "素材メタが落ちた")
        XCTAssertEqual(updated.clips.map(\.id), state.clips.map(\.id), "クリップの順序・同一性が変わった")
        XCTAssertTrue(updated.validate())
    }

    /// 変形は合成尺を変えないこと（配置矩形の見た目だけが変わる）。
    func test_settingClipTransform_doesNotChangeDurations() {
        let state = makeState()
        let updated = state.settingClipTransform(clipID: state.clips[0].id,
                                                  transform: ClipTransform(scale: 3.0))
        XCTAssertEqual(updated.mapping.totalDuration, state.mapping.totalDuration, accuracy: 1e-9)
    }

    /// 同値・不在 clipID では self をそのまま返すこと。
    func test_settingClipTransform_noOpCases_returnSelf() {
        let state = makeState()
        XCTAssertEqual(state.settingClipTransform(clipID: state.clips[0].id, transform: .identity), state,
                       "同値なのに新しい状態を返している")
        XCTAssertEqual(state.settingClipTransform(clipID: UUID(),
                                                  transform: ClipTransform(scale: 2.0)),
                       state, "存在しない clipID で状態が変化した")
    }

    /// 短いトランジションが変形の編集で消えたりクランプされたりしないこと
    /// （`normalizingTransitions()` を通していれば副作用が出る組み合わせ。`settingColorGrade` と同じ趣旨）。
    func test_settingClipTransform_keepsTransitionUntouched() {
        var state = makeState()
        state.transitions[state.clips[0].id] = TransitionSpec(kind: .wipeLeft, duration: 3.0)
        let updated = state.settingClipTransform(clipID: state.clips[1].id,
                                                  transform: ClipTransform(scale: 0.5))
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.duration, 3.0,
                       "変形の編集でトランジションが作り直された")
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.kind, .wipeLeft)
    }

    /// 変形が Codable 往復で保存されること（`TimelineState` 経由）。
    func test_transformSurvivesCodableRoundTrip() throws {
        let base = makeState()
        let state = base.settingClipTransform(clipID: base.clips[0].id,
                                              transform: ClipTransform(scale: 2.2,
                                                                       offset: CGPoint(x: -0.4, y: 0.4)))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state, "Codable 往復で状態が一致しない")
        XCTAssertEqual(decoded.clips[0].transform, state.clips[0].transform)
    }
}
