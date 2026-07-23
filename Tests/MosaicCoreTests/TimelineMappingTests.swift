import XCTest
@testable import MosaicCore

final class TimelineMappingTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private struct MappingTestData {
        let mapping: TimelineMapping
        let clipA: TimelineClip
        let clipB: TimelineClip
    }

    /// クリップA(素材Aの0-3秒) + クリップB(素材Bの10-14秒) の並び。
    private func makeMapping() -> MappingTestData {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        return MappingTestData(mapping: TimelineMapping(clips: [a, b]), clipA: a, clipB: b)
    }

    func test_totalDurationIsSumOfClips() {
        let data = makeMapping()
        XCTAssertEqual(data.mapping.totalDuration, 7, accuracy: 1e-9)
    }

    /// 先頭クリップ内の時刻は、そのまま素材時刻になる。
    func test_firstClipMapsDirectly() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 1.5)
        XCTAssertEqual(loc?.clipID, data.clipA.id)
        XCTAssertEqual(loc?.sourceID, sourceA)
        XCTAssertEqual(loc?.time ?? 0, 1.5, accuracy: 1e-9)
    }

    /// 2つ目のクリップでは、素材内のオフセット(10秒)が加算される。
    /// ここがずれると、後続クリップの検出結果が全て別時刻を引く。
    func test_secondClipAppliesSourceOffset() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 4.0)  // クリップBの先頭から1秒
        XCTAssertEqual(loc?.clipID, data.clipB.id)
        XCTAssertEqual(loc?.sourceID, sourceB)
        XCTAssertEqual(loc?.time ?? 0, 11.0, accuracy: 1e-9)
    }

    /// クリップ境界は次のクリップの先頭に属する（半開区間 [start, end)）。
    /// 境界の扱いが曖昧だと、1フレームだけ前のクリップの顔が出る不具合になる。
    func test_boundaryBelongsToNextClip() {
        let data = makeMapping()
        let loc = data.mapping.sourceLocation(at: 3.0)
        XCTAssertEqual(loc?.clipID, data.clipB.id)
        XCTAssertEqual(loc?.time ?? 0, 10.0, accuracy: 1e-9)
    }

    /// 範囲外は nil。末尾ちょうども範囲外とする。
    func test_outOfRangeReturnsNil() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.sourceLocation(at: -0.1))
        XCTAssertNil(data.mapping.sourceLocation(at: 7.0))
        XCTAssertNil(data.mapping.sourceLocation(at: 99))
    }

    /// 素材時刻から合成時刻への逆変換。
    func test_reverseMapping() {
        let data = makeMapping()
        let t = data.mapping.compositionTime(clipID: data.clipB.id, sourceTime: 11.0)
        XCTAssertEqual(t ?? 0, 4.0, accuracy: 1e-9)
    }

    /// クリップの使用範囲外の素材時刻は逆変換できない。
    func test_reverseMappingRejectsTimeOutsideClip() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.compositionTime(clipID: data.clipB.id, sourceTime: 20.0))
    }

    /// 空のタイムラインで破綻しないこと。
    func test_emptyTimeline() {
        let mapping = TimelineMapping(clips: [])
        XCTAssertEqual(mapping.totalDuration, 0, accuracy: 1e-9)
        XCTAssertNil(mapping.sourceLocation(at: 0))
    }

    /// 同じ素材を分割した2クリップは、同じ sourceID を返す。
    /// これが成立しないと分割時に検出キャッシュを共有できない。
    func test_splitClipsShareSourceID() {
        let first = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [first, second])

        XCTAssertEqual(mapping.sourceLocation(at: 1.0)?.sourceID, sourceA)
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.sourceID, sourceA)
        // 合成時刻3.0 はクリップ2の先頭から1秒 = 素材時刻3.0
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.time ?? 0, 3.0, accuracy: 1e-9)
    }

    /// `sourceLocation(at:)` は境界(end)を次のクリップに属させる半開区間だが、
    /// `compositionTime` がその境界(sourceEnd ちょうど)を受け入れてしまうと、
    /// 素材時刻→合成時刻→素材時刻の往復が境界で非対称になる。
    /// クリップAの sourceEnd(=3.0)は「クリップAの範囲外」として nil を返すべき。
    func test_compositionTimeRejectsExactSourceEnd() {
        let data = makeMapping()
        XCTAssertNil(data.mapping.compositionTime(clipID: data.clipA.id, sourceTime: 3.0))
    }

    /// sourceLocation(at:) が返す複数の合成時刻について、
    /// compositionTime(clipID:sourceTime:) に通すと元の合成時刻に戻ることを検証する。
    /// 境界(3.0)を含めても対称性が崩れないことがポイント。
    func test_roundTripIsSymmetric() {
        let data = makeMapping()
        let compositionTimes: [Double] = [0.0, 1.5, 2.999, 3.0, 4.0, 6.999]
        for compositionTime in compositionTimes {
            guard let loc = data.mapping.sourceLocation(at: compositionTime) else {
                XCTFail("expected a location for \(compositionTime)")
                continue
            }
            let roundTripped = data.mapping.compositionTime(clipID: loc.clipID, sourceTime: loc.time)
            XCTAssertEqual(roundTripped ?? -1, compositionTime, accuracy: 1e-9,
                           "round trip failed for compositionTime \(compositionTime)")
        }
    }

    // MARK: - rate（再生倍率）付き写像

    /// 2x のクリップでは合成 1 秒が素材 2 秒に対応する（順写像のスケール）。
    func test_rateScalesForwardMapping() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 10, sourceEnd: 14, rate: 2.0)
        let mapping = TimelineMapping(clips: [clip])
        // 合成尺は (14-10)/2 = 2 秒。
        XCTAssertEqual(mapping.totalDuration, 2.0, accuracy: 1e-9)
        // 合成 0.5 秒 → 素材 10 + 0.5*2 = 11 秒。
        XCTAssertEqual(mapping.sourceLocation(at: 0.5)?.time ?? 0, 11.0, accuracy: 1e-9)
    }

    /// 0.5x / 2x のクリップでも順写像→逆写像の往復が対称であること。
    func test_roundTripIsSymmetricWithRates() {
        let slow = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2, rate: 0.5)   // 合成 4 秒
        let fast = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14, rate: 2.0) // 合成 2 秒
        let mapping = TimelineMapping(clips: [slow, fast])
        XCTAssertEqual(mapping.totalDuration, 6.0, accuracy: 1e-9)

        let compositionTimes: [Double] = [0.0, 1.5, 3.999, 4.0, 5.0, 5.999]
        for compositionTime in compositionTimes {
            guard let loc = mapping.sourceLocation(at: compositionTime) else {
                XCTFail("expected a location for \(compositionTime)")
                continue
            }
            let roundTripped = mapping.compositionTime(clipID: loc.clipID, sourceTime: loc.time)
            XCTAssertEqual(roundTripped ?? -1, compositionTime, accuracy: 1e-9,
                           "round trip failed for compositionTime \(compositionTime)")
        }
    }

    /// 極端な倍率（0.1x / 10x）でも順逆写像の精度が保たれること。
    /// 乗除の往復による浮動小数点誤差は 1e-9 秒以内に収まる。
    func test_extremeRatesKeepPrecision() {
        let verySlow = TimelineClip(sourceID: sourceA, sourceStart: 5, sourceEnd: 6, rate: 0.1)   // 合成 10 秒
        let veryFast = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 30, rate: 10.0) // 合成 3 秒
        let mapping = TimelineMapping(clips: [verySlow, veryFast])
        XCTAssertEqual(mapping.totalDuration, 13.0, accuracy: 1e-9)

        // 0.1x: 合成 7 秒 → 素材 5 + 7*0.1 = 5.7 秒。
        XCTAssertEqual(mapping.sourceLocation(at: 7.0)?.time ?? 0, 5.7, accuracy: 1e-9)
        // 10x: 合成 11.5 秒（クリップ先頭から 1.5 秒）→ 素材 15 秒。
        XCTAssertEqual(mapping.sourceLocation(at: 11.5)?.time ?? 0, 15.0, accuracy: 1e-9)

        // 逆写像の精度も確認する。
        XCTAssertEqual(mapping.compositionTime(clipID: verySlow.id, sourceTime: 5.7) ?? -1, 7.0, accuracy: 1e-9)
        XCTAssertEqual(mapping.compositionTime(clipID: veryFast.id, sourceTime: 15.0) ?? -1, 11.5, accuracy: 1e-9)
    }

    /// rate ≠ 1 のクリップでも半開区間契約が維持されること。
    /// 前クリップの終端ちょうどの合成時刻は、次クリップの先頭（素材時刻 sourceStart）に属する。
    func test_boundaryBelongsToNextClipWithRates() {
        let slow = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2, rate: 0.5)   // 合成 4 秒
        let fast = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14, rate: 2.0) // 合成 2 秒
        let mapping = TimelineMapping(clips: [slow, fast])

        // 境界(合成 4.0 秒)は fast の先頭に属する。
        let loc = mapping.sourceLocation(at: 4.0)
        XCTAssertEqual(loc?.clipID, fast.id)
        XCTAssertEqual(loc?.time ?? 0, 10.0, accuracy: 1e-9)
        // slow の sourceEnd ちょうどの素材時刻は逆写像できない（範囲外）。
        XCTAssertNil(mapping.compositionTime(clipID: slow.id, sourceTime: 2.0))
        // 末尾(合成 6.0 秒)は範囲外。
        XCTAssertNil(mapping.sourceLocation(at: 6.0))
    }

    /// 順写像の ulp 漏れ対策: 区間内ぎりぎりの合成時刻（totalDuration.nextDown）でも
    /// 素材時刻が半開区間 [sourceStart, sourceEnd) の内側に収まり、往復が nil にならないこと。
    /// rate=0.3 × sourceEnd=19.11827 は乗算の丸め上がりで sourceEnd ちょうどに達する実測再現ケース。
    func test_forwardMappingStaysInsideClipAtUlpBoundary() {
        for rate in [0.1, 0.3, 0.7, 1.0, 1.5, 3.3, 10.0] {
            let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 19.11827, rate: rate)
            let mapping = TimelineMapping(clips: [clip])
            let lastTime = mapping.totalDuration.nextDown
            guard let loc = mapping.sourceLocation(at: lastTime) else {
                XCTFail("expected a location at rate \(rate)")
                continue
            }
            XCTAssertLessThan(loc.time, clip.sourceEnd, "rate \(rate)")
            XCTAssertNotNil(mapping.compositionTime(clipID: clip.id, sourceTime: loc.time), "rate \(rate)")
        }
    }

    /// 逆写像の ulp 漏れ対策: sourceEnd 手前ぎりぎりの素材時刻（sourceEnd.nextDown）の
    /// 合成時刻がクリップの合成区間からはみ出さない（タイムライン終端に達しない）こと。
    func test_reverseMappingStaysInsideClipAtUlpBoundary() {
        for rate in [0.1, 0.3, 0.7, 1.0, 1.5, 3.3, 10.0] {
            let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 19.11827, rate: rate)
            let mapping = TimelineMapping(clips: [clip])
            guard let time = mapping.compositionTime(clipID: clip.id, sourceTime: clip.sourceEnd.nextDown) else {
                XCTFail("expected a composition time at rate \(rate)")
                continue
            }
            XCTAssertLessThan(time, mapping.totalDuration, "rate \(rate)")
            // 往復してもクリップの外（次クリップ側/範囲外）に出ないこと。
            XCTAssertEqual(mapping.sourceLocation(at: time)?.clipID, clip.id, "rate \(rate)")
        }
    }

    /// 複数クリップで rate が混在しても totalDuration が rate 込みの合算になること。
    func test_totalDurationWithMixedRates() {
        let clips = [
            TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3),              // 等速: 3 秒
            TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 3, rate: 2.0),   // 1.5 秒
            TimelineClip(sourceID: sourceA, sourceStart: 5, sourceEnd: 6, rate: 0.1)    // 10 秒
        ]
        let mapping = TimelineMapping(clips: clips)
        XCTAssertEqual(mapping.totalDuration, 14.5, accuracy: 1e-9)
    }
}

/// トランジション（重なり）付き写像のテスト。
/// 単一クリップ・transitions 空では既存挙動が 1 つも変わらないことが S2 の合格条件。
final class TimelineMappingTransitionTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private struct OverlapTestData {
        let mapping: TimelineMapping
        let clipA: TimelineClip
        let clipB: TimelineClip
    }

    /// A(素材Aの0-4秒) → B(素材Bの10-14秒)、A→B にクロスフェード duration 秒。
    /// duration=1 なら B は合成 3 秒から始まり、重なりは合成 [3, 4)。
    private func makeOverlapMapping(duration: Double = 1.0) -> OverlapTestData {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b],
                                      transitions: [a.id: TransitionSpec(kind: .crossfade, duration: duration)])
        return OverlapTestData(mapping: mapping, clipA: a, clipB: b)
    }

    /// トランジション duration の分だけ totalDuration が縮むこと（Σ合成尺 − ΣD）。
    func test_overlapReducesTotalDuration() {
        let data = makeOverlapMapping(duration: 1.0)
        XCTAssertEqual(data.mapping.totalDuration, 7.0, accuracy: 1e-9)
        // 後続クリップは 1 秒前倒しで始まる。
        XCTAssertEqual(data.mapping.clipStartTime(clipID: data.clipB.id) ?? 0, 3.0, accuracy: 1e-9)
    }

    /// 制約違反の duration は防御的に min(両クリップ合成尺)/2 へクランプされること。
    func test_overlapDurationIsDefensivelyClamped() {
        let data = makeOverlapMapping(duration: 100)
        // D = min(4, 4)/2 = 2 → totalDuration = 8 − 2 = 6。
        XCTAssertEqual(data.mapping.totalDuration, 6.0, accuracy: 1e-9)
        XCTAssertEqual(data.mapping.clipStartTime(clipID: data.clipB.id) ?? 0, 2.0, accuracy: 1e-9)
    }

    /// 重なり内では 2 要素（outgoing → incoming の順）と progress が返ること。
    func test_overlapReturnsTwoLocationsWithProgress() {
        let data = makeOverlapMapping()
        let locations = data.mapping.sourceLocations(at: 3.5)  // 重なり [3, 4) の中央
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations[0].side, .outgoing)
        XCTAssertEqual(locations[0].location.clipID, data.clipA.id)
        XCTAssertEqual(locations[0].location.time, 3.5, accuracy: 1e-9)
        XCTAssertEqual(locations[0].progress ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(locations[1].side, .incoming)
        XCTAssertEqual(locations[1].location.clipID, data.clipB.id)
        XCTAssertEqual(locations[1].location.time, 10.5, accuracy: 1e-9)
        XCTAssertEqual(locations[1].progress ?? -1, 0.5, accuracy: 1e-9)
    }

    /// 重なり外では 1 要素で side / progress は nil であること。範囲外は空配列。
    func test_outsideOverlapReturnsSingleLocation() {
        let data = makeOverlapMapping()
        let locations = data.mapping.sourceLocations(at: 1.0)
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0].location.clipID, data.clipA.id)
        XCTAssertNil(locations[0].side)
        XCTAssertNil(locations[0].progress)
        XCTAssertTrue(data.mapping.sourceLocations(at: -0.1).isEmpty)
        XCTAssertTrue(data.mapping.sourceLocations(at: 7.0).isEmpty)
    }

    /// 既存 sourceLocation(at:) は重なり内では後続（incoming）側を返すこと（互換定義）。
    func test_sourceLocationPrefersIncomingInOverlap() {
        let data = makeOverlapMapping()
        let loc = data.mapping.sourceLocation(at: 3.5)
        XCTAssertEqual(loc?.clipID, data.clipB.id)
        XCTAssertEqual(loc?.time ?? 0, 10.5, accuracy: 1e-9)
        // 重なり前は従来どおり先行クリップ。
        XCTAssertEqual(data.mapping.sourceLocation(at: 2.9)?.clipID, data.clipA.id)
    }

    /// 重なり境界の半開区間帰属: 開始(3.0)は重なりに属し progress=0、終端(4.0)は重なり外で B のみ。
    func test_overlapBoundariesAreHalfOpen() {
        let data = makeOverlapMapping()
        let atStart = data.mapping.sourceLocations(at: 3.0)
        XCTAssertEqual(atStart.count, 2)
        XCTAssertEqual(atStart[0].progress ?? -1, 0.0, accuracy: 1e-9)
        let atEnd = data.mapping.sourceLocations(at: 4.0)
        XCTAssertEqual(atEnd.count, 1)
        XCTAssertEqual(atEnd[0].location.clipID, data.clipB.id)
        XCTAssertEqual(atEnd[0].location.time, 11.0, accuracy: 1e-9)
        XCTAssertNil(atEnd[0].side)
    }

    /// 重なり内でも順写像→逆写像の往復が両側とも対称であること。
    func test_roundTripIsSymmetricInsideOverlap() {
        let data = makeOverlapMapping()
        for compositionTime in [3.0, 3.25, 3.9] {
            for entry in data.mapping.sourceLocations(at: compositionTime) {
                let roundTripped = data.mapping.compositionTime(clipID: entry.location.clipID,
                                                                sourceTime: entry.location.time)
                XCTAssertEqual(roundTripped ?? -1, compositionTime, accuracy: 1e-9,
                               "round trip failed for \(compositionTime) side \(String(describing: entry.side))")
            }
        }
    }

    /// ulp 境界: 重なり終端ぎりぎり（4.0.nextDown）でも 2 要素・progress < 1 で、
    /// 素材時刻が半開区間の内側に収まること。タイムライン終端ぎりぎりも範囲内であること。
    func test_ulpBoundariesInsideOverlap() {
        let data = makeOverlapMapping()
        let nearOverlapEnd = data.mapping.sourceLocations(at: 4.0.nextDown)
        XCTAssertEqual(nearOverlapEnd.count, 2)
        XCTAssertLessThan(nearOverlapEnd[0].progress ?? 2, 1.0)
        XCTAssertLessThan(nearOverlapEnd[0].location.time, data.clipA.sourceEnd)
        XCTAssertLessThan(nearOverlapEnd[1].location.time, data.clipB.sourceEnd)
        let nearTimelineEnd = data.mapping.sourceLocations(at: data.mapping.totalDuration.nextDown)
        XCTAssertEqual(nearTimelineEnd.count, 1)
        XCTAssertLessThan(nearTimelineEnd[0].location.time, data.clipB.sourceEnd)
    }

    /// transitions 空の init(clips:transitions:) は既存 init(clips:) と同一挙動であること。
    func test_emptyTransitionsMatchLegacyBehavior() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b], transitions: [:])
        XCTAssertEqual(mapping.totalDuration, 7.0, accuracy: 1e-9)
        for time in [0.0, 1.5, 3.0, 6.999] {
            let locations = mapping.sourceLocations(at: time)
            XCTAssertEqual(locations.count, 1, "\(time)")
            XCTAssertNil(locations[0].side, "\(time)")
            XCTAssertEqual(locations[0].location, mapping.sourceLocation(at: time), "\(time)")
        }
    }

    /// NaN の duration は 0（トランジションなし）として扱われ、写像を汚染しないこと。
    /// 素通しすると totalDuration=nan で全時刻の写像が nil になる。
    func test_nanTransitionDurationIsTreatedAsZero() {
        let data = makeOverlapMapping(duration: .nan)
        XCTAssertEqual(data.mapping.totalDuration, 8.0, accuracy: 1e-9)
        XCTAssertEqual(data.mapping.clipStartTime(clipID: data.clipB.id) ?? 0, 4.0, accuracy: 1e-9)
        let locations = data.mapping.sourceLocations(at: 3.5)
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0].location.clipID, data.clipA.id)
    }

    /// editTime(forDisplayTime:) が表示時刻（重なり込み）を編集時刻（重なりなし）へ変換すること。
    /// 重なり内の帰属は sourceLocation(at:) と同じ incoming 側。
    func test_editTimeConvertsDisplayTimeline() {
        let data = makeOverlapMapping()  // 重なりは表示 [3, 4)、編集タイムラインでは A=4 秒 + B=4 秒
        // 重なり前は恒等。
        XCTAssertEqual(data.mapping.editTime(forDisplayTime: 2.9) ?? -1, 2.9, accuracy: 1e-9)
        // 重なり内は incoming（B）に帰属: 表示 3.5 = B の先頭から 0.5 秒 → 編集 4.5。
        XCTAssertEqual(data.mapping.editTime(forDisplayTime: 3.5) ?? -1, 4.5, accuracy: 1e-9)
        // 重なり後: 表示 5.0 = B の先頭から 2 秒 → 編集 6.0。
        XCTAssertEqual(data.mapping.editTime(forDisplayTime: 5.0) ?? -1, 6.0, accuracy: 1e-9)
        // 範囲外は nil（表示タイムラインの totalDuration=7 が上限）。
        XCTAssertNil(data.mapping.editTime(forDisplayTime: -0.1))
        XCTAssertNil(data.mapping.editTime(forDisplayTime: 7.0))
    }

    /// transitions が空なら editTime は恒等変換であること。
    func test_editTimeIsIdentityWithoutTransitions() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b])
        for time in [0.0, 1.5, 3.0, 6.999] {
            XCTAssertEqual(mapping.editTime(forDisplayTime: time) ?? -1, time, accuracy: 1e-9, "\(time)")
        }
    }

    /// clipSpans がタイムライン順に全クリップの合成区間（重なり込み）を返すこと。
    func test_clipSpansExposeOverlappingIntervals() {
        let data = makeOverlapMapping()
        let spans = data.mapping.clipSpans
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].clip.id, data.clipA.id)
        XCTAssertEqual(spans[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 4.0, accuracy: 1e-9)
        XCTAssertEqual(spans[1].clip.id, data.clipB.id)
        XCTAssertEqual(spans[1].start, 3.0, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 7.0, accuracy: 1e-9)
    }
}
