import XCTest
@testable import MosaicCore

/// 写真クリップの適用区間が「素材 [0, sourceEnd) を覆う」不変条件を、
/// **区間を作る・付け替える全経路**で守っているかの回帰テスト。
///
/// 写真の素材時刻は `TimelineState.clampedSourceTime` が常に 0 へ丸めるため、
/// `sourceStart > 0` の区間はゲートに**絶対にヒットしない**。それでも帯
/// （`TimelineBandLayout.applySpans`）はクリップとの交差だけで出るので、
/// 「帯は出ているのにモザイクが消える」（不変条件 I1 違反）という無言の事故になる。
///
/// 既存の写真テスト（`TimelineApplyRangeStateTests`）は追加経路
/// （`addingApplyRange`）しか見ておらず、分割・移行・トリムの写真扱いを 1 件も
/// 押さえていなかった。ここで 3 経路をゲートの ON/OFF 実測で固定する。
final class PhotoApplyRangeGateTests: XCTestCase {
    private let photoID = UUID()

    private func photoState(sourceEnd: Double = 3) -> TimelineState {
        let clip = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: sourceEnd)
        return TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [photoID]),
            sources: [photoID: TimelineSource(id: photoID, kind: .photo)])
    }

    /// 合成時刻を等間隔にサンプリングしたゲートの ON/OFF 集計。
    private struct GateSamples {
        var on = 0
        var off = 0
        var firstOff: Double?
    }

    /// `ranges` は必ず `effectiveRanges` を通す（帯とゲートを同じ材料で測るため）。
    private func gateSamples(_ state: TimelineState, samples: Int = 60) -> GateSamples {
        let mapping = state.mapping
        let effective = MosaicApplyGate.effectiveRanges(state.applyRanges, mapping: mapping)
        var result = GateSamples()
        for index in 0..<samples {
            let t = mapping.totalDuration * Double(index) / Double(samples)
            if MosaicApplyGate.isActive(ranges: effective, mapping: mapping,
                                        compositionTime: t, photoSourceIDs: state.photoSourceIDs) {
                result.on += 1
            } else {
                result.off += 1
                if result.firstOff == nil { result.firstOff = t }
            }
        }
        return result
    }

    private func bandCount(_ state: TimelineState) -> Int {
        TimelineBandLayout.applySpans(ranges: state.applyRanges, mapping: state.mapping,
                                      photoSourceIDs: state.photoSourceIDs).count
    }

    // MARK: - 経路 1: 分割（`MosaicApplyGate.ranges(splittingClip:into:...)`）

    /// 写真クリップを分割しても全区間 ON のままであること（再現 A の回帰）。
    ///
    /// 修正前は後半クリップの区間が `[1.5, 3.0)` になり、素材時刻 0 へ丸めるゲートに
    /// 永久にヒットしなかった（帯 2 本・有効区間 2 個のまま合成 1.5 秒以降が全 OFF）。
    func test_splittingPhotoClip_keepsGateOnForWholeTimeline() {
        let state = photoState()
        let before = gateSamples(state)
        XCTAssertEqual(before.on, 60, "前提: 分割前は全 ON")

        let split = state.splitting(clipID: state.clips[0].id, atDisplayTime: 1.5)
        XCTAssertEqual(split.clips.count, 2, "前提: 分割できていない")
        XCTAssertTrue(split.validate(), "写真クリップの区間が sourceStart == 0 を破っている")

        // 区間は前後どちらも [0, clip.sourceEnd)。**分割されない**。
        XCTAssertEqual(split.applyRanges.count, 2)
        XCTAssertEqual(split.applyRanges[0].clipID, split.clips[0].id)
        XCTAssertEqual(split.applyRanges[0].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(split.applyRanges[0].sourceEnd, split.clips[0].sourceEnd, accuracy: 1e-12)
        XCTAssertEqual(split.applyRanges[1].clipID, split.clips[1].id)
        XCTAssertEqual(split.applyRanges[1].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(split.applyRanges[1].sourceEnd, split.clips[1].sourceEnd, accuracy: 1e-12)
        // 元 id は前半が継承する（UI の選択が飛ばない）。
        XCTAssertEqual(split.applyRanges[0].id, state.applyRanges[0].id)

        let after = gateSamples(split)
        print("[PHOTO-split] 帯=\(bandCount(split)) 有効=\(MosaicApplyGate.effectiveRanges(split.applyRanges, mapping: split.mapping).count) "
              + "ON=\(after.on) OFF=\(after.off) 最初のOFF=\(String(describing: after.firstOff))")
        XCTAssertEqual(after.off, 0, "分割後にモザイクが消えている（I1 違反）")
        XCTAssertEqual(bandCount(split), 2)
    }

    /// 区間を全削除した写真クリップを分割しても区間は生えない（不変条件 I5）。
    func test_splittingPhotoClip_withoutRanges_staysEmpty() {
        var state = photoState()
        state.applyRanges = []
        let split = state.splitting(clipID: state.clips[0].id, atDisplayTime: 1.5)
        XCTAssertEqual(split.clips.count, 2)
        XCTAssertTrue(split.applyRanges.isEmpty, "削除済みの区間が分割で復活している")
    }

    // MARK: - 経路 2: v1 下書きの移行（`TimelineState.migratedApplyRanges`）

    /// v2 の状態から **v1 相当の JSON**（`schemaVersion` 無し・`applyRanges` は旧形式）を作る。
    ///
    /// JSON を手書きしないのは、`[UUID: TransitionSpec]` などの辞書が Swift の
    /// Codable では「キーと値を交互に並べた配列」になるためで、手書きすると
    /// 移行の検証ではなく JSON の形の検証になってしまう。
    private func legacyJSON(from state: TimelineState,
                            legacyRanges: [[String: Any]]) throws -> Data {
        let encoded = try JSONEncoder().encode(state)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw NSError(domain: "test", code: 0)
        }
        object.removeValue(forKey: "schemaVersion")   // = v1 と判定される
        object["applyRanges"] = legacyRanges
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// v1（`schemaVersion` 無し・`applyRanges: []`）の写真クリップが全区間 ON で復元されること
    /// （再現 B の回帰）。旧仕様の「区間 0 本 = 全区間 ON」という意味を保存する経路である。
    func test_migratingLegacyDraft_withPhotoClips_keepsGateOn() throws {
        // 写真 3 秒を 1.5 秒で分割した構成（= 再現 B と同じ形）。
        let source = TimelineSource(id: photoID, kind: .photo)
        let front = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 1.5)
        let back = TimelineClip(sourceID: photoID, sourceStart: 1.5, sourceEnd: 3)
        let original = TimelineState(clips: [front, back], sources: [photoID: source])
        let data = try legacyJSON(from: original, legacyRanges: [])

        let state = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertTrue(state.validate())
        XCTAssertEqual(state.applyRanges.count, 2)
        XCTAssertTrue(state.applyRanges.allSatisfy { $0.sourceStart == 0 })

        let samples = gateSamples(state)
        print("[PHOTO-migrate] 帯=\(bandCount(state)) ON=\(samples.on) OFF=\(samples.off) "
              + "最初のOFF=\(String(describing: samples.firstOff))")
        XCTAssertEqual(samples.off, 0, "移行でモザイクが減っている")
        XCTAssertEqual(bandCount(state), 2)
    }

    /// v1 の非空区間も写真クリップでは `[0, clip.sourceEnd)` へ丸めること（クリップあたり 1 本）。
    func test_migratingLegacyDraft_withPhotoRanges_roundsToWholeClip() throws {
        let clip = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)
        let original = TimelineState(clips: [clip],
                                     sources: [photoID: TimelineSource(id: photoID, kind: .photo)])
        let rangeID = UUID()
        let data = try legacyJSON(from: original, legacyRanges: [
            ["id": rangeID.uuidString, "sourceID": photoID.uuidString,
             "sourceStart": 1.0, "sourceEnd": 2.0]
        ])

        let state = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(state.applyRanges.count, 1)
        XCTAssertEqual(state.applyRanges[0].id, rangeID, "id 継承が壊れている")
        XCTAssertEqual(state.applyRanges[0].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(state.applyRanges[0].sourceEnd, 3, accuracy: 1e-12)
        XCTAssertEqual(gateSamples(state).off, 0)
    }

    // MARK: - 経路 3: トリム（`MosaicApplyGate.ranges(trimmingPhotoClip:existing:)`）

    /// 写真クリップの右端を伸ばしてから左端をトリムしても区間が孤児化しないこと
    /// （再現 C の回帰。capacity 15 秒化で到達可能になった）。
    func test_trimmingPhotoClip_keepsRangeCoveringTheClip() {
        var state = photoState()
        let clipID = state.clips[0].id

        // 右端を capacity いっぱい（15 秒）まで伸ばす。
        state = state.trimming(clipID: clipID, sourceStart: 0, sourceEnd: 15)
        XCTAssertEqual(state.applyRanges.count, 1)
        XCTAssertEqual(state.applyRanges[0].sourceEnd, 15, accuracy: 1e-12,
                       "伸ばした先まで区間が追従していない")
        XCTAssertEqual(gateSamples(state).off, 0)

        // 左端を 4 秒までトリム（`trimmedBounds` の上限 14.9 以内 = UI から到達可能）。
        state = state.trimming(clipID: clipID, sourceStart: 4, sourceEnd: 15)
        XCTAssertTrue(state.validate())
        XCTAssertEqual(state.applyRanges.count, 1)
        XCTAssertEqual(state.applyRanges[0].sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(state.applyRanges[0].sourceEnd, 15, accuracy: 1e-12)

        let samples = gateSamples(state)
        print("[PHOTO-trim] 生区間=\(state.applyRanges.count) "
              + "有効=\(MosaicApplyGate.effectiveRanges(state.applyRanges, mapping: state.mapping).count) "
              + "帯=\(bandCount(state)) ON=\(samples.on) OFF=\(samples.off)")
        XCTAssertEqual(samples.off, 0, "トリムで区間が孤児化してモザイクが消えている")
        XCTAssertEqual(bandCount(state), 1)
    }

    /// 動画クリップのトリムは従来どおり区間を書き換えない（孤児区間の温存）。
    func test_trimmingVideoClip_stillPreservesOrphanRanges() {
        let videoID = UUID()
        let clip = TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 6)
        var state = TimelineState(
            clips: [clip],
            applyRanges: MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: []),
            sources: [videoID: TimelineSource(id: videoID, kind: .video)])
        state = state.trimming(clipID: clip.id, sourceStart: 4, sourceEnd: 6)
        XCTAssertEqual(state.applyRanges[0].sourceStart, 0, accuracy: 1e-12,
                       "動画の区間が書き換わっている（素材時刻アンカーの契約違反）")
        XCTAssertEqual(state.applyRanges[0].sourceEnd, 6, accuracy: 1e-12)
    }

    // MARK: - 生成器と不変条件

    func test_fullCoverRange_forPhotoClip_startsAtZero() throws {
        // トリム済み（sourceStart > 0）の写真クリップでも区間は 0 始まり。
        let clip = TimelineClip(sourceID: photoID, sourceStart: 4, sourceEnd: 15)
        let photo = try XCTUnwrap(MosaicApplyGate.fullCoverRange(for: clip, isPhoto: true))
        XCTAssertEqual(photo.sourceStart, 0, accuracy: 1e-12)
        XCTAssertEqual(photo.sourceEnd, 15, accuracy: 1e-12)
        // 動画扱いでは従来どおりクリップ使用範囲そのもの。
        let video = try XCTUnwrap(MosaicApplyGate.fullCoverRange(for: clip, isPhoto: false))
        XCTAssertEqual(video.sourceStart, 4, accuracy: 1e-12)

        let ranges = MosaicApplyGate.fullCoverRanges(for: [clip], photoSourceIDs: [photoID])
        XCTAssertEqual(ranges.first?.sourceStart, 0)
    }

    /// 写真クリップ追加（`appending`）の自動生成も 0 始まりであること。
    func test_appendingPhotoClip_coversFromZero() {
        let secondID = UUID()
        let clip = TimelineClip(sourceID: secondID, sourceStart: 0, sourceEnd: 3)
        let state = photoState().appending(clip: clip,
                                           source: TimelineSource(id: secondID, kind: .photo))
        XCTAssertEqual(state.applyRanges.count, 2)
        XCTAssertTrue(state.validate())
        XCTAssertEqual(gateSamples(state).off, 0)
    }

    /// `validate()` が写真クリップの `sourceStart > 0` を弾くこと（この種の退行の検知網）。
    func test_validate_rejectsPhotoRangeNotStartingAtZero() {
        var state = photoState()
        XCTAssertTrue(state.validate())
        state.applyRanges = [MosaicApplyRange(clipID: state.clips[0].id, sourceID: photoID,
                                              sourceStart: 1.5, sourceEnd: 3)]
        XCTAssertFalse(state.validate(), "写真クリップの不正な区間を validate が通している")
    }
}
