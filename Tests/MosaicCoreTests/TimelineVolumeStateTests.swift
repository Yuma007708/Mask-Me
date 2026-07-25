import XCTest
@testable import MosaicCore

/// S12: `TimelineState.settingVolume`（クリップ音量のコア API）。
///
/// `TimelineEditOperations.setVolume` 側の値の扱い（クランプ・NaN）は
/// `TimelineEditOperationsTests` が見ているので、ここは**状態ラッパとしての契約**
/// （他の状態を壊さない・同値なら self・トランジションを作り直さない・永続化）だけを固定する。
final class TimelineVolumeStateTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// クリップ 2 本 + トランジション + 適用区間 + 素材メタを持つ状態。
    private func makeState() -> TimelineState {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        var state = TimelineState(
            clips: [clipA, clipB],
            // duration は clipB の合成尺（rate 2.0 で 3s）の半分以内にしておく（validate 通過条件）。
            transitions: [clipA.id: TransitionSpec(kind: .crossfade, duration: 1.0)],
            applyRanges: [
                MosaicApplyRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 3)
            ],
            sources: [sourceA: TimelineSource(id: sourceA, kind: .video),
                      sourceB: TimelineSource(id: sourceB, kind: .photo)])
        state.clips[1].rate = 2.0
        return state
    }

    /// 音量だけが変わり、`transitions` / `applyRanges` / `sources` と
    /// 他クリップ（使用範囲・rate）は一切変わらないこと。
    func test_settingVolume_preservesEverythingElse() {
        let state = makeState()
        let target = state.clips[0].id
        let updated = state.settingVolume(clipID: target, volume: 0.25)

        XCTAssertEqual(updated.clips[0].originalAudioVolume, 0.25, accuracy: 1e-6)
        XCTAssertEqual(updated.clips[1].originalAudioVolume, 1.0, accuracy: 1e-6,
                       "他クリップの音量まで書き換わっている")
        XCTAssertEqual(updated.transitions, state.transitions, "トランジションが壊れた")
        XCTAssertEqual(updated.applyRanges, state.applyRanges, "モザイク適用区間が壊れた")
        XCTAssertEqual(updated.sources, state.sources, "素材メタ（写真/動画の別）が落ちた")
        XCTAssertEqual(updated.clips.map(\.id), state.clips.map(\.id), "クリップの順序・同一性が変わった")
        XCTAssertEqual(updated.clips[0].sourceEnd, state.clips[0].sourceEnd, accuracy: 1e-9)
        XCTAssertEqual(updated.clips[1].rate, 2.0, accuracy: 1e-9, "rate が巻き添えで戻った")
        XCTAssertTrue(updated.validate())
    }

    /// 合成尺は音量で変わらないこと（`normalizingTransitions` を通さない前提の根拠）。
    func test_settingVolume_doesNotChangeDurations() {
        let state = makeState()
        let updated = state.settingVolume(clipID: state.clips[0].id, volume: 0)
        XCTAssertEqual(updated.mapping.totalDuration, state.mapping.totalDuration, accuracy: 1e-9)
    }

    /// 同値・不在 clipID では self をそのまま返す（他の編集操作と同じ契約）。
    func test_settingVolume_noOpCases_returnSelf() {
        let state = makeState()
        XCTAssertEqual(state.settingVolume(clipID: state.clips[0].id, volume: 1.0), state,
                       "同値なのに新しい状態を返している（世代・履歴が無駄に進む）")
        XCTAssertEqual(state.settingVolume(clipID: UUID(), volume: 0.5), state,
                       "存在しない clipID で状態が変化した")
        // クランプ後に同値になる指定も no-op（1.5 → 1.0、NaN → 1.0）。
        XCTAssertEqual(state.settingVolume(clipID: state.clips[0].id, volume: 1.5), state)
        XCTAssertEqual(state.settingVolume(clipID: state.clips[0].id, volume: .nan), state)
    }

    /// 許容範囲外はクランプされること（状態経由でも `clampedVolume` が効く）。
    func test_settingVolume_clampsToRange() {
        let state = makeState()
        let target = state.clips[0].id
        XCTAssertEqual(state.settingVolume(clipID: target, volume: -3).clips[0].originalAudioVolume,
                       0, accuracy: 1e-6)
        XCTAssertEqual(state.settingVolume(clipID: target, volume: 9).clips[0].originalAudioVolume,
                       1, accuracy: 1e-6)
    }

    /// 短いトランジションが音量編集で消えたりクランプされたりしないこと
    /// （`normalizingTransitions()` を通していれば副作用が出る組み合わせ）。
    func test_settingVolume_keepsTransitionUntouched() {
        var state = makeState()
        state.transitions[state.clips[0].id] = TransitionSpec(kind: .wipeLeft, duration: 3.0)
        let updated = state.settingVolume(clipID: state.clips[1].id, volume: 0.5)
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.duration, 3.0,
                       "音量編集でトランジションが作り直された")
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.kind, .wipeLeft)
    }

    /// 下書き（`TimelineState` の Codable）に音量が載って往復すること。
    func test_volumeSurvivesCodableRoundTrip() throws {
        let base = makeState()
        let state = base.settingVolume(clipID: base.clips[0].id, volume: 0.4)
        let edited = state.settingVolume(clipID: state.clips[1].id, volume: 0)
        let data = try JSONEncoder().encode(edited)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, edited, "Codable 往復で状態が一致しない")
        XCTAssertEqual(decoded.clips[1].originalAudioVolume, 0, accuracy: 1e-6,
                       "無音設定が下書きから復元されない")
    }
}
