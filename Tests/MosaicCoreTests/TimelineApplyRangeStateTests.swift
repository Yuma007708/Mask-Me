import XCTest
@testable import MosaicCore

/// S9: モザイク適用区間の編集 API と、分割対象の明示（活性判定と対象の一致）。
///
/// `TimelineStateTests` から分けているのは `file_length` / `type_body_length` に
/// 収めるためで、対象は同じ `TimelineState.swift` / `MosaicApplyRange.swift`。
final class TimelineApplyRangeStateTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()
    // MARK: - モザイク適用区間の編集 API（S9）

    /// 合成時刻の区間が素材アンカーへ分解されて保存されること。
    func test_addingApplyRange_decomposesToSourceAnchors() {
        let state = TimelineState(clips: [
            TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4),
            TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        ])
        let added = state.addingApplyRange(fromCompositionTime: 3, to: 5)

        XCTAssertEqual(added.applyRanges.count, 2, "クリップ境界を跨ぐのでクリップごとに分解される")
        XCTAssertEqual(added.applyRanges[0].clipID, state.clips[0].id)
        XCTAssertEqual(added.applyRanges[0].sourceID, sourceA)
        XCTAssertEqual(added.applyRanges[0].sourceStart, 3, accuracy: 1e-9)
        XCTAssertEqual(added.applyRanges[0].sourceEnd, 4, accuracy: 1e-9)
        XCTAssertEqual(added.applyRanges[1].clipID, state.clips[1].id)
        XCTAssertEqual(added.applyRanges[1].sourceID, sourceB)
        XCTAssertEqual(added.applyRanges[1].sourceStart, 10, accuracy: 1e-9)
        XCTAssertEqual(added.applyRanges[1].sourceEnd, 11, accuracy: 1e-9)
        XCTAssertTrue(added.validate())
        XCTAssertEqual(state.addingApplyRange(fromCompositionTime: 5, to: 5), state, "空区間は self")
        XCTAssertEqual(state.addingApplyRange(fromCompositionTime: .nan, to: 1), state)
    }

    func test_removingApplyRange() {
        let state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)])
            .addingApplyRange(fromCompositionTime: 1, to: 2)
        let id = state.applyRanges[0].id

        XCTAssertTrue(state.removingApplyRange(id: id).applyRanges.isEmpty)
        XCTAssertEqual(state.removingApplyRange(id: UUID()), state, "不在 id は self")
    }

    /// 端ドラッグの確定（置き換え）は縮める操作も表現できること。
    func test_replacingApplyRange_canShrink() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [clip]).addingApplyRange(fromCompositionTime: 1, to: 3)
        let id = state.applyRanges[0].id

        let shrunk = state.replacingApplyRange(id: id, clipID: clip.id,
                                               compositionInterval: CompositionInterval(start: 1.5, end: 2))
        XCTAssertEqual(shrunk.applyRanges.count, 1)
        XCTAssertEqual(shrunk.applyRanges[0].sourceStart, 1.5, accuracy: 1e-9)
        XCTAssertEqual(shrunk.applyRanges[0].sourceEnd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(shrunk.applyRanges[0].id, id, "マージで id が飛んではいけない")
        XCTAssertTrue(shrunk.validate())

        let interval = CompositionInterval(start: 0, end: 1)
        XCTAssertEqual(state.replacingApplyRange(id: UUID(), clipID: clip.id, compositionInterval: interval),
                       state, "不在 id は self")
        XCTAssertEqual(state.replacingApplyRange(id: id, clipID: UUID(), compositionInterval: interval),
                       state, "不在 clipID は self")
        XCTAssertEqual(state.replacingApplyRange(id: id, clipID: clip.id,
                                                 compositionInterval: CompositionInterval(start: 2, end: 1)),
                       state, "逆順は self")
    }

    /// 掴んだセグメントの差し替えで、**クリップ使用範囲外の素材区間が消えない**こと。
    ///
    /// 旧実装（合成時刻の区間列から作り直す）は、合成時刻から復元できるのが
    /// 「今どれかのクリップが使っている素材範囲」だけなので、この区間を必ず落としていた。
    func test_replacingApplyRange_keepsSourceRangeOutsideClips() {
        // 同一素材の 2 クリップ A=[0,2) / B=[3,5)。素材 [2,3) はどのクリップも使っていない。
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let clipB = TimelineClip(sourceID: sourceA, sourceStart: 3, sourceEnd: 5)
        var state = TimelineState(clips: [clipA, clipB])
        state.applyRanges = [MosaicApplyRange(clipID: clipB.id, sourceID: sourceA,
                                              sourceStart: 1, sourceEnd: 4)]
        let id = state.applyRanges[0].id

        // B のセグメント（合成 [2,3) = 素材 [3,4)）を素材 [3.5,4) 相当へ縮める。
        let replaced = state.replacingApplyRange(
            id: id, clipID: clipB.id, compositionInterval: CompositionInterval(start: 2.5, end: 3))

        XCTAssertEqual(replaced.applyRanges.count, 2, "使用範囲外の素材区間が別区間として残る")
        let sorted = replaced.applyRanges.sorted { $0.sourceStart < $1.sourceStart }
        XCTAssertEqual(sorted[0].sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(sorted[0].sourceEnd, 3.0, accuracy: 1e-9,
                       "クリップ B の使用範囲外 [1,3) が繋がって残る")
        XCTAssertEqual(sorted[1].sourceStart, 3.5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].sourceEnd, 4.0, accuracy: 1e-9)
        // 温存された断片は clipID ごと残る（トリムを戻せば復活する）。
        XCTAssertTrue(sorted.allSatisfy { $0.clipID == clipB.id })
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: replaced.applyRanges, clipID: clipB.id,
                                               sourceID: sourceA, sourceTime: 2.5),
                      "クリップ使用範囲外の素材時刻の適用が消えている")
        XCTAssertTrue(replaced.validate())
    }

    /// 隙間なしケース（旧テストの対象）でも、掴んだセグメントだけを渡せば
    /// 他セグメントぶんの適用が残ること。
    func test_replacingApplyRange_keepsOtherSegments() {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 3, sourceEnd: 10)
        let state = TimelineState(clips: [front, back])
            .addingApplyRange(fromCompositionTime: 2, to: 4)
        XCTAssertEqual(state.applyRanges.count, 2, "S11: clipID が違うのでマージされない")
        let id = state.applyRanges[0].id

        // 前半セグメント [2,3) を [2.5,3) に縮める（後半セグメントは渡さない）。
        let replaced = state.replacingApplyRange(
            id: id, clipID: front.id, compositionInterval: CompositionInterval(start: 2.5, end: 3))
        XCTAssertEqual(replaced.applyRanges.count, 2)
        XCTAssertEqual(replaced.applyRanges[0].sourceStart, 2.5, accuracy: 1e-9)
        XCTAssertEqual(replaced.applyRanges[0].sourceEnd, 3.0, accuracy: 1e-9)
        XCTAssertEqual(replaced.applyRanges[1].clipID, back.id)
        XCTAssertEqual(replaced.applyRanges[1].sourceEnd, 4.0, accuracy: 1e-9,
                       "後半セグメントぶんの適用が残る")
    }

    /// ハンドルを掴んで動かさずに離した（ドラッグ量 0）ときは self を返し、
    /// **区間の並びも変わらない**こと（id 再発行だけで undo 履歴が汚れる問題）。
    func test_replacingApplyRange_zeroDragIsNoOp() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clipA, clipB])
        state.applyRanges = [
            MosaicApplyRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
            MosaicApplyRange(clipID: clipB.id, sourceID: sourceB, sourceStart: 1, sourceEnd: 2)
        ]
        let orderBefore = state.applyRanges.map(\.clipID)
        let id = state.applyRanges[0].id

        let same = state.replacingApplyRange(
            id: id, clipID: clipA.id, compositionInterval: CompositionInterval(start: 1, end: 2))
        XCTAssertEqual(same, state, "動かしていないのに状態が変わっている（undo 履歴が汚れる）")
        XCTAssertEqual(same.applyRanges.map(\.clipID), orderBefore, "並び順まで変わっている")
    }

    /// 写真素材の適用区間はクリップ全体（素材 [0, sourceEnd)）を覆うこと。
    ///
    /// 写真クリップの素材時刻は常に 0 に clamp されるため、合成時刻由来のアンカー
    /// （例 [1,2)）を保存すると `isActive` が絶対にヒットしない。
    func test_applyRange_forPhotoSource_coversWholeClip() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        var state = TimelineState(clips: [photo])
        state.sources = [sourceA: TimelineSource(id: sourceA, kind: .photo)]

        let added = state.addingApplyRange(fromCompositionTime: 1, to: 2)
        XCTAssertEqual(added.applyRanges.count, 1)
        XCTAssertEqual(added.applyRanges[0].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(added.applyRanges[0].sourceEnd, 3, accuracy: 1e-12)
        let clamped = added.clampedSourceTime(1.5, sourceID: sourceA)
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: added.applyRanges, clipID: photo.id,
                                               sourceID: sourceA, sourceTime: clamped),
                      "写真素材で適用区間がヒットしない")
        // 端ドラッグは構造的に no-op なので UI はハンドルを出さない（`isEdgeAdjustable`）。
        let spans = TimelineBandLayout.applySpans(ranges: added.applyRanges, mapping: added.mapping,
                                                  photoSourceIDs: added.photoSourceIDs)
        XCTAssertEqual(spans.count, 1)
        XCTAssertFalse(spans[0].isEdgeAdjustable)

        // 端ドラッグでもクリップ全体のまま（= 変化しないので self）。
        XCTAssertEqual(added.replacingApplyRange(id: added.applyRanges[0].id, clipID: photo.id,
                                                 compositionInterval: CompositionInterval(start: 1.5, end: 2)),
                       added, "写真素材では区間の端ドラッグが状態を変えない")

        // 動画素材では従来どおり合成時刻由来のアンカーになる（対比）。
        let video = TimelineState(clips: [photo]).addingApplyRange(fromCompositionTime: 1, to: 2)
        XCTAssertEqual(video.applyRanges[0].sourceStart, 1, accuracy: 1e-12)
    }

    // MARK: - S9: 分割対象の明示（活性判定と対象の一致）

    /// トランジションの重なり区間では、`splitting(clipID:atDisplayTime:)` が
    /// **選択したクリップ**を割ること（帰属規則は incoming 側なので食い違う）。
    func test_splittingByClipID_splitsSelectedClipInsideOverlap() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        let state = TimelineState(clips: [clipA, clipB],
                                  transitions: [clipA.id: TransitionSpec(kind: .crossfade, duration: 2.0)])
        // 重なりは表示時刻 [4, 6)。5.0 は重なりの中。
        XCTAssertNotNil(state.mapping.overlap(at: 5.0))

        let byClip = state.splitting(clipID: clipA.id, atDisplayTime: 5.0)
        XCTAssertEqual(byClip.clips.filter { $0.sourceID == sourceA }.count, 2, "選択した A が割れていない")
        XCTAssertEqual(byClip.clips.filter { $0.sourceID == sourceB }.count, 1, "選択していない B が割れた")

        // 帰属規則に任せる旧経路は B を割る（この差分が M-C1 の実害）。
        let byRule = state.splitting(atDisplayTime: 5.0)
        XCTAssertEqual(byRule.clips.filter { $0.sourceID == sourceB }.count, 2)
    }

    /// `canSplit` が「実際に分割されるかどうか」と完全に一致すること
    /// （活性判定と対象が別規則だと、押せるのに何も起きない・別クリップが割れる）。
    func test_canSplit_agreesWithSplitting() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 6)
        let state = TimelineState(clips: [clipA, clipB],
                                  transitions: [clipA.id: TransitionSpec(kind: .crossfade, duration: 2.0)])
        for clip in [clipA, clipB] {
            for step in 0...120 {
                let time = Double(step) * 0.1
                let expected = state.canSplit(clipID: clip.id, atDisplayTime: time)
                let actual = state.splitting(clipID: clip.id, atDisplayTime: time) != state
                XCTAssertEqual(expected, actual,
                               "canSplit と splitting が食い違う（clip=\(clip.sourceID) t=\(time)）")
            }
        }
        XCTAssertFalse(state.canSplit(clipID: UUID(), atDisplayTime: 1),
                       "不在クリップは分割できない")
        XCTAssertFalse(state.canSplit(clipID: clipA.id, atDisplayTime: .nan))
    }
}
