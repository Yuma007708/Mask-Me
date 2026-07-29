import XCTest
@testable import MosaicCore

/// S6: `TimelineSource`（素材種別）と写真クリップの素材時刻 clamp のテスト。
final class TimelineSourceTests: XCTestCase {
    // MARK: - Codable 後方互換

    /// `kind` キーを持たない旧 JSON が動画（`.video`）として復元されること。
    func test_decode_missingKind_fallsBackToVideo() throws {
        let json = """
        {"id":"7F9C8E5A-1111-2222-3333-444455556666"}
        """
        let source = try JSONDecoder().decode(TimelineSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.kind, .video, "kind 欠落の旧データが .video として復元されない")
        XCTAssertEqual(source.id.uuidString, "7F9C8E5A-1111-2222-3333-444455556666")
    }

    /// `sources` キーを持たない旧 `TimelineState` JSON（S6 以前の下書き）が
    /// 空（全素材が動画扱い）としてデコードされること。
    func test_decodeTimelineState_missingSources_decodesAsEmpty() throws {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 2)
        // S6 以前のスキーマを再現: sources を持たない TimelineState をエンコードする。
        struct LegacyState: Encodable {
            let clips: [TimelineClip]
            let transitions: [UUID: TransitionSpec]
            let applyRanges: [MosaicApplyRange]
        }
        let data = try JSONEncoder().encode(
            LegacyState(clips: [clip], transitions: [:], applyRanges: []))

        let state = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(state.clips, [clip])
        XCTAssertTrue(state.sources.isEmpty, "sources 欠落の旧データが空として復元されない")
        XCTAssertEqual(state.sourceKind(of: clip.sourceID), .video,
                       "未登録の素材が動画として扱われない")
    }

    /// 写真素材を含む `TimelineState` が round-trip で kind まで復元されること。
    func test_timelineStateWithPhotoSource_roundTripsKind() throws {
        let photoID = UUID()
        let videoID = UUID()
        let state = TimelineState(
            clips: [
                TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2),
                TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)
            ],
            sources: [
                photoID: TimelineSource(id: photoID, kind: .photo),
                videoID: TimelineSource(id: videoID, kind: .video)
            ])
        XCTAssertTrue(state.validate())

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(decoded, state, "sources を含む TimelineState が round-trip しない")
        XCTAssertEqual(decoded.sourceKind(of: photoID), .photo)
        XCTAssertEqual(decoded.photoSourceIDs, [photoID])
    }

    // MARK: - 素材時刻の clamp（写真は t=0 固定）

    /// 写真素材の素材時刻が 0 に clamp され、動画素材・未登録素材は素通しになること。
    func test_clampedSourceTime_photoClampsToZero_videoPassesThrough() {
        let photoID = UUID()
        let videoID = UUID()
        let state = TimelineState(
            clips: [TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)],
            sources: [photoID: TimelineSource(id: photoID, kind: .photo),
                      videoID: TimelineSource(id: videoID, kind: .video)])

        XCTAssertEqual(state.clampedSourceTime(1.7, sourceID: photoID), 0,
                       "写真素材の素材時刻が 0 に clamp されない")
        XCTAssertEqual(state.clampedSourceTime(0, sourceID: photoID), 0)
        XCTAssertEqual(state.clampedSourceTime(1.7, sourceID: videoID), 1.7,
                       "動画素材の素材時刻が変更された")
        XCTAssertEqual(state.clampedSourceTime(1.7, sourceID: UUID()), 1.7,
                       "未登録素材（旧データ相当）が動画扱いになっていない")
    }

    /// 写像（mapping）の後に clamp する運用で、写真クリップ区間の全合成時刻が
    /// 素材時刻 0（seed バケット）へ落ちること。
    func test_mappingThenClamp_photoRegionAlwaysHitsSeedBucket() {
        let videoID = UUID()
        let photoID = UUID()
        let state = TimelineState(
            clips: [
                TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2),
                TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)
            ],
            sources: [photoID: TimelineSource(id: photoID, kind: .photo)])
        let mapping = state.mapping

        // 写真クリップ区間（合成 [2,5)）: 写像 → clamp で常に素材時刻 0
        for t in [2.0, 2.5, 3.9, 4.999] {
            let location = mapping.sourceLocation(at: t)
            XCTAssertEqual(location?.sourceID, photoID)
            XCTAssertEqual(state.clampedSourceTime(location!.time, sourceID: location!.sourceID), 0,
                           "合成 \(t)s（写真区間）が素材時刻 0 に落ちない")
        }
        // 動画クリップ区間（合成 [0,2)）は恒等
        let videoLocation = mapping.sourceLocation(at: 1.25)
        XCTAssertEqual(videoLocation?.sourceID, videoID)
        XCTAssertEqual(state.clampedSourceTime(videoLocation!.time, sourceID: videoID),
                       1.25, accuracy: 1e-9)
    }

    // MARK: - 編集操作での sources 維持

    /// split / remove / move / trim / setRate のいずれでも素材メタ（kind）が失われないこと
    /// （内部で TimelineState を再構築する際の取りこぼし防止）。
    func test_editOperations_preserveSources() {
        let photoID = UUID()
        let videoID = UUID()
        let video = TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 4)
        let photo = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)
        let sources = [photoID: TimelineSource(id: photoID, kind: .photo)]
        let state = TimelineState(clips: [video, photo], sources: sources)

        XCTAssertEqual(state.splitting(at: 2.0).sources, sources, "splitting で sources が消えた")
        XCTAssertEqual(state.removing(clipID: video.id).sources, sources, "removing で sources が消えた")
        XCTAssertEqual(state.moving(clipID: photo.id, toIndex: 0).sources, sources,
                       "moving で sources が消えた")
        XCTAssertEqual(state.trimming(clipID: video.id, sourceStart: 1, sourceEnd: 3).sources, sources,
                       "trimming で sources が消えた")
        XCTAssertEqual(state.settingRate(clipID: video.id, rate: 2.0).sources, sources,
                       "settingRate で sources が消えた")
    }

    // MARK: - appending（写真クリップの追加経路）

    /// appending がクリップと素材メタを同時登録し、壊れたクリップでは self を返すこと。
    func test_appending_addsClipAndSource_rejectsInvalidClip() {
        let videoID = UUID()
        let photoID = UUID()
        let state = TimelineState(clips: [TimelineClip(sourceID: videoID, sourceStart: 0, sourceEnd: 2)])
        let photoClip = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: 3)

        let appended = state.appending(clip: photoClip,
                                       source: TimelineSource(id: photoID, kind: .photo))
        XCTAssertEqual(appended.clips.count, 2)
        XCTAssertEqual(appended.clips.last, photoClip)
        XCTAssertEqual(appended.sourceKind(of: photoID), .photo)
        XCTAssertTrue(appended.validate())
        XCTAssertEqual(appended.mapping.totalDuration, 5.0, accuracy: 1e-9)

        // 壊れたクリップ（start >= end・非有限）は self を返す
        let zeroLength = TimelineClip(sourceID: photoID, sourceStart: 1, sourceEnd: 1)
        XCTAssertEqual(state.appending(clip: zeroLength), state)
        let nonFinite = TimelineClip(sourceID: photoID, sourceStart: 0, sourceEnd: .infinity)
        XCTAssertEqual(state.appending(clip: nonFinite), state)
    }

    /// validate が「キーと TimelineSource.id の食い違い」を検出すること。
    func test_validate_rejectsMismatchedSourceKey() {
        let sourceID = UUID()
        let state = TimelineState(
            clips: [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)],
            sources: [UUID(): TimelineSource(id: sourceID, kind: .photo)])
        XCTAssertFalse(state.validate(), "キーと id が食い違う sources を validate が見逃した")
    }
}
