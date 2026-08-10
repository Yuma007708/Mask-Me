import XCTest
@testable import MosaicCore

/// `TimelineState.settingColorGrade` と `TimelineState.colorGrade(atComposition:)`（E4）。
///
/// `TimelineEditOperations.setColorGrade` 側の値の扱い（クランプ）は `ColorGrade` 自身が
/// 担うので、ここは「状態ラッパとしての契約」と「合成時刻からの純粋な参照」だけを固定する
/// （`TimelineVolumeStateTests` と同じ立て付け）。
final class TimelineColorGradeStateTests: XCTestCase {
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

    // MARK: - settingColorGrade（状態ラッパとしての契約）

    /// 色調補正だけが変わり、他のクリップ・トランジション・適用区間・素材メタは変わらないこと。
    func test_settingColorGrade_preservesEverythingElse() {
        let state = makeState()
        let target = state.clips[0].id
        let grade = ColorGrade(brightness: 0.3, contrast: 1.4, saturation: 0.6, warmth: -0.2)
        let updated = state.settingColorGrade(clipID: target, colorGrade: grade)

        XCTAssertEqual(updated.clips[0].colorGrade, grade)
        XCTAssertEqual(updated.clips[1].colorGrade, .identity, "他クリップの色調補正まで書き換わっている")
        XCTAssertEqual(updated.transitions, state.transitions, "トランジションが壊れた")
        XCTAssertEqual(updated.applyRanges, state.applyRanges, "モザイク適用区間が壊れた")
        XCTAssertEqual(updated.sources, state.sources, "素材メタが落ちた")
        XCTAssertEqual(updated.clips.map(\.id), state.clips.map(\.id), "クリップの順序・同一性が変わった")
        XCTAssertTrue(updated.validate())
    }

    /// 色調補正は合成尺を変えないこと。
    func test_settingColorGrade_doesNotChangeDurations() {
        let state = makeState()
        let updated = state.settingColorGrade(clipID: state.clips[0].id,
                                              colorGrade: ColorGrade(brightness: -1))
        XCTAssertEqual(updated.mapping.totalDuration, state.mapping.totalDuration, accuracy: 1e-9)
    }

    /// 同値・不在 clipID では self をそのまま返すこと。
    func test_settingColorGrade_noOpCases_returnSelf() {
        let state = makeState()
        XCTAssertEqual(state.settingColorGrade(clipID: state.clips[0].id, colorGrade: .identity), state,
                       "同値なのに新しい状態を返している")
        XCTAssertEqual(state.settingColorGrade(clipID: UUID(), colorGrade: ColorGrade(brightness: 0.5)),
                       state, "存在しない clipID で状態が変化した")
    }

    /// 短いトランジションが色調補正の編集で消えたりクランプされたりしないこと
    /// （`normalizingTransitions()` を通していれば副作用が出る組み合わせ。`settingVolume` と同じ趣旨）。
    func test_settingColorGrade_keepsTransitionUntouched() {
        var state = makeState()
        state.transitions[state.clips[0].id] = TransitionSpec(kind: .wipeLeft, duration: 3.0)
        let updated = state.settingColorGrade(clipID: state.clips[1].id,
                                              colorGrade: ColorGrade(saturation: 0))
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.duration, 3.0,
                       "色調補正の編集でトランジションが作り直された")
        XCTAssertEqual(updated.transitions[state.clips[0].id]?.kind, .wipeLeft)
    }

    /// 色調補正が Codable 往復で保存されること（`TimelineState` 経由）。
    func test_colorGradeSurvivesCodableRoundTrip() throws {
        let base = makeState()
        let state = base.settingColorGrade(clipID: base.clips[0].id,
                                           colorGrade: ColorGrade(brightness: 0.4, contrast: 1.3,
                                                                  saturation: 0.7, warmth: -0.5))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state, "Codable 往復で状態が一致しない")
        XCTAssertEqual(decoded.clips[0].colorGrade, state.clips[0].colorGrade)
    }

    // MARK: - スキーマ版

    /// 現在のスキーマ版が 7 であること（v7 = `TimelineClip.colorGrade` 追加）。
    func test_currentSchemaVersionIs7() {
        XCTAssertEqual(TimelineState.currentSchemaVersion, 7)
    }

    /// 保存した JSON に `schemaVersion: 7` が書かれること。
    func test_encodedJSON_containsSchemaVersion7() throws {
        let data = try JSONEncoder().encode(makeState())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 7)
    }

    // MARK: - colorGrade(atComposition:)（純関数）

    /// クリップが 0 本の状態では `.identity` を返すこと。
    func test_colorGradeAtComposition_emptyTimeline_returnsIdentity() {
        let state = TimelineState()
        XCTAssertEqual(state.colorGrade(atComposition: 0), .identity)
    }

    /// 範囲外の合成時刻（負・末尾以降）では `.identity` を返すこと。
    func test_colorGradeAtComposition_outOfRange_returnsIdentity() {
        var state = makeState()
        state.clips[0].colorGrade = ColorGrade(brightness: 0.9)
        XCTAssertEqual(state.colorGrade(atComposition: -1), .identity)
        XCTAssertEqual(state.colorGrade(atComposition: state.mapping.totalDuration + 10), .identity)
    }

    /// 重なり外（単独クリップ）では、そのクリップの色調補正をそのまま返すこと。
    func test_colorGradeAtComposition_singleClip_returnsOwnGrade() {
        var state = makeState()
        let gradeA = ColorGrade(brightness: 0.4, contrast: 1.2, saturation: 0.5, warmth: -0.3)
        state.clips[0].colorGrade = gradeA
        // クリップ A の重なり外（先頭付近）。
        XCTAssertEqual(state.colorGrade(atComposition: 0.1), gradeA)
    }

    /// トランジションの重なりの両端で、各クリップ自身の色調補正に一致すること
    /// （`progress` は `mapping.sourceLocations(at:)` が返す値をそのまま使う契約）。
    func test_colorGradeAtComposition_atOverlapBoundaries_matchesEachClipGrade() {
        var state = makeState()
        let gradeA = ColorGrade(brightness: 0.4, contrast: 1.2, saturation: 0.5, warmth: -0.3)
        let gradeB = ColorGrade(brightness: -0.2, contrast: 0.8, saturation: 1.5, warmth: 0.6)
        state.clips[0].colorGrade = gradeA
        state.clips[1].colorGrade = gradeB

        guard let overlap = state.mapping.overlaps.first else {
            XCTFail("テストの前提（重なりが作られること）が崩れている")
            return
        }

        let atStart = state.colorGrade(atComposition: overlap.start)
        XCTAssertEqual(atStart, gradeA, "重なり開始（progress=0）で先行クリップの色調補正に一致しない")

        let nearEnd = state.colorGrade(atComposition: overlap.end.nextDown)
        XCTAssertEqual(nearEnd.brightness, gradeB.brightness, accuracy: 1e-6)
        XCTAssertEqual(nearEnd.contrast, gradeB.contrast, accuracy: 1e-6)
        XCTAssertEqual(nearEnd.saturation, gradeB.saturation, accuracy: 1e-6)
        XCTAssertEqual(nearEnd.warmth, gradeB.warmth, accuracy: 1e-6)
    }

    /// 重なりの中点では、`ColorGrade.blend` の中点と一致すること（近似であることの直接固定）。
    func test_colorGradeAtComposition_atOverlapMidpoint_matchesBlend() {
        var state = makeState()
        let gradeA = ColorGrade(brightness: -1, contrast: 0, saturation: 0, warmth: -1)
        let gradeB = ColorGrade(brightness: 1, contrast: 2, saturation: 2, warmth: 1)
        state.clips[0].colorGrade = gradeA
        state.clips[1].colorGrade = gradeB

        guard let overlap = state.mapping.overlaps.first else {
            XCTFail("テストの前提（重なりが作られること）が崩れている")
            return
        }
        let midTime = (overlap.start + overlap.end) / 2
        let mid = state.colorGrade(atComposition: midTime)
        let expected = ColorGrade.blend(gradeA, gradeB, t: 0.5)
        XCTAssertEqual(mid.brightness, expected.brightness, accuracy: 1e-6)
        XCTAssertEqual(mid.contrast, expected.contrast, accuracy: 1e-6)
        XCTAssertEqual(mid.saturation, expected.saturation, accuracy: 1e-6)
        XCTAssertEqual(mid.warmth, expected.warmth, accuracy: 1e-6)
    }
}
