import XCTest
@testable import MosaicCore

/// S11: 吸着（`TimelineSnap.swift`）。
///
/// 最重要は **「吸着 → クランプ」の順序**を固定すること。逆順にすると
/// クランプで最小尺に止めた端を吸着が内側へ引き戻し、クリップが
/// `TimelineEditOperations.minimumClipDuration` を割る。
final class TimelineSnapTests: XCTestCase {
    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }

    // MARK: - 候補の収集

    /// クリップ帯の両端・適用区間の両端・プレイヘッド・0・全体尺が候補になる。
    func test_candidates_collectsAllAnchors() {
        let first = clip(start: 0, end: 4)
        let second = clip(start: 0, end: 6)
        let mapping = TimelineMapping(clips: [first, second])
        let layouts = TimelineBandLayout.clipLayouts(mapping: mapping)
        let range = MosaicApplyRange(clipID: first.id, sourceID: first.sourceID, sourceStart: 1, sourceEnd: 2)
        let spans = TimelineBandLayout.applySpans(ranges: [range], mapping: mapping)

        let candidates = TimelineSnap.candidates(layouts: layouts, applySpans: spans,
                                                 playheadTime: 7.5, totalDuration: mapping.totalDuration)
        XCTAssertEqual(candidates, [0, 1, 2, 4, 7.5, 10])
        // 昇順・重複除去済み（帯の境界 4 は「1本目の終わり」と「2本目の始まり」で 1 件）。
        XCTAssertEqual(candidates, candidates.sorted())
    }

    /// 掴んでいる要素の候補は外れる（自分の端に吸着すると操作が固まる）。
    ///
    /// **クリップは 1 本外すだけでは継ぎ目が消えない**（帯どうしが接しているので、
    /// 同じ時刻を隣のクリップも候補として出す）。継ぎ目そのものを外したいときは
    /// 隣も一緒に渡す必要がある、という制約をここで固定する。
    func test_candidates_excludesGrabbedElement() {
        let first = clip(start: 0, end: 4)
        let second = clip(start: 0, end: 6)
        let mapping = TimelineMapping(clips: [first, second])
        let layouts = TimelineBandLayout.clipLayouts(mapping: mapping)
        let range = MosaicApplyRange(clipID: first.id, sourceID: first.sourceID, sourceStart: 1, sourceEnd: 2)
        let spans = TimelineBandLayout.applySpans(ranges: [range], mapping: mapping)

        // 適用区間を外すと、その両端（1・2）だけが消える。
        XCTAssertEqual(TimelineSnap.candidates(layouts: layouts, applySpans: spans,
                                               playheadTime: 7.5, totalDuration: 10,
                                               excluding: [range.id]),
                       [0, 4, 7.5, 10])

        // 1 本目を外しても継ぎ目 4 は残る（2 本目の帯の開始として出るため）。
        // 1 本目に載っている適用区間は一緒に外れる（掴んでいるクリップの上の区間だから）。
        XCTAssertEqual(TimelineSnap.candidates(layouts: layouts, applySpans: spans,
                                               playheadTime: 7.5, totalDuration: 10,
                                               excluding: [first.id]),
                       [0, 4, 7.5, 10])

        // 両方外すと継ぎ目が消える（0 と 10 は定数・全体尺として残る）。
        XCTAssertEqual(TimelineSnap.candidates(layouts: layouts, applySpans: spans,
                                               playheadTime: 7.5, totalDuration: 10,
                                               excluding: [first.id, second.id]),
                       [0, 7.5, 10])
    }

    /// 非有限（壊れた totalDuration・NaN プレイヘッド）は候補に混ぜない。
    func test_candidates_dropsNonFinite() {
        let only = clip(start: 0, end: 4)
        let layouts = TimelineBandLayout.clipLayouts(mapping: TimelineMapping(clips: [only]))
        let candidates = TimelineSnap.candidates(layouts: layouts, applySpans: [],
                                                 playheadTime: .nan, totalDuration: .infinity)
        XCTAssertEqual(candidates, [0, 4])
    }

    // MARK: - 吸着

    func test_snapped_picksNearestWithinTolerance() {
        let candidates: [Double] = [0, 4, 7.5, 10]
        let hit = TimelineSnap.snapped(time: 4.2, candidates: candidates, tolerance: 0.3)
        XCTAssertEqual(hit.time, 4, accuracy: 1e-12)
        XCTAssertEqual(hit.snappedTo, 4)
        XCTAssertTrue(hit.isSnapped)

        let miss = TimelineSnap.snapped(time: 4.9, candidates: candidates, tolerance: 0.3)
        XCTAssertEqual(miss.time, 4.9, accuracy: 1e-12)
        XCTAssertNil(miss.snappedTo)
        XCTAssertFalse(miss.isSnapped)

        // 許容量ちょうどは吸着する（境界を含む）。
        XCTAssertEqual(TimelineSnap.snapped(time: 4.3, candidates: candidates, tolerance: 0.3).snappedTo, 4)
    }

    /// 距離が同じなら小さい時刻（並び順で結果が変わらない）。
    func test_snapped_tieBreaksToSmallerTime() {
        XCTAssertEqual(TimelineSnap.snapped(time: 5, candidates: [4, 6], tolerance: 2).snappedTo, 4)
        XCTAssertEqual(TimelineSnap.snapped(time: 5, candidates: [6, 4], tolerance: 2).snappedTo, 4)
    }

    /// 壊れた入力では吸着しない（入力をそのまま返す）。
    func test_snapped_degenerateInputs() {
        XCTAssertNil(TimelineSnap.snapped(time: 4.1, candidates: [], tolerance: 1).snappedTo)
        XCTAssertNil(TimelineSnap.snapped(time: 4.1, candidates: [4], tolerance: 0).snappedTo)
        XCTAssertNil(TimelineSnap.snapped(time: 4.1, candidates: [4], tolerance: -1).snappedTo)
        XCTAssertNil(TimelineSnap.snapped(time: 4.1, candidates: [4], tolerance: .nan).snappedTo)
        XCTAssertNil(TimelineSnap.snapped(time: 4.1, candidates: [.nan, .infinity], tolerance: 1).snappedTo)
        let nan = TimelineSnap.snapped(time: .nan, candidates: [4], tolerance: 1)
        XCTAssertTrue(nan.time.isNaN)
        XCTAssertNil(nan.snappedTo)
    }

    // MARK: - 吸着 → クランプの合成（順序の固定）

    /// **正しい順序（吸着 → クランプ）は最小合成尺を割らない。**
    /// **逆順（クランプ → 吸着）は割る**（＝この順序でなければならない理由）。
    func test_snapThenClamp_keepsMinimumDuration() {
        let minimum = TimelineEditOperations.minimumClipDuration   // 0.1
        let target = clip(start: 0, end: 5)                        // 帯 0...5
        let candidates: [Double] = [0.06]                          // 例: プレイヘッド
        let tolerance = 0.05
        // 末尾ハンドルを 5 秒 → 0.08 秒へドラッグ（最小尺の内側まで来ている）。
        let draggedTime = 0.08

        // 正しい順序: 先に吸着 → その差分でクランプ。
        let snapped = TimelineSnap.snapped(time: draggedTime, candidates: candidates, tolerance: tolerance)
        XCTAssertEqual(snapped.snappedTo, 0.06)
        let correct = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                       deltaCompositionSeconds: snapped.time - target.sourceEnd,
                                                       sourceDuration: 30)
        XCTAssertGreaterThanOrEqual((correct.sourceEnd - correct.sourceStart) / target.rate, minimum)
        XCTAssertEqual(correct.sourceEnd, minimum, accuracy: 1e-12)

        // 逆順: 先にクランプ（0.1 で止まる）→ そこから吸着すると 0.06 へ引き戻される。
        let clampedFirst = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                            deltaCompositionSeconds: draggedTime - target.sourceEnd,
                                                            sourceDuration: 30)
        XCTAssertEqual(clampedFirst.sourceEnd, minimum, accuracy: 1e-12)
        let thenSnapped = TimelineSnap.snapped(time: clampedFirst.sourceEnd,
                                               candidates: candidates, tolerance: tolerance)
        XCTAssertEqual(thenSnapped.snappedTo, 0.06)
        XCTAssertLessThan((thenSnapped.time - clampedFirst.sourceStart) / target.rate, minimum)
    }

    /// rate ≠ 1 でも同じ（合成秒で吸着 → `trimmedBounds` が素材秒へ写してクランプ）。
    func test_snapThenClamp_withRate() {
        let minimum = TimelineEditOperations.minimumClipDuration
        let target = clip(start: 0, end: 10, rate: 2)   // 合成尺 5
        let candidates: [Double] = [0.03]
        let snapped = TimelineSnap.snapped(time: 0.05, candidates: candidates, tolerance: 0.05)
        XCTAssertEqual(snapped.snappedTo, 0.03)
        let bounds = TimelineBandLayout.trimmedBounds(clip: target, edge: .end,
                                                      deltaCompositionSeconds: snapped.time - target.duration,
                                                      sourceDuration: 30)
        // 素材側の下限は minimum * rate = 0.2。
        XCTAssertEqual(bounds.sourceEnd, minimum * target.rate, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual((bounds.sourceEnd - bounds.sourceStart) / target.rate, minimum)
    }

    /// 先頭側の端でも同じ（クランプの上限で止まり、最小尺を割らない）。
    func test_snapThenClamp_startEdge() {
        let minimum = TimelineEditOperations.minimumClipDuration
        let target = clip(start: 0, end: 5)
        // 4.97 秒へ吸着（残り 0.03 秒 = 最小尺未満）。
        let snapped = TimelineSnap.snapped(time: 4.97, candidates: [4.97], tolerance: 0.05)
        let bounds = TimelineBandLayout.trimmedBounds(clip: target, edge: .start,
                                                      deltaCompositionSeconds: snapped.time,
                                                      sourceDuration: 30)
        XCTAssertEqual(bounds.sourceStart, 5 - minimum, accuracy: 1e-12)
        // 5 - 0.1 は丸め誤差で最小尺を 1e-16 下回る（クランプ式そのものの性質）。
        // 「最小尺を割らない」の判定は誤差込みで見る。
        XCTAssertGreaterThanOrEqual((bounds.sourceEnd - bounds.sourceStart) / target.rate, minimum - 1e-12)
    }
}
