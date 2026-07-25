import XCTest
@testable import MosaicCore

final class TimelineEditOperationsTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// クリップA(素材Aの0-3秒) + クリップB(素材Bの10-14秒) の並び。
    private func makeClips() -> [TimelineClip] {
        [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3),
         TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)]
    }

    // MARK: - split

    /// 分割後の 2 クリップは sourceID・rate・音量を引き継ぎ、
    /// 前半が元の id を維持、後半が新しい id を持つこと。
    func test_splitInheritsAttributesAndKeepsFrontID() {
        let original = TimelineClip(sourceID: sourceA, sourceStart: 1, sourceEnd: 5,
                                    originalAudioVolume: 0.5, rate: 2.0) // 合成 2 秒
        let result = TimelineEditOperations.split(clips: [original], at: 1.0)

        XCTAssertEqual(result.count, 2)
        let front = result[0]
        let back = result[1]
        // 前半: id 維持、[1, 3)。
        XCTAssertEqual(front.id, original.id)
        XCTAssertEqual(front.sourceStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(front.sourceEnd, 3.0, accuracy: 1e-9)
        // 後半: 新 id、[3, 5)。
        XCTAssertNotEqual(back.id, original.id)
        XCTAssertEqual(back.sourceStart, 3.0, accuracy: 1e-9)
        XCTAssertEqual(back.sourceEnd, 5.0, accuracy: 1e-9)
        // 両者とも sourceID・rate・音量を引き継ぐ。
        for clip in result {
            XCTAssertEqual(clip.sourceID, sourceA)
            XCTAssertEqual(clip.rate, 2.0, accuracy: 1e-9)
            XCTAssertEqual(clip.originalAudioVolume, 0.5)
        }
    }

    /// 分割は対象クリップだけを 2 分し、前後のクリップは保存されること。
    func test_splitKeepsOtherClipsIntact() {
        let clips = makeClips()
        let result = TimelineEditOperations.split(clips: clips, at: 4.0) // クリップB内(先頭から1秒)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], clips[0])
        XCTAssertEqual(result[1].sourceEnd, 11.0, accuracy: 1e-9)
        XCTAssertEqual(result[2].sourceStart, 11.0, accuracy: 1e-9)
    }

    /// クリップ境界ちょうど・範囲外では分割せず元の配列を返すこと。
    func test_splitRejectsBoundaryAndOutOfRange() {
        let clips = makeClips()
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 0.0), clips)  // 先頭
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 3.0), clips)  // 境界(Bの先頭0秒)
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 7.0), clips)  // 末尾ちょうど
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: -1.0), clips) // 負
    }

    /// 分割後のどちらかが最小合成尺(0.1秒)未満になる場合は分割しないこと。
    func test_splitRejectsTooShortSide() {
        let clips = makeClips()
        // 前半 0.05 秒 < 0.1 秒。
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 0.05), clips)
        // 後半 0.05 秒 < 0.1 秒。
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 2.95), clips)
        // ちょうど 0.1 秒は許容される。
        XCTAssertEqual(TimelineEditOperations.split(clips: clips, at: 0.1).count, 3)
    }

    /// 最小尺の判定は合成時刻基準であること（0.1x では素材 0.01 秒でも合成 0.1 秒として有効）。
    func test_splitMinimumDurationIsInCompositionTime() {
        let slow = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 1, rate: 0.1) // 合成 10 秒
        let result = TimelineEditOperations.split(clips: [slow], at: 0.1)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].sourceEnd, 0.01, accuracy: 1e-9)
    }

    // MARK: - remove

    func test_removeDeletesClip() {
        let clips = makeClips()
        let result = TimelineEditOperations.remove(clips: clips, clipID: clips[0].id)
        XCTAssertEqual(result, [clips[1]])
    }

    /// 最後の 1 本は削除できないこと。未知の id も変更なし。
    func test_removeRejectsLastClipAndUnknownID() {
        let clips = makeClips()
        let single = [clips[0]]
        XCTAssertEqual(TimelineEditOperations.remove(clips: single, clipID: clips[0].id), single)
        XCTAssertEqual(TimelineEditOperations.remove(clips: clips, clipID: UUID()), clips)
    }

    // MARK: - move

    func test_moveReordersClips() {
        let clips = makeClips()
        let result = TimelineEditOperations.move(clips: clips, clipID: clips[0].id, toIndex: 1)
        XCTAssertEqual(result, [clips[1], clips[0]])
    }

    /// 範囲外 index はクランプされること。未知の id は変更なし。
    func test_moveClampsIndexAndRejectsUnknownID() {
        let clips = makeClips()
        XCTAssertEqual(TimelineEditOperations.move(clips: clips, clipID: clips[0].id, toIndex: 99),
                       [clips[1], clips[0]])
        XCTAssertEqual(TimelineEditOperations.move(clips: clips, clipID: clips[1].id, toIndex: -5),
                       [clips[1], clips[0]])
        XCTAssertEqual(TimelineEditOperations.move(clips: clips, clipID: UUID(), toIndex: 0), clips)
    }

    // MARK: - trim

    func test_trimUpdatesSourceRange() {
        let clips = makeClips()
        let result = TimelineEditOperations.trim(clips: clips, clipID: clips[1].id,
                                                 sourceStart: 11, sourceEnd: 13)
        XCTAssertEqual(result[1].sourceStart, 11.0, accuracy: 1e-9)
        XCTAssertEqual(result[1].sourceEnd, 13.0, accuracy: 1e-9)
        // id・sourceID・他クリップは保存される。
        XCTAssertEqual(result[1].id, clips[1].id)
        XCTAssertEqual(result[1].sourceID, sourceB)
        XCTAssertEqual(result[0], clips[0])
    }

    /// 不正な素材範囲（start >= end、負の start、最小合成尺未満）は変更なし。
    func test_trimRejectsInvalidRange() {
        let clips = makeClips()
        let clipID = clips[0].id
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID, sourceStart: 2, sourceEnd: 2), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID, sourceStart: 2, sourceEnd: 1), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID, sourceStart: -1, sourceEnd: 2), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID, sourceStart: 0, sourceEnd: 0.05), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: UUID(), sourceStart: 0, sourceEnd: 1), clips)
    }

    /// 非有限の素材範囲（±∞・NaN）は変更なし。NaN は比較ガードで落ちるが、
    /// +∞ の sourceEnd はかつて素通りして合成尺・写像全体（totalDuration）を
    /// ∞ に汚染していた（S4 レビューの実測）。
    func test_trimRejectsNonFiniteRange() {
        let clips = makeClips()
        let clipID = clips[0].id
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: 0, sourceEnd: .infinity), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: .infinity, sourceEnd: .infinity), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: -.infinity, sourceEnd: 2), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: .nan, sourceEnd: 2), clips)
        XCTAssertEqual(TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: 0, sourceEnd: .nan), clips)
        // 写像が ∞ に汚染されないこと（totalDuration が有限のまま）。
        let mapping = TimelineMapping(clips: TimelineEditOperations.trim(
            clips: clips, clipID: clipID, sourceStart: 0, sourceEnd: .infinity))
        XCTAssertTrue(mapping.totalDuration.isFinite)
    }

    /// 最小尺の判定は合成時刻基準であること（2x では素材 0.15 秒は合成 0.075 秒となり不可）。
    func test_trimMinimumDurationIsInCompositionTime() {
        let fast = [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3, rate: 2.0)]
        XCTAssertEqual(TimelineEditOperations.trim(clips: fast, clipID: fast[0].id,
                                                   sourceStart: 0, sourceEnd: 0.15), fast)
        // 素材 0.2 秒 = 合成 0.1 秒ちょうどは許容される。
        let trimmed = TimelineEditOperations.trim(clips: fast, clipID: fast[0].id,
                                                  sourceStart: 0, sourceEnd: 0.2)
        XCTAssertEqual(trimmed[0].sourceEnd, 0.2, accuracy: 1e-9)
    }

    // MARK: - setRate

    func test_setRateUpdatesRate() {
        let clips = makeClips()
        let result = TimelineEditOperations.setRate(clips: clips, clipID: clips[0].id, rate: 2.0)
        XCTAssertEqual(result[0].rate, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(result[1], clips[1])
    }

    /// 範囲外の倍率は 0.1〜10 にクランプされること。未知の id は変更なし。
    func test_setRateClampsAndRejectsUnknownID() {
        let clips = makeClips()
        XCTAssertEqual(TimelineEditOperations.setRate(clips: clips, clipID: clips[0].id, rate: 100)[0].rate,
                       10.0, accuracy: 1e-9)
        XCTAssertEqual(TimelineEditOperations.setRate(clips: clips, clipID: clips[0].id, rate: 0.01)[0].rate,
                       0.1, accuracy: 1e-9)
        XCTAssertEqual(TimelineEditOperations.setRate(clips: clips, clipID: UUID(), rate: 2.0), clips)
    }

    // MARK: - rate のクランプ（NaN・直接代入）

    /// NaN は min/max を素通りして mapping 全体を無効化するため、等速（1.0）に落とすこと。
    func test_rateClampRejectsNaN() {
        XCTAssertEqual(TimelineClip.clampedRate(.nan), 1.0, accuracy: 1e-9)
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3, rate: .nan)
        XCTAssertEqual(clip.rate, 1.0, accuracy: 1e-9)
        let result = TimelineEditOperations.setRate(clips: [clip], clipID: clip.id, rate: .nan)
        XCTAssertEqual(result[0].rate, 1.0, accuracy: 1e-9)
    }

    /// rate は public var のため、直接代入でも didSet でクランプされること
    /// （rate=0 の素通しは duration=+inf を生む）。
    func test_rateDirectAssignmentIsClamped() {
        var clip = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        clip.rate = 0
        XCTAssertEqual(clip.rate, 0.1, accuracy: 1e-9)
        XCTAssertTrue(clip.duration.isFinite)
        clip.rate = 100
        XCTAssertEqual(clip.rate, 10.0, accuracy: 1e-9)
        clip.rate = .nan
        XCTAssertEqual(clip.rate, 1.0, accuracy: 1e-9)
    }

    // MARK: - Codable

    /// エンコード→デコードの round-trip で全プロパティが一致すること。
    func test_codableRoundTrip() throws {
        let clip = TimelineClip(sourceID: sourceA, sourceStart: 1.5, sourceEnd: 4.25,
                                originalAudioVolume: 0.7, rate: 0.5)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: data)
        XCTAssertEqual(decoded, clip)
    }

    /// rate キーを持たない旧 JSON は rate = 1.0 としてデコードできること（下書き互換）。
    func test_decodeLegacyJSONWithoutRate() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","sourceID":"\(sourceA.uuidString)",
         "sourceStart":2.0,"sourceEnd":5.0,"originalAudioVolume":1.0}
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.rate, 1.0, accuracy: 1e-9)
        XCTAssertEqual(decoded.duration, 3.0, accuracy: 1e-9)
    }

    /// init と同様、デコード時も rate は許容範囲にクランプされること。
    func test_decodeClampsOutOfRangeRate() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceID":"\(sourceA.uuidString)",
         "sourceStart":0,"sourceEnd":1,"originalAudioVolume":1.0,"rate":99.0}
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rate, 10.0, accuracy: 1e-9)
    }
}
