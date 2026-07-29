import XCTest
@testable import MosaicCore

/// S11: 下書き（`TimelineState` の Codable）の v1 → v2 移行。
///
/// v1 は `MosaicApplyRange` に `clipID` が無く、**空 = 全区間適用**だった。
/// v2 は `clipID` を持ち、**空 = 適用なし（全区間 OFF）**。意味が反転しているので、
/// `schemaVersion` の有無で読み分ける（書き忘れると「全削除した下書き」が
/// 「全体を覆う 1 本」へ化ける）。
final class MosaicApplyMigrationTests: XCTestCase {
    private let sourceA = UUID()

    private func range(_ clip: TimelineClip, _ start: Double, _ end: Double) -> MosaicApplyRange {
        MosaicApplyRange(clipID: clip.id, sourceID: clip.sourceID,
                         sourceStart: start, sourceEnd: end)
    }

    // MARK: - 永続化（v1 → v2 移行）

    /// v1（`schemaVersion` を持たず、`applyRanges` に `clipID` が無い）下書き JSON を作る。
    ///
    /// clips / transitions / sources の表現は実エンコーダに任せ、v1 との差分
    /// （`schemaVersion` の除去と `applyRanges` の旧形式化）だけを文字列で当てる。
    /// 手書きすると `[UUID: T]` が配列で符号化される Swift の規則を踏み外す。
    private func legacyJSON(clips: [TimelineClip], applyRanges: String) throws -> Data {
        let current = TimelineState(clips: clips)
        var text = try XCTUnwrap(String(bytes: try JSONEncoder().encode(current), encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\":2"))
        text = text.replacingOccurrences(of: ",\"schemaVersion\":2", with: "")
        text = text.replacingOccurrences(of: "\"schemaVersion\":2,", with: "")
        XCTAssertTrue(text.contains("\"applyRanges\":[]"))
        text = text.replacingOccurrences(of: "\"applyRanges\":[]",
                                         with: "\"applyRanges\":[\(applyRanges)]")
        return Data(text.utf8)
    }

    /// (a) v1 で区間 0 本 + クリップ 2 本 → 旧仕様の「空 = 全区間 ON」を保存するため、
    /// クリップ全体を覆う区間が 2 本生成されること。
    func test_migration_emptyLegacyRangesBecomeFullCover() throws {
        let clips = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4),
                     TimelineClip(sourceID: UUID(), sourceStart: 1, sourceEnd: 3)]
        let decoded = try JSONDecoder().decode(TimelineState.self,
                                               from: legacyJSON(clips: clips, applyRanges: ""))
        XCTAssertEqual(decoded.applyRanges.count, 2)
        XCTAssertEqual(Set(decoded.applyRanges.map(\.clipID)), Set(clips.map(\.id)))
        print("[S11-migrate] v1 区間 0 本 + クリップ 2 本 → v2 区間 \(decoded.applyRanges.count) 本 "
              + "(全体を覆う): " + decoded.applyRanges
                  .map { "[\($0.sourceStart),\($0.sourceEnd))" }.joined(separator: " "))
        XCTAssertTrue(decoded.validate())
        // 意味が保存されている: 全合成時刻で ON。
        for t in stride(from: 0.0, to: decoded.mapping.totalDuration, by: 0.1) {
            XCTAssertTrue(MosaicApplyGate.isActive(ranges: decoded.applyRanges, mapping: decoded.mapping,
                                                   compositionTime: t, photoSourceIDs: []),
                          "旧「空 = 全区間 ON」が保存されていない（t=\(t)）")
        }
    }

    /// (b) 2 クリップにまたがる v1 区間 → クリップごとに交差部分へクリップした 2 本になること。
    /// id は最初に一致したクリップだけ継承する。
    func test_migration_legacyRangeIsClippedPerClip() throws {
        let front = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let back = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let legacyID = UUID()
        let json = try legacyJSON(clips: [front, back], applyRanges: """
        {"id":"\(legacyID.uuidString)","sourceID":"\(sourceA.uuidString)","sourceStart":1,"sourceEnd":3}
        """)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: json)

        XCTAssertEqual(decoded.applyRanges.count, 2)
        XCTAssertEqual(decoded.applyRanges[0].clipID, front.id)
        XCTAssertEqual(decoded.applyRanges[0].id, legacyID, "最初の一致は旧 id を継承する")
        XCTAssertEqual(decoded.applyRanges[0].sourceStart, 1, accuracy: 1e-12)
        XCTAssertEqual(decoded.applyRanges[0].sourceEnd, 2, accuracy: 1e-12, "クリップ使用範囲でクリップ")
        XCTAssertEqual(decoded.applyRanges[1].clipID, back.id)
        XCTAssertNotEqual(decoded.applyRanges[1].id, legacyID, "2 本目は新規 id")
        XCTAssertEqual(decoded.applyRanges[1].sourceStart, 2, accuracy: 1e-12)
        XCTAssertEqual(decoded.applyRanges[1].sourceEnd, 3, accuracy: 1e-12)
        XCTAssertTrue(decoded.validate())
        print("[S11-migrate] v1 区間 source[1,3) × クリップ[0,2)/[2,5) → v2 "
              + decoded.applyRanges
                  .map { "clip=\($0.clipID.uuidString.prefix(4)) [\($0.sourceStart),\($0.sourceEnd))" }
                  .joined(separator: " / "))
        // ゲートの意味も保存されている: 合成 [1,3) だけ ON。
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: decoded.applyRanges, mapping: decoded.mapping,
                                                compositionTime: 0.5, photoSourceIDs: []))
        XCTAssertTrue(MosaicApplyGate.isActive(ranges: decoded.applyRanges, mapping: decoded.mapping,
                                               compositionTime: 2.5, photoSourceIDs: []))
        XCTAssertFalse(MosaicApplyGate.isActive(ranges: decoded.applyRanges, mapping: decoded.mapping,
                                                compositionTime: 3.5, photoSourceIDs: []))
    }

    /// (c) どのクリップとも交差しない v1 区間は落ちること
    /// （旧実装でも帯・ゲートの両方から既に除外されていたので観測挙動は変わらない）。
    func test_migration_dropsLegacyRangesWithoutIntersection() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let json = try legacyJSON(clips: [clip], applyRanges: """
        {"id":"\(UUID().uuidString)","sourceID":"\(sourceA.uuidString)","sourceStart":5,"sourceEnd":6},
        {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)","sourceStart":0,"sourceEnd":2}
        """)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: json)
        XCTAssertTrue(decoded.applyRanges.isEmpty, "交差しない旧区間が残っている")
        print("[S11-migrate] どのクリップとも交差しない v1 区間 2 本 → v2 区間 \(decoded.applyRanges.count) 本")
    }

    /// (d) `schemaVersion: 2` の JSON は変換せず素通しすること。
    func test_migration_schemaVersion2IsPassedThrough() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        var state = TimelineState(clips: [clip])
        state.applyRanges = [range(clip, 1, 2)]
        let data = try JSONEncoder().encode(state)
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\":2"),
                      "encode が schemaVersion を書いていない（次回起動で v1 と誤認する）")
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.applyRanges[0].id, state.applyRanges[0].id)
    }

    /// (e) **encode → decode の往復で「区間 0 本」が 0 本のままであること。**
    ///
    /// ここが崩れると、ユーザーが意図的に全区間を削除した下書きが次回起動で
    /// 「全体を覆う 1 本」へ化ける（新仕様の意味が黙って逆転する最悪の事故）。
    func test_migration_emptyRangesSurviveRoundTrip() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 4)
        let state = TimelineState(clips: [clip], applyRanges: [])
        let decoded = try JSONDecoder().decode(TimelineState.self,
                                               from: JSONEncoder().encode(state))
        XCTAssertTrue(decoded.applyRanges.isEmpty, "全削除した状態が復活している")
        // 2 周しても復活しない。
        let twice = try JSONDecoder().decode(TimelineState.self,
                                             from: JSONEncoder().encode(decoded))
        XCTAssertTrue(twice.applyRanges.isEmpty)
        // 区間 0 本 = 全区間 OFF。
        for t in stride(from: 0.0, to: 4.0, by: 0.25) {
            XCTAssertFalse(MosaicApplyGate.isActive(ranges: decoded.applyRanges, mapping: decoded.mapping,
                                                    compositionTime: t, photoSourceIDs: []))
        }
    }
}
