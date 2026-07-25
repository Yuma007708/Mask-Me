import XCTest
@testable import MosaicCore

final class MosaicApplyRangeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    // MARK: - isActive（ゲート判定）

    /// ranges が空なら常に true（範囲指定なし = 全区間適用の既存挙動互換）であること。
    func test_emptyRangesAlwaysActive() {
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], sourceID: sourceA, sourceTime: 0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], sourceID: UUID(), sourceTime: 123.4))
    }

    /// 判定は半開区間 [sourceStart, sourceEnd) であること。sourceID 不一致は false。
    func test_isActiveUsesHalfOpenInterval() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 1.0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 2.0.nextDown))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 2.0))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 0.999))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceB, sourceTime: 1.5))
    }

    // MARK: - isActive（合成時刻ゲート。S10 で手動矩形・背景モザイクの描画に配線）

    /// ranges が空なら合成時刻ゲートも常に true（既存挙動と bit 同一）であること。
    func test_compositionGate_emptyRangesAlwaysActive() {
        let mapping = TimelineMapping(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)])
        for t in stride(from: -1.0, through: 5.0, by: 0.5) {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], mapping: mapping, compositionTime: t, photoSourceIDs: []),
                          "compositionTime \(t)")
        }
    }

    /// 合成時刻の境界フレームで ON/OFF が切り替わり、半開区間契約
    /// （`sourceEnd` ちょうどは区間外）が合成時刻側でも保たれること。
    func test_compositionGate_switchesAtBoundary() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [clip])
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 1.0.nextDown, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 2.0.nextDown, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 2.0, photoSourceIDs: []))
    }

    /// **速度変更されたクリップでは素材時刻で判定する**こと。
    /// rate=2 の 4 秒素材（合成 2 秒）で素材 [2,4) を指定した場合、ON になるのは
    /// 合成 [1,2) である。合成時刻をそのまま `isActive` に渡す誤実装だと [2,4) を見て
    /// 全フレーム OFF（または位置がずれる）になる。
    func test_compositionGate_usesSourceTimeForSpeedChangedClip() {
        let fast = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4, rate: 2.0)
        let mapping = TimelineMapping(clips: [fast])
        XCTAssertEqual(mapping.totalDuration, 2.0, accuracy: 1e-9)
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 0.5, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 1.9, photoSourceIDs: []))
    }

    /// 分割・並べ替えの後も素材アンカーが追従し、合成時刻ゲートの結果が
    /// 「その合成時刻に写る素材時刻」だけで決まること。
    func test_compositionGate_followsSourceAcrossSplitAndReorder() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)]
        // 素材 [2,4) は元の並びでは合成 [2,4)、並べ替え後は合成 [0,2)。
        let original = TimelineMapping(clips: [front, back])
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: original, compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: original, compositionTime: 3.0, photoSourceIDs: []))
        let reordered = TimelineMapping(clips: [back, front])
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: reordered, compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: reordered, compositionTime: 3.0, photoSourceIDs: []))
    }

    /// トランジションの重なり区間では「映っている素材のどれかが区間内なら適用」
    /// （素材アンカーを持たない手動矩形・背景モザイクの判定規則）。
    func test_compositionGate_overlapAppliesIfAnySourceIsInRange() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [a, b],
                                      transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 2)])
        // 重なりは合成 [2,4)。sourceB 側だけを区間内にする。
        let ranges = [MosaicApplyRange(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)]
        XCTAssertEqual(mapping.sourceLocations(at: 3.0).count, 2, "重なり区間の前提が崩れている")
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 3.0, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping, compositionTime: 1.0, photoSourceIDs: []),
                       "重なり外の sourceA 単独区間まで適用されている")
    }

    /// 写像が解決できない合成時刻（クリップ未構築・非有限）はフェイルオープンし、
    /// 範囲外の有限時刻はタイムラインの端へクランプしてから写像すること
    /// （`resolveSourceTime(atComposition:)` / `VideoMosaicExporter.resolveLocation` と同じ規則）。
    func test_compositionGate_failsOpenAndClampsOutOfRangeTimes() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 1)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: TimelineMapping(clips: []),
                                               compositionTime: 0.5, photoSourceIDs: []),
                      "クリップ未構築でゲートが閉じている（従来経路の挙動が変わる）")

        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [clip])
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: .nan, photoSourceIDs: []))
        // 負値 → 先頭（素材 0）へクランプ = 区間内。
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: -0.5, photoSourceIDs: []))
        // 合成尺ちょうど（半開区間の外）→ 終端（素材 4.nextDown）へクランプ = 区間外。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                compositionTime: 4.0, photoSourceIDs: []))
    }

    /// 顔の素材別ゲートも、合成時刻ゲートと**同じ方向にフェイルオープン**すること。
    ///
    /// 非有限の素材時刻（写像が壊れた時刻）でフェイル方向が食い違うと、
    /// 「顔にはモザイクが乗らないが手動矩形と背景モザイクは乗る」中途半端な絵になる。
    /// プロジェクトの原則どおり過剰適用（安全側）へ倒す。
    func test_sourceGate_failsOpenOnNonFiniteSourceTime() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 1)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: .nan))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA,
                                               sourceTime: .infinity))
        // 有限時刻の判定は従来どおり（フェイルオープンは非有限のときだけ）。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, sourceID: sourceA, sourceTime: 5))
    }

    /// 写真素材は素材時刻を 0 へ clamp してから判定すること
    /// （`MosaicApplyRange` 型の doc: 写真の適用区間は素材 [0, sourceEnd) を覆う）。
    func test_compositionGate_photoSourceClampsToZero() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let mapping = TimelineMapping(clips: [photo])
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)]
        for t in stride(from: 0.0, to: 3.0, by: 0.5) {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                   compositionTime: t, photoSourceIDs: [sourceA]),
                          "compositionTime \(t)")
        }
        // 素材 0 を含まない区間は写真では絶対にヒットしない（clamp 後が 0 のため）。
        let notCoveringZero = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: notCoveringZero, mapping: mapping,
                                                compositionTime: 1.5, photoSourceIDs: [sourceA]))
    }

    // MARK: - effectiveRanges（孤児区間の除外。S10 レビュー修正）

    /// 合成全域を `step` 刻みで走査して、ゲートが ON になった割合を返す。
    /// レビューが実測した「ゲート ON 比率」と同じ土俵で比較するための計測子。
    private func gateOnRatio(ranges: [MosaicApplyRange], mapping: TimelineMapping,
                             samples: Int = 2001) -> Double {
        guard mapping.totalDuration > 0 else { return 0 }
        let effective = MosaicApplyGate.effectiveRanges(ranges, mapping: mapping)
        var onCount = 0
        for index in 0..<samples {
            let t = mapping.totalDuration * Double(index) / Double(samples - 1)
            if MosaicApplyGate.isActive(ranges: effective, mapping: mapping,
                                        compositionTime: t, photoSourceIDs: []) {
                onCount += 1
            }
        }
        return Double(onCount) / Double(samples)
    }

    /// **孤児区間（どのクリップの使用範囲とも交差しない適用区間）でモザイクが
    /// 全区間 OFF にならないこと。**
    ///
    /// レビュー実測の再現手順そのまま: 4 秒素材に区間 source[1,2) を置き、左端を
    /// 2.5 までトリムすると帯が 1 本 → 0 本になる。修正前はこのとき `applyRanges` が
    /// 非空のままゲートに渡り、ON 比率が 0.24988 → **0.0**（全区間 OFF・帯が無いので
    /// 削除もできず undo 以外に復帰不能）になっていた。
    func test_effectiveRanges_orphanRangeDoesNotBlackOutWholeTimeline() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        let before = TimelineMapping(clips: [clip])
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: ranges, mapping: before).count, 1)
        XCTAssertEqual(gateOnRatio(ranges: ranges, mapping: before), 0.24988, accuracy: 1e-5)

        // 左端トリム 1 回で区間はどのクリップの使用範囲とも交差しなくなる（孤児）。
        let trimmed = TimelineClip(id: clip.id, sourceID: sourceA, sourceStart: 2.5, sourceEnd: 4)
        let after = TimelineMapping(clips: [trimmed])
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: ranges, mapping: after).isEmpty,
                      "前提が崩れている（孤児になっていない）")
        XCTAssertTrue(MosaicApplyGate.effectiveRanges(ranges, mapping: after).isEmpty,
                      "孤児区間がゲートに残っている")
        XCTAssertEqual(gateOnRatio(ranges: ranges, mapping: after), 1.0, accuracy: 1e-9,
                       "孤児区間で全区間 OFF になっている（復帰不能な事故）")
    }

    /// **帯 UI と有効区間が常に一致すること**（今回の修正の本質）。
    /// 「帯が n 本 ⇔ 有効区間が n 個」「帯 0 本 ⇔ ゲート常時 ON」。
    func test_effectiveRanges_matchesApplySpansExactly() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 5, sourceEnd: 7)
        let mapping = TimelineMapping(clips: [clipA, clipB])
        let ranges = [
            MosaicApplyRange(sourceID: sourceA, sourceStart: 0.5, sourceEnd: 1.0),  // 帯に出る
            MosaicApplyRange(sourceID: sourceB, sourceStart: 5.5, sourceEnd: 6.0),  // 帯に出る
            MosaicApplyRange(sourceID: sourceA, sourceStart: 8.0, sourceEnd: 9.0),  // 孤児
            MosaicApplyRange(sourceID: sourceB, sourceStart: 0.0, sourceEnd: 1.0),  // 孤児
            MosaicApplyRange(sourceID: UUID(), sourceStart: 0.0, sourceEnd: 9.0)    // 素材ごと不在
        ]
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping)
        let effective = MosaicApplyGate.effectiveRanges(ranges, mapping: mapping)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(effective.count, spans.count, "帯の本数と有効区間の個数が食い違う")
        XCTAssertEqual(Set(effective.map(\.id)), Set(spans.map(\.rangeID)),
                       "帯に出ている区間と有効区間の集合が食い違う")

        // 帯 0 本（全部が孤児）なら「区間指定なし」＝ゲート常時 ON。
        let orphansOnly = Array(ranges.dropFirst(2))
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: orphansOnly, mapping: mapping).isEmpty)
        XCTAssertEqual(gateOnRatio(ranges: orphansOnly, mapping: mapping), 1.0, accuracy: 1e-9)
    }

    /// クリップを 1 本も持たない（未構築）タイムラインでは全区間が有効から外れ、
    /// 顔ゲート・合成時刻ゲートの両方がフェイルオープンで揃うこと。
    func test_effectiveRanges_emptyTimelineDropsEverything() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 1)]
        let empty = TimelineMapping(clips: [])
        let effective = MosaicApplyGate.effectiveRanges(ranges, mapping: empty)
        XCTAssertTrue(effective.isEmpty)
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, sourceID: sourceA, sourceTime: 5),
                      "クリップ未構築で顔ゲートだけフェイルクローズしている")
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, mapping: empty,
                                               compositionTime: 5, photoSourceIDs: []))
    }

    /// 写真素材（素材時刻 0 へ clamp）の区間が孤児判定で落ちないこと。
    func test_effectiveRanges_keepsPhotoSourceRanges() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let mapping = TimelineMapping(clips: [photo])
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)]
        XCTAssertEqual(MosaicApplyGate.effectiveRanges(ranges, mapping: mapping).count, 1)
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping).count, 1)
    }

    /// 重なり区間ごとの適用対象素材（`gateState.activeSourceIDs`）が素材別に出ること。
    /// エクスポートの強制再検出（`gateChanged`）はこの集合の変化で判断する。
    func test_gateState_reportsActiveSourceIDsPerFrame() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [a, b],
                                      transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 2)])
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)]
        // 重なりは合成 [2,4)。A 単独区間 → {A}、重なり → {A}（B は区間外）、B 単独 → {}。
        XCTAssertEqual(MosaicApplyGate.gateState(ranges: ranges, mapping: mapping,
                                                 compositionTime: 1.0, photoSourceIDs: []).activeSourceIDs,
                       [sourceA])
        let inOverlap = MosaicApplyGate.gateState(ranges: ranges, mapping: mapping,
                                                  compositionTime: 3.0, photoSourceIDs: [])
        XCTAssertEqual(inOverlap.activeSourceIDs, [sourceA],
                       "重なり区間で区間外の素材まで適用対象になっている")
        XCTAssertTrue(inOverlap.isActive)
        let afterOverlap = MosaicApplyGate.gateState(ranges: ranges, mapping: mapping,
                                                     compositionTime: 5.0, photoSourceIDs: [])
        XCTAssertTrue(afterOverlap.activeSourceIDs.isEmpty)
        XCTAssertFalse(afterOverlap.isActive)
    }

    /// 絞り込みのコスト実測（50 クリップ × 100 区間）。
    /// 描画ごとに回すには重すぎるが、タイムライン変更時 1 回なら無視できることを固定する。
    func test_effectiveRanges_costIsNegligiblePerTimelineChange() {
        let sources = (0..<50).map { _ in UUID() }
        let clips = sources.map { TimelineClip(sourceID: $0, sourceStart: 0, sourceEnd: 2) }
        let mapping = TimelineMapping(clips: clips)
        let ranges = (0..<100).map { index in
            MosaicApplyRange(sourceID: sources[index % sources.count],
                             sourceStart: 0.5, sourceEnd: 1.5)
        }
        let start = Date()
        var total = 0
        for _ in 0..<100 { total += MosaicApplyGate.effectiveRanges(ranges, mapping: mapping).count }
        let msPerCall = Date().timeIntervalSince(start) * 1000 / 100
        XCTAssertEqual(total, 100 * 100)
        XCTAssertLessThan(msPerCall, 5.0, "effectiveRanges が \(msPerCall)ms/回 と重すぎる")
        print("[S10-perf] effectiveRanges 50 clips x 100 ranges: \(msPerCall) ms/call")
    }

    // MARK: - 合成時刻区間の分解

    /// 複数クリップを跨ぐ合成区間は素材ごとのセグメントに分割されること。
    func test_addingIntervalAcrossClipsSplitsPerSource() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 4,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].sourceID, sourceA)
        XCTAssertEqual(ranges[0].sourceStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].sourceID, sourceB)
        XCTAssertEqual(ranges[1].sourceStart, 10.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].sourceEnd, 11.0, accuracy: 1e-9)
    }

    /// rate ≠ 1 のクリップでは合成区間が素材時刻へスケールされること（2x で 2 倍の素材区間）。
    func test_addingIntervalScalesWithRate() {
        let fast = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4, rate: 2.0) // 合成 2 秒
        let mapping = TimelineMapping(clips: [fast])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 0.5, to: 1.0,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
    }

    /// 同一素材を分割した 2 クリップに跨る区間は、素材時刻で 1 本にマージされること。
    func test_addingIntervalMergesAcrossSplitClips() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [front, back])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 1, to: 3,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].sourceID, sourceA)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
    }

    /// 既存区間と重複・隣接する追加は同一 sourceID 内でマージされ、
    /// マージ結果は最も早い開始位置の区間の id を引き継ぐこと。別素材の区間は独立に残ること。
    func test_addingIntervalMergesWithExisting() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
                        MosaicApplyRange(sourceID: sourceB, sourceStart: 0, sourceEnd: 1)]
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 3,
                                            mapping: mapping, existing: existing)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].id, existing[0].id)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1], existing[1])
    }

    /// 新規セグメントが既存区間を**前方に**伸ばす場合でも、マージ結果は既存区間の id を
    /// 引き継ぐこと（開始位置最小の側ではなく入力順優先。UI の選択が飛ばないため）。
    func test_extendingForwardKeepsExistingID() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 0.5, to: 1.2,
                                            mapping: mapping, existing: existing)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].id, existing[0].id)
        XCTAssertEqual(ranges[0].sourceStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
    }

    /// 逆転・空の合成区間では existing がそのまま返ること。
    func test_addingInvalidIntervalKeepsExisting() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 3, to: 3,
                                              mapping: mapping, existing: existing), existing)
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 4, to: 2,
                                              mapping: mapping, existing: existing), existing)
    }

    // MARK: - 素材アンカーの自動追従

    /// 素材時刻アンカーのため、クリップの分割・並べ替え（mapping の変化）後も
    /// 同じ素材時刻に対する isActive 判定が不変であること。
    func test_rangesFollowSourceAcrossTimelineEdits() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let original = TimelineMapping(clips: [a, b])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 1, to: 2,
                                            mapping: original, existing: [])  // 素材A [1, 2)

        // 分割 + 並べ替え後の mapping（B → A後半 → A前半）でも、素材時刻の判定は同じ。
        var frontA = a
        frontA.sourceEnd = 2
        let backA = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 4)
        let reordered = TimelineMapping(clips: [b, backA, frontA])
        for compositionTime in stride(from: 0.0, to: reordered.totalDuration, by: 0.25) {
            guard let loc = reordered.sourceLocation(at: compositionTime) else {
                XCTFail("expected a location at \(compositionTime)")
                continue
            }
            let expected = loc.sourceID == sourceA && loc.time >= 1 && loc.time < 2
            XCTAssertEqual(MosaicApplyGate.isActive(ranges: ranges, sourceID: loc.sourceID,
                                                    sourceTime: loc.time),
                           expected, "compositionTime \(compositionTime)")
        }
    }

    // MARK: - 削除

    /// removingRange は指定 id の区間だけを取り除き、未知の id では変更しないこと。
    func test_removingRange() {
        let ranges = [MosaicApplyRange(sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
                      MosaicApplyRange(sourceID: sourceA, sourceStart: 3, sourceEnd: 4)]
        let removed = MosaicApplyGate.removingRange(id: ranges[0].id, from: ranges)
        XCTAssertEqual(removed, [ranges[1]])
        XCTAssertEqual(MosaicApplyGate.removingRange(id: UUID(), from: ranges), ranges)
    }

    // MARK: - Codable

    /// エンコード→デコードの round-trip で全プロパティが一致すること。
    func test_codableRoundTrip() throws {
        let range = MosaicApplyRange(sourceID: sourceA, sourceStart: 1.25, sourceEnd: 8.5)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(MosaicApplyRange.self, from: data)
        XCTAssertEqual(decoded, range)
    }
}
