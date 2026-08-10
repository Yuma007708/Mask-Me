import XCTest
@testable import MosaicCore

/// 声区間（`ClipDuckRange` / `ClipDuckGate`）の追従ロジック。
///
/// `ClipAudioMuteRange` と同じ「素材時刻アンカー ＋ clipID」で持つため、クリップの分割・
/// 削除・トリムに自動追従することを固定する（新しい追従機構を作っていないことの回帰テスト）。
final class ClipDuckRangeTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    // MARK: - 分割

    /// 分割境界をまたぐ声区間は前後 2 本に割れる。
    func test_splittingClip_atMiddleOfRange_splitsIntoTwo() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 2, sourceEnd: 8)]

        let split = state.splitting(at: 5)
        XCTAssertEqual(split.clips.count, 2)
        XCTAssertEqual(split.clipDuckRanges.count, 2, "境界をまたぐ声区間は前後クリップへ割れる")
        let front = split.clips[0]
        let back = split.clips[1]
        XCTAssertTrue(split.clipDuckRanges.contains {
            $0.clipID == front.id && abs($0.sourceStart - 2) < 1e-9 && abs($0.sourceEnd - 5) < 1e-9
        }, "前半クリップに [2,5) が残る")
        XCTAssertTrue(split.clipDuckRanges.contains {
            $0.clipID == back.id && abs($0.sourceStart - 5) < 1e-9 && abs($0.sourceEnd - 8) < 1e-9
        }, "後半クリップに [5,8) が付け替わる")
        XCTAssertTrue(split.validate())
    }

    // MARK: - 複製

    /// **複製先へ声区間を引き継ぐこと。**
    ///
    /// 声区間は適用区間・消音区間と同じ `clipID` 単位のデータなので、複製時に
    /// 引き継がないと**複製先だけ BGM が下がらない**（元クリップと見た目も音も同じはずが、
    /// 片方だけ挙動が違う）。`orientation` が複製で引き継がれずマージで欠落した前科、
    /// `clipAudioMuteRange` を足したときに同じ場所へ追記した経緯と同型。
    ///
    /// **fuzz テストはこの経路を覆っていない**（操作一覧に複製が無い）ので、
    /// ここが唯一の番人になる。
    func test_duplicatingClip_copiesDuckRangesToTheCopy() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [ClipDuckRange(clipID: clip.id, sourceID: sourceA,
                                              sourceStart: 2, sourceEnd: 8)]

        let duplicated = state.duplicating(clipID: clip.id)
        XCTAssertEqual(duplicated.clips.count, 2, "テスト前提: 複製できていること")
        let copy = duplicated.clips[1]
        XCTAssertNotEqual(copy.id, clip.id, "テスト前提: 複製先は別の id を持つ")

        XCTAssertTrue(duplicated.clipDuckRanges.contains { $0.clipID == clip.id },
                      "元クリップの声区間が失われた")
        XCTAssertTrue(duplicated.clipDuckRanges.contains {
            $0.clipID == copy.id && $0.sourceID == sourceA
                && abs($0.sourceStart - 2) < 1e-9 && abs($0.sourceEnd - 8) < 1e-9
        }, "複製先に声区間が引き継がれていない（複製先だけ BGM が下がらなくなる）")
        XCTAssertTrue(duplicated.validate(), "複製後の状態が不変条件を満たさない")
    }

    /// 分割境界が声区間の外なら、区間はそのまま片方へ帰属する（割れない）。
    func test_splittingClip_outsideRange_keepsRangeWhole() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 3)]

        let split = state.splitting(at: 6)
        XCTAssertEqual(split.clipDuckRanges.count, 1)
        XCTAssertEqual(split.clipDuckRanges[0].clipID, split.clips[0].id, "前半クリップへ丸ごと残る")
        XCTAssertTrue(split.validate())
    }

    /// 写真クリップの分割は割らず、前後へ `[0, sourceEnd)` を複製する。
    func test_splittingPhotoClip_duplicatesFullCoverRangeToBothSides() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [photo], sources: [sourceA: TimelineSource(id: sourceA, kind: .photo)])
        state.clipDuckRanges = [ClipDuckRange(clipID: photo.id, sourceID: sourceA, sourceStart: 0, sourceEnd: 10)]

        let split = state.splitting(at: 4)
        XCTAssertEqual(split.clipDuckRanges.count, 2)
        for range in split.clipDuckRanges {
            XCTAssertEqual(range.sourceStart, 0, accuracy: 1e-9)
        }
        XCTAssertTrue(split.validate())
    }

    // MARK: - 削除

    /// クリップ削除でそのクリップの声区間も消える（孤児が残らない）。
    func test_removingClip_removesItsDuckRanges() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clipA, clipB])
        state.clipDuckRanges = [
            ClipDuckRange(clipID: clipA.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 2),
            ClipDuckRange(clipID: clipB.id, sourceID: sourceB, sourceStart: 1, sourceEnd: 2)
        ]

        let removed = state.removing(clipID: clipA.id)
        XCTAssertEqual(removed.clipDuckRanges.count, 1)
        XCTAssertEqual(removed.clipDuckRanges[0].clipID, clipB.id)
        XCTAssertTrue(removed.validate())
    }

    // MARK: - トリム

    /// 動画クリップのトリムは声区間に触らない（素材時刻アンカーが自動追従する）。
    func test_trimming_videoClip_preservesDuckRangeAnchor() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 8, sourceEnd: 9)]

        let trimmed = state.trimming(clipID: clip.id, sourceStart: 0, sourceEnd: 5)
        XCTAssertEqual(trimmed.clipDuckRanges, state.clipDuckRanges,
                       "区間は書き換わらない（トリムを戻せば復活する）")
    }

    /// 写真クリップのトリムは `sourceEnd` を引き直す。
    func test_trimming_photoClip_rewritesDuckRangeSourceEnd() {
        let photo = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 15)
        var state = TimelineState(clips: [photo], sources: [sourceA: TimelineSource(id: sourceA, kind: .photo)])
        state.clipDuckRanges = [ClipDuckRange(clipID: photo.id, sourceID: sourceA, sourceStart: 0, sourceEnd: 15)]

        let trimmed = state.trimming(clipID: photo.id, sourceStart: 0, sourceEnd: 4)
        XCTAssertEqual(trimmed.clipDuckRanges.count, 1)
        XCTAssertEqual(trimmed.clipDuckRanges[0].sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(trimmed.clipDuckRanges[0].sourceEnd, 4, accuracy: 1e-9)
        XCTAssertTrue(trimmed.validate())
    }

    // MARK: - 不変条件

    func test_validate_rejectsOverlappingDuckRangesInSameClip() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [
            ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 4),
            ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 3, sourceEnd: 6)
        ]
        XCTAssertFalse(state.validate(), "同じクリップ内で重なる声区間は不変条件違反")
    }

    func test_validate_rejectsNonFiniteOrInvertedDuckRange() {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        var invertedState = TimelineState(clips: [clip])
        invertedState.clipDuckRanges = [
            ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 5, sourceEnd: 1)
        ]
        XCTAssertFalse(invertedState.validate(), "逆転区間は不変条件違反")

        var nonFiniteState = TimelineState(clips: [clip])
        nonFiniteState.clipDuckRanges = [
            ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: .nan, sourceEnd: 5)
        ]
        XCTAssertFalse(nonFiniteState.validate(), "非有限の端は不変条件違反")
    }

    // MARK: - Codable（後方互換）

    /// キーの無い旧下書き（v6 以前）は声区間が空配列で復元される。
    func test_codable_missingKeyDecodesToEmptyArray() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [clip])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNotNil(json?.removeValue(forKey: "clipDuckRanges"), "前提: 通常は書き出される")
        let data = try JSONSerialization.data(withJSONObject: json as Any)

        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertTrue(decoded.clipDuckRanges.isEmpty, "キーが無ければ声区間なしで復元される")
        XCTAssertTrue(decoded.validate())
    }

    /// 往復で声区間が保たれる。
    func test_codable_roundTripPreservesDuckRanges() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clip])
        state.clipDuckRanges = [ClipDuckRange(clipID: clip.id, sourceID: sourceA, sourceStart: 1, sourceEnd: 2)]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.clipDuckRanges, state.clipDuckRanges)
    }

    /// スキーマ版が 7 で書き出される。
    func test_currentSchemaVersion_is7() throws {
        let state = TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 7)
    }
}
