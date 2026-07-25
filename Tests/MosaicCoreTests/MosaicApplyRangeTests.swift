import XCTest
@testable import MosaicCore

final class MosaicApplyRangeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// そのクリップに属する適用区間（`clipID` + `sourceID` を必ずクリップから取る）。
    private func range(_ clip: TimelineClip, _ start: Double, _ end: Double) -> MosaicApplyRange {
        MosaicApplyRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: start, sourceEnd: end)
    }

    // MARK: - isActive（素材別ゲート）の判定順序

    /// **判定順序 ①②③ が仕様そのものである**ことを固定する（S11）。
    ///
    /// - ① `clipID` が nil（写像不能）→ フェイルオープン。② を先に置くと
    ///   クリップ未構築の窓（動画ロード中）で顔だけモザイクが外れる。
    /// - ② 区間 0 本 → OFF（新仕様。旧仕様の「空 = 全区間 ON」から反転した）。
    /// - ③ 非有限の素材時刻（写像破損）→ フェイルオープン。③ を ② より前に置くと、
    ///   ユーザーが全区間を削除した状態で NaN 時刻だけ ON に戻る。
    func test_isActive_decisionOrderClipIDThenEmptyThenNonFinite() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [range(clip, 1, 2)]

        // ① 写像不能（clipID = nil）は区間の有無に関わらずフェイルオープン。
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], clipID: nil, sourceID: sourceA, sourceTime: 0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, clipID: nil, sourceID: sourceA, sourceTime: 99))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: [], clipID: nil, sourceID: sourceA, sourceTime: .nan))

        // ② 区間 0 本 + clipID あり → OFF。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: [], clipID: clip.id, sourceID: sourceA, sourceTime: 0))
        // ② が ③ より先: 全削除した状態では NaN 時刻でも ON に戻らない。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: [], clipID: clip.id, sourceID: sourceA, sourceTime: .nan))

        // ③ 区間あり + 非有限時刻 → フェイルオープン（過剰適用が安全側）。
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceA, sourceTime: .nan))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id,
                                               sourceID: sourceA, sourceTime: .infinity))
        // 有限時刻の判定は通常どおり（フェイルオープンは非有限のときだけ）。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceA, sourceTime: 5))
    }

    /// 判定は半開区間 [sourceStart, sourceEnd)。`clipID` / `sourceID` 不一致は false。
    func test_isActiveUsesHalfOpenIntervalAndClipScope() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let other = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [range(clip, 1, 2)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceA, sourceTime: 1.0))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id,
                                               sourceID: sourceA, sourceTime: 2.0.nextDown))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceA, sourceTime: 2.0))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceA, sourceTime: 0.999))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, clipID: clip.id, sourceID: sourceB, sourceTime: 1.5))
        // 同一素材の別クリップ（＝S11 で直したバグの本体）は素通ししない。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, clipID: other.id, sourceID: sourceA, sourceTime: 1.5),
                       "同一素材の別クリップまで区間が効いている")
    }

    // MARK: - isActive（合成時刻ゲート。手動矩形・背景モザイクの描画に配線）

    /// **区間 0 本なら合成時刻ゲートも全区間 OFF**（S11 で意味が反転した）。
    func test_compositionGate_emptyRangesIsOffEverywhere() {
        let mapping = TimelineMapping(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)])
        for t in stride(from: -1.0, through: 5.0, by: 0.5) {
            XCTAssertFalse(MosaicApplyGate.isActive(ranges: [], mapping: mapping,
                                                    compositionTime: t, photoSourceIDs: []),
                           "compositionTime \(t)")
        }
        // 区間 0 本のとき activeSourceIDs は**空集合**にすること。「映っている素材すべて」を
        // 返すと、エクスポートの gateChanged が「区間なし → 区間あり」を検出できなくなる。
        let state = MosaicApplyGate.gateState(ranges: [], mapping: mapping,
                                              compositionTime: 1.0, photoSourceIDs: [])
        XCTAssertTrue(state.activeSourceIDs.isEmpty)
        XCTAssertFalse(state.isActive)
    }

    /// 合成時刻の境界フレームで ON/OFF が切り替わり、半開区間契約
    /// （`sourceEnd` ちょうどは区間外）が合成時刻側でも保たれること。
    func test_compositionGate_switchesAtBoundary() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [clip])
        let ranges = [range(clip, 1, 2)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                compositionTime: 1.0.nextDown, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: 2.0.nextDown, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                compositionTime: 2.0, photoSourceIDs: []))
    }

    /// **速度変更されたクリップでは素材時刻で判定する**こと。
    /// rate=2 の 4 秒素材（合成 2 秒）で素材 [2,4) を指定した場合、ON になるのは
    /// 合成 [1,2) である。合成時刻をそのまま `isActive` に渡す誤実装だと [2,4) を見て
    /// 全フレーム OFF（または位置がずれる）になる。
    func test_compositionGate_usesSourceTimeForSpeedChangedClip() {
        let fast = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4, rate: 2.0)
        let mapping = TimelineMapping(clips: [fast])
        XCTAssertEqual(mapping.totalDuration, 2.0, accuracy: 1e-9)
        let ranges = [range(fast, 2, 4)]
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                compositionTime: 0.5, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: 1.0, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: 1.9, photoSourceIDs: []))
    }

    /// トランジションの重なり区間では「映っている素材のどれかが区間内なら適用」
    /// （素材アンカーを持たない手動矩形・背景モザイクの判定規則）。
    func test_compositionGate_overlapAppliesIfAnySourceIsInRange() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [a, b],
                                      transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 2)])
        // 重なりは合成 [2,4)。sourceB 側だけを区間内にする。
        let ranges = [range(b, 0, 4)]
        XCTAssertEqual(mapping.sourceLocations(at: 3.0).count, 2, "重なり区間の前提が崩れている")
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                               compositionTime: 3.0, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: ranges, mapping: mapping,
                                                compositionTime: 1.0, photoSourceIDs: []),
                       "重なり外の sourceA 単独区間まで適用されている")
    }

    /// 写像が解決できない合成時刻（クリップ未構築・非有限）はフェイルオープンし、
    /// 範囲外の有限時刻はタイムラインの端へクランプしてから写像すること
    /// （`resolveSourceLocation(atComposition:)` / `VideoMosaicExporter.resolveLocation` と同じ規則）。
    func test_compositionGate_failsOpenAndClampsOutOfRangeTimes() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [range(clip, 0, 1)]
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: ranges, mapping: TimelineMapping(clips: []),
                                               compositionTime: 0.5, photoSourceIDs: []),
                      "クリップ未構築でゲートが閉じている（写像不能はフェイルオープン）")

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

    // MARK: - effectiveRanges（帯とゲートの一致 = 不変条件 I1）

    /// 合成全域を `step` 刻みで走査して、ゲートが ON になった割合を返す。
    /// 「帯 0 本 ⇔ 全区間 OFF」を実測で確かめるための計測子。
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

    /// **帯 0 本 ⇔ 全区間 OFF**（不変条件 I1）。
    ///
    /// 4 秒素材に区間 source[1,2) を置くと帯 1 本・ON 比率 0.24988。左端を 2.5 まで
    /// トリムすると区間はどのクリップの使用範囲とも交差しなくなり（孤児）、
    /// 帯 0 本・ON 比率 0.0 になる。旧仕様ではここが「フェイルオープンで 1.0」だった。
    func test_effectiveRanges_orphanRangeTurnsGateOff() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [range(clip, 1, 2)]
        let before = TimelineMapping(clips: [clip])
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: ranges, mapping: before, photoSourceIDs: []).count, 1)
        XCTAssertEqual(gateOnRatio(ranges: ranges, mapping: before), 0.24988, accuracy: 1e-5)

        let trimmed = TimelineClip(id: clip.id, sourceID: sourceA, sourceStart: 2.5, sourceEnd: 4)
        let after = TimelineMapping(clips: [trimmed])
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: ranges, mapping: after, photoSourceIDs: []).isEmpty,
                      "前提が崩れている（孤児になっていない）")
        XCTAssertTrue(MosaicApplyGate.effectiveRanges(ranges, mapping: after).isEmpty,
                      "孤児区間がゲートに残っている")
        XCTAssertEqual(gateOnRatio(ranges: ranges, mapping: after), 0.0, accuracy: 1e-9,
                       "帯 0 本なのにゲートが ON になっている")
        print("[S11-gate] 帯 \(TimelineBandLayout.applySpans(ranges: ranges, mapping: before, photoSourceIDs: []).count) 本 → "
              + "ON 比率 \(gateOnRatio(ranges: ranges, mapping: before)) / "
              + "帯 \(TimelineBandLayout.applySpans(ranges: ranges, mapping: after, photoSourceIDs: []).count) 本 → "
              + "ON 比率 \(gateOnRatio(ranges: ranges, mapping: after))")
        // 区間データそのものは温存されるので、トリムを戻せば復活する。
        XCTAssertEqual(gateOnRatio(ranges: ranges, mapping: before), 0.24988, accuracy: 1e-5)
    }

    /// **帯 UI と有効区間が常に一致すること**（I1 / I3）。
    /// 「帯が n 本 ⇔ 有効区間が n 個」「帯 0 本 ⇔ ゲート全区間 OFF」。
    func test_effectiveRanges_matchesApplySpansExactly() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 5, sourceEnd: 7)
        let mapping = TimelineMapping(clips: [clipA, clipB])
        let ranges = [
            range(clipA, 0.5, 1.0),                                        // 帯に出る
            range(clipB, 5.5, 6.0),                                        // 帯に出る
            range(clipA, 8.0, 9.0),                                        // 孤児（素材範囲外）
            range(clipB, 0.0, 1.0),                                        // 孤児（素材範囲外）
            MosaicApplyRange(clipID: UUID(), sourceID: sourceA, sourceStart: 0, sourceEnd: 9),
            MosaicApplyRange(clipID: clipA.id, sourceID: UUID(), sourceStart: 0, sourceEnd: 9),
            // 境界 1 ulp: clipA の終端ちょうどから始まる区間は交差 0 なので帯にもゲートにも出ない。
            range(clipA, 2.0, 3.0)
        ]
        let spans = TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: [])
        let effective = MosaicApplyGate.effectiveRanges(ranges, mapping: mapping)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(effective.count, spans.count, "帯の本数と有効区間の個数が食い違う")
        XCTAssertEqual(Set(effective.map(\.id)), Set(spans.map(\.rangeID)),
                       "帯に出ている区間と有効区間の集合が食い違う")
        // 終端 1 ulp 手前まで縮めれば両方に出る（交差判定が同じ式である証拠）。
        let oneUlp = [range(clipA, 2.0.nextDown, 3.0)]
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: oneUlp, mapping: mapping, photoSourceIDs: []).count, 1)
        XCTAssertEqual(MosaicApplyGate.effectiveRanges(oneUlp, mapping: mapping).count, 1)

        // 帯 0 本（全部が孤児）= 全区間 OFF。
        let orphansOnly = Array(ranges.dropFirst(2))
        XCTAssertTrue(TimelineBandLayout.applySpans(ranges: orphansOnly, mapping: mapping, photoSourceIDs: []).isEmpty)
        XCTAssertEqual(gateOnRatio(ranges: orphansOnly, mapping: mapping), 0.0, accuracy: 1e-9)
    }

    /// クリップを 1 本も持たない（未構築）タイムラインでは全区間が有効から外れ、
    /// 顔ゲート・合成時刻ゲートの両方がフェイルオープンで揃うこと（I4）。
    ///
    /// 顔ゲート側の「写像不能」は `clipID == nil` で表される。実際の呼び出し元
    /// （`displayFaces` / `transitionFaces`）はクリップ未構築のとき必ず nil を渡す。
    func test_effectiveRanges_emptyTimelineDropsEverything() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let ranges = [range(clip, 0, 1)]
        let empty = TimelineMapping(clips: [])
        let effective = MosaicApplyGate.effectiveRanges(ranges, mapping: empty)
        XCTAssertTrue(effective.isEmpty)
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, clipID: nil,
                                               sourceID: sourceA, sourceTime: 5),
                      "クリップ未構築で顔ゲートだけフェイルクローズしている")
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: effective, mapping: empty,
                                               compositionTime: 5, photoSourceIDs: []))
    }

    /// 写真素材（素材時刻 0 へ clamp）の区間が孤児判定で落ちないこと。
    func test_effectiveRanges_keepsPhotoSourceRanges() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let mapping = TimelineMapping(clips: [photo])
        let ranges = [range(photo, 0, 3)]
        XCTAssertEqual(MosaicApplyGate.effectiveRanges(ranges, mapping: mapping).count, 1)
        XCTAssertEqual(TimelineBandLayout.applySpans(ranges: ranges, mapping: mapping, photoSourceIDs: []).count, 1)
    }

    /// 重なり区間ごとの適用対象素材（`gateState.activeSourceIDs`）が素材別に出ること。
    /// エクスポートの強制再検出（`gateChanged`）はこの集合の変化で判断する。
    func test_gateState_reportsActiveSourceIDsPerFrame() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let mapping = TimelineMapping(clips: [a, b],
                                      transitions: [a.id: TransitionSpec(kind: .crossfade, duration: 2)])
        let ranges = [range(a, 0, 4)]
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

    // MARK: - 合成時刻区間の分解

    /// 複数クリップを跨ぐ合成区間はクリップごとのセグメントに分割されること。
    func test_addingIntervalAcrossClipsSplitsPerClip() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        let mapping = TimelineMapping(clips: [a, b])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 2, to: 4,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].clipID, a.id)
        XCTAssertEqual(ranges[0].sourceID, sourceA)
        XCTAssertEqual(ranges[0].sourceStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].clipID, b.id)
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
        XCTAssertEqual(ranges[0].clipID, fast.id)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
    }

    /// **同一素材を分割した 2 クリップに跨る区間は 1 本にマージされない**（S11 で反転）。
    ///
    /// 旧仕様は素材アンカーだけだったので境界で 1 本になり、その 1 本が両クリップに
    /// 効いてしまっていた。clipID が別なので必ず 2 本に分かれる。
    func test_addingIntervalDoesNotMergeAcrossSplitClips() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [front, back])
        let ranges = MosaicApplyGate.ranges(addingCompositionInterval: 1, to: 3,
                                            mapping: mapping, existing: [])
        XCTAssertEqual(ranges.count, 2, "clipID をまたいでマージされている")
        XCTAssertEqual(ranges[0].clipID, front.id)
        XCTAssertEqual(ranges[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].sourceEnd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].clipID, back.id)
        XCTAssertEqual(ranges[1].sourceStart, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].sourceEnd, 3.0, accuracy: 1e-9)
    }

    /// 既存区間と重複・隣接する追加は同一 clipID 内でマージされ、
    /// マージ結果は入力順で最初の区間の id を引き継ぐこと。別クリップの区間は独立に残ること。
    func test_addingIntervalMergesWithExisting() {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let other = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [a])
        let existing = [range(a, 1, 2), range(other, 0, 1)]
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
        let existing = [range(a, 1, 2)]
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
        let existing = [range(a, 1, 2)]
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 3, to: 3,
                                              mapping: mapping, existing: existing), existing)
        XCTAssertEqual(MosaicApplyGate.ranges(addingCompositionInterval: 4, to: 2,
                                              mapping: mapping, existing: existing), existing)
    }

    // MARK: - 削除

    /// removingRange は指定 id の区間だけを取り除き、未知の id では変更しないこと。
    func test_removingRange() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 5)
        let ranges = [range(clip, 1, 2), range(clip, 3, 4)]
        let removed = MosaicApplyGate.removingRange(id: ranges[0].id, from: ranges)
        XCTAssertEqual(removed, [ranges[1]])
        XCTAssertEqual(MosaicApplyGate.removingRange(id: UUID(), from: ranges), ranges)
    }

    // MARK: - Codable

    /// エンコード→デコードの round-trip で全プロパティ（clipID を含む）が一致すること。
    func test_codableRoundTrip() throws {
        let range = MosaicApplyRange(clipID: UUID(), sourceID: sourceA, sourceStart: 1.25, sourceEnd: 8.5)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(MosaicApplyRange.self, from: data)
        XCTAssertEqual(decoded, range)
        XCTAssertEqual(decoded.clipID, range.clipID)
    }

    /// **`MosaicApplyRange` の Codable に旧形式フォールバックが無いこと。**
    /// `clipID` 欠落を `?? UUID()` で埋めると、どのクリップとも一致しない sentinel が
    /// 黙って残り、その区間は永久に効かなくなる。旧 JSON は `TimelineState` 側で吸収する。
    func test_codable_rejectsLegacyJSONWithoutClipID() {
        let legacy = """
        {"id":"\(UUID().uuidString)","sourceID":"\(sourceA.uuidString)","sourceStart":0,"sourceEnd":1}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(MosaicApplyRange.self,
                                                      from: Data(legacy.utf8)),
                             "clipID 無しの JSON が黙って通っている")
    }
}
