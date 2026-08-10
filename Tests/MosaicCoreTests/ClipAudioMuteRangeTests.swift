import XCTest
@testable import MosaicCore

/// クリップ内消音区間（`ClipAudioMuteRange` / `ClipAudioMuteGate`）のコアロジック。
///
/// `MosaicApplyRange` と同じ「素材時刻アンカー ＋ clipID」で持つため、クリップの分割・
/// 削除・並べ替え・トリムに自動追従することを固定する（新しい追従機構を作っていないことの
/// 回帰テスト）。**意味は逆**（空 = 消音なし）であることも固定する。
final class ClipAudioMuteRangeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    // MARK: - 判定の純関数

    /// 区間内は消音・区間外は元音量になる。
    func test_isMuted_insideRangeTrue_outsideFalse() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let ranges = [ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 2, sourceEnd: 4)]

        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clip.id, sourceID: sourceA,
                                                 sourceTime: 1), "区間の前は消音しない")
        XCTAssertTrue(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clip.id, sourceID: sourceA,
                                                sourceTime: 2), "半開区間なので開始ちょうどは消音")
        XCTAssertTrue(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clip.id, sourceID: sourceA,
                                                sourceTime: 3.9), "区間の中は消音")
        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clip.id, sourceID: sourceA,
                                                 sourceTime: 4), "終了ちょうどは区間外（半開区間）")
        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clip.id, sourceID: sourceA,
                                                 sourceTime: 8), "区間の後は消音しない")
    }

    /// 空 = 消音なし（`MosaicApplyRange` の「空 = 全区間 OFF」と意味が逆）。
    /// `clipID` が写像不能・時刻が非有限のときも false に倒す（音声はフェイルオープンさせない）。
    func test_isMuted_failsClosedNotOpen() {
        let clipID = UUID()
        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: [], clipID: clipID, sourceID: sourceA, sourceTime: 1),
                       "区間 0 本は消音なし")
        let ranges = [ClipAudioMuteRange(clipID: clipID, sourceID: sourceA, sourceStart: 0, sourceEnd: 2)]
        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: nil, sourceID: sourceA, sourceTime: 1),
                       "clipID が写像不能でも消音しない（モザイクとは逆のフェイル方向）")
        XCTAssertFalse(ClipAudioMuteGate.isMuted(ranges: ranges, clipID: clipID, sourceID: sourceA,
                                                 sourceTime: .nan),
                       "非有限時刻でも消音しない")
    }

    /// `effectiveVolume` は消音区間内で 0、区間外で `originalAudioVolume` を返す。
    func test_effectiveVolume_usesOriginalVolumeOutsideMuteRange() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10, originalAudioVolume: 0.6)
        let ranges = [ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 2, sourceEnd: 4)]

        XCTAssertEqual(ClipAudioMuteGate.effectiveVolume(ranges: ranges, clip: clip, sourceTime: 3), 0,
                       "消音区間内は 0")
        XCTAssertEqual(ClipAudioMuteGate.effectiveVolume(ranges: ranges, clip: clip, sourceTime: 5), 0.6,
                       "消音区間外は originalAudioVolume")
    }

    // MARK: - 編集 API（追加・削除・移動・端トリム・全消し）

    func test_addingClipAudioMuteRange_decomposesToSourceAnchors() {
        let state = TimelineState(clips: [
            TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4),
            TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        ])
        let added = state.addingClipAudioMuteRange(fromCompositionTime: 3, to: 5)

        XCTAssertEqual(added.clipAudioMuteRanges.count, 2, "クリップ境界を跨ぐのでクリップごとに分解される")
        XCTAssertEqual(added.clipAudioMuteRanges[0].clipID, state.clips[0].id)
        XCTAssertEqual(added.clipAudioMuteRanges[0].sourceStart, 3, accuracy: 1e-9)
        XCTAssertEqual(added.clipAudioMuteRanges[0].sourceEnd, 4, accuracy: 1e-9)
        XCTAssertEqual(added.clipAudioMuteRanges[1].clipID, state.clips[1].id)
        XCTAssertEqual(added.clipAudioMuteRanges[1].sourceStart, 10, accuracy: 1e-9)
        XCTAssertEqual(added.clipAudioMuteRanges[1].sourceEnd, 11, accuracy: 1e-9)
        XCTAssertTrue(added.validate())
        XCTAssertEqual(state.addingClipAudioMuteRange(fromCompositionTime: 5, to: 5), state, "空区間は self")
    }

    func test_removingClipAudioMuteRange() {
        let state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)])
            .addingClipAudioMuteRange(fromCompositionTime: 1, to: 2)
        let id = state.clipAudioMuteRanges[0].id

        XCTAssertTrue(state.removingClipAudioMuteRange(id: id).clipAudioMuteRanges.isEmpty)
        XCTAssertEqual(state.removingClipAudioMuteRange(id: UUID()), state, "不在 id は self")
    }

    func test_replacingClipAudioMuteRange_canShrink() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [clip]).addingClipAudioMuteRange(fromCompositionTime: 1, to: 3)
        let id = state.clipAudioMuteRanges[0].id

        let shrunk = state.replacingClipAudioMuteRange(
            id: id, clipID: clip.id, compositionInterval: CompositionInterval(start: 1.5, end: 2))
        XCTAssertEqual(shrunk.clipAudioMuteRanges.count, 1)
        XCTAssertEqual(shrunk.clipAudioMuteRanges[0].sourceStart, 1.5, accuracy: 1e-9)
        XCTAssertEqual(shrunk.clipAudioMuteRanges[0].sourceEnd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(shrunk.clipAudioMuteRanges[0].id, id, "マージで id が飛んではいけない")
        XCTAssertTrue(shrunk.validate())
    }

    func test_movingClipAudioMuteRange_clampsAtClipBoundary() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip]).addingClipAudioMuteRange(fromCompositionTime: 1, to: 3)
        let id = state.clipAudioMuteRanges[0].id

        let moved = state.movingClipAudioMuteRange(id: id, clipID: clip.id, byCompositionDelta: -5)
        XCTAssertEqual(moved.clipAudioMuteRanges[0].sourceStart, 0, accuracy: 1e-9,
                       "クリップ先頭でクランプされ、はみ出さない")
        XCTAssertEqual(moved.clipAudioMuteRanges[0].sourceEnd, 2, accuracy: 1e-9, "長さは保たれる")
        XCTAssertTrue(moved.validate())
    }

    func test_clearingClipAudioMuteRanges_removesEverything() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip])
            .addingClipAudioMuteRange(fromCompositionTime: 1, to: 3)
            .addingClipAudioMuteRange(fromCompositionTime: 5, to: 6)

        let cleared = state.clearingClipAudioMuteRanges()
        XCTAssertTrue(cleared.clipAudioMuteRanges.isEmpty)
        XCTAssertEqual(state.clearingClipAudioMuteRanges().clearingClipAudioMuteRanges(),
                       cleared, "既に空なら self（冪等）")
        XCTAssertEqual(TimelineState(clips: [clip]).clearingClipAudioMuteRanges(),
                       TimelineState(clips: [clip]), "元々空なら self")
    }

    // MARK: - クリップ編集への追従（分割・削除・並べ替え・トリム）

    /// 分割で消音区間が正しく前後へ付け替わる（境界をまたぐ区間は 2 本に割れる）。
    func test_splitting_reassignsMuteRangeAcrossBoundary() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip]).addingClipAudioMuteRange(fromCompositionTime: 2, to: 8)

        let split = state.splitting(at: 5)
        XCTAssertEqual(split.clips.count, 2)
        let front = split.clips[0]
        let back = split.clips[1]
        let frontRanges = split.clipAudioMuteRanges.filter { $0.clipID == front.id }
        let backRanges = split.clipAudioMuteRanges.filter { $0.clipID == back.id }
        XCTAssertEqual(frontRanges.count, 1)
        XCTAssertEqual(frontRanges[0].sourceStart, 2, accuracy: 1e-9)
        XCTAssertEqual(frontRanges[0].sourceEnd, 5, accuracy: 1e-9)
        XCTAssertEqual(backRanges.count, 1)
        XCTAssertEqual(backRanges[0].sourceStart, 5, accuracy: 1e-9)
        XCTAssertEqual(backRanges[0].sourceEnd, 8, accuracy: 1e-9)
        XCTAssertTrue(split.validate())
    }

    /// 完全に前半（または後半）に収まる区間は割れずそのまま付け替わる。
    func test_splitting_keepsRangeIntactWhenEntirelyOnOneSide() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip]).addingClipAudioMuteRange(fromCompositionTime: 6, to: 8)

        let split = state.splitting(at: 5)
        let back = split.clips[1]
        XCTAssertEqual(split.clipAudioMuteRanges.count, 1)
        XCTAssertEqual(split.clipAudioMuteRanges[0].clipID, back.id)
        XCTAssertTrue(split.validate())
    }

    /// 写真クリップの分割は区間を割らず、前後どちらにも `[0, sourceEnd)` を複製する。
    func test_splitting_photoClip_duplicatesWholeRangeToBothSides() throws {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 6)
        var state = TimelineState(clips: [photo], sources: [sourceA: TimelineSource(id: sourceA, kind: .photo)])
        state = state.addingClipAudioMuteRange(fromCompositionTime: 0, to: 6)

        let split = state.splitting(at: 3)
        XCTAssertEqual(split.clips.count, 2)
        let front = split.clips[0]
        let back = split.clips[1]
        XCTAssertEqual(split.clipAudioMuteRanges.count, 2, "前後どちらにも 1 本ずつ")
        for range in split.clipAudioMuteRanges {
            XCTAssertEqual(range.sourceStart, 0, accuracy: 1e-9, "写真は 0 始まり固定")
        }
        let frontEnd = try XCTUnwrap(split.clipAudioMuteRanges.first { $0.clipID == front.id }?.sourceEnd)
        XCTAssertEqual(frontEnd, front.sourceEnd, accuracy: 1e-9)
        let backEnd = try XCTUnwrap(split.clipAudioMuteRanges.first { $0.clipID == back.id }?.sourceEnd)
        XCTAssertEqual(backEnd, back.sourceEnd, accuracy: 1e-9)
        XCTAssertTrue(split.validate())
    }

    /// クリップ削除でそのクリップの消音区間も消える（孤児が残らない）。
    func test_removingClip_removesItsMuteRanges() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clipA, clipB])
        state.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
            ClipAudioMuteRange(clipID: clipB.id, sourceID: sourceB, sourceStart: 1, sourceEnd: 2)
        ]

        let removed = state.removing(clipID: clipA.id)
        XCTAssertEqual(removed.clipAudioMuteRanges.count, 1)
        XCTAssertEqual(removed.clipAudioMuteRanges[0].clipID, clipB.id)
        XCTAssertTrue(removed.validate())
    }

    /// 並べ替えは消音区間に触らない（`clipID`・素材時刻とも変わらないので自動追従する）。
    func test_moving_leavesMuteRangesUntouched() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clipA, clipB])
        state.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 2)
        ]

        let moved = state.moving(clipID: clipB.id, toIndex: 0)
        XCTAssertEqual(moved.clipAudioMuteRanges, state.clipAudioMuteRanges)
        XCTAssertTrue(moved.validate())
    }

    /// 動画クリップのトリムは消音区間に触らない（素材時刻アンカーが自動追従する）。
    /// クリップ使用範囲外へ一時的に外れた消音区間も孤児として温存される。
    func test_trimming_videoClip_preservesMuteRangeAnchor() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 8, sourceEnd: 9)
        ]

        let trimmed = state.trimming(clipID: clip.id, sourceStart: 0, sourceEnd: 5)
        XCTAssertEqual(trimmed.clipAudioMuteRanges, state.clipAudioMuteRanges,
                       "区間は書き換わらない（トリムを戻せば復活する）")
    }

    /// 写真クリップのトリムは `sourceEnd` を引き直す（[0, sourceEnd) の不変条件を保つ）。
    func test_trimming_photoClip_rewritesMuteRangeSourceEnd() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 15)
        var state = TimelineState(clips: [photo], sources: [sourceA: TimelineSource(id: sourceA, kind: .photo)])
        state.clipAudioMuteRanges = [ClipAudioMuteRange(clipID: photo.id, sourceID: sourceA,
                                                        sourceStart: 0, sourceEnd: 15)]

        let trimmed = state.trimming(clipID: photo.id, sourceStart: 0, sourceEnd: 4)
        XCTAssertEqual(trimmed.clipAudioMuteRanges.count, 1)
        XCTAssertEqual(trimmed.clipAudioMuteRanges[0].sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(trimmed.clipAudioMuteRanges[0].sourceEnd, 4, accuracy: 1e-9)
        XCTAssertTrue(trimmed.validate())
    }

    /// 複製先へも消音区間が複製される（`clipID` スコープなので流用すると効かないため）。
    func test_duplicating_copiesMuteRangeToNewClip() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clip])
        state.clipAudioMuteRanges = [ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA,
                                                        sourceStart: 1, sourceEnd: 2)]

        let duplicated = state.duplicating(clipID: clip.id)
        XCTAssertEqual(duplicated.clips.count, 2)
        let copyID = duplicated.clips[1].id
        XCTAssertEqual(duplicated.clipAudioMuteRanges.count, 2)
        XCTAssertTrue(duplicated.clipAudioMuteRanges.contains { $0.clipID == copyID })
        XCTAssertTrue(duplicated.validate())
    }

    // MARK: - 正規化・不変条件

    /// 同じクリップ内で重なる区間を作れない（追加で自動マージされる）。
    func test_addingOverlappingRange_mergesInsteadOfOverlapping() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip])
            .addingClipAudioMuteRange(fromCompositionTime: 1, to: 4)
            .addingClipAudioMuteRange(fromCompositionTime: 3, to: 6)

        XCTAssertEqual(state.clipAudioMuteRanges.count, 1, "重なりはマージされる")
        XCTAssertEqual(state.clipAudioMuteRanges[0].sourceStart, 1, accuracy: 1e-9)
        XCTAssertEqual(state.clipAudioMuteRanges[0].sourceEnd, 6, accuracy: 1e-9)
        XCTAssertTrue(state.validate())
    }

    /// 手で重ねて作った状態は `validate()` が false を返す（正規化されていない不整合を検知する）。
    func test_validate_rejectsOverlappingMuteRangesInSameClip() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 4),
            ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 3, sourceEnd: 6)
        ]
        XCTAssertFalse(state.validate(), "同じクリップ内で重なる区間は不変条件違反")
    }

    /// 非有限・逆転した区間は作られない（追加系 API は静かに no-op になる）。
    func test_nonFiniteOrInvertedRangesAreNeverCreated() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip])

        XCTAssertEqual(state.addingClipAudioMuteRange(fromCompositionTime: .nan, to: 5), state)
        XCTAssertEqual(state.addingClipAudioMuteRange(fromCompositionTime: 5, to: 1), state, "逆転は self")
        XCTAssertEqual(state.addingClipAudioMuteRange(fromCompositionTime: .infinity, to: .infinity), state)
    }

    /// `validate()` は非有限・逆転した消音区間を手作業で入れても弾く。
    func test_validate_rejectsNonFiniteOrInvertedMuteRange() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var invertedState = TimelineState(clips: [clip])
        invertedState.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: 5, sourceEnd: 1)
        ]
        XCTAssertFalse(invertedState.validate(), "逆転区間は不変条件違反")

        var nonFiniteState = TimelineState(clips: [clip])
        nonFiniteState.clipAudioMuteRanges = [
            ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA, sourceStart: .nan, sourceEnd: 5)
        ]
        XCTAssertFalse(nonFiniteState.validate(), "非有限の端は不変条件違反")
    }

    // MARK: - Codable（後方互換）

    /// キーの無い旧下書き（v5 以前）は消音区間が空配列で復元される。
    func test_codable_missingKeyDecodesToEmptyArray() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [clip])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNotNil(json?.removeValue(forKey: "clipAudioMuteRanges"), "前提: 通常は書き出される")
        let data = try JSONSerialization.data(withJSONObject: json as Any)

        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertTrue(decoded.clipAudioMuteRanges.isEmpty, "キーが無ければ消音区間なしで復元される")
        XCTAssertTrue(decoded.validate())
    }

    /// 往復で消音区間が保たれる。
    func test_codable_roundTripPreservesMuteRanges() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clip])
        state.clipAudioMuteRanges = [ClipAudioMuteRange(clipID: clip.id, sourceID: sourceA,
                                                        sourceStart: 1, sourceEnd: 2)]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.clipAudioMuteRanges, state.clipAudioMuteRanges)
    }
}
