import XCTest
@testable import MosaicCore

/// `AudioDuckingFilter`（「実際に声が聞こえる区間」だけへ絞り込む）。
final class AudioDuckingFilterTests: XCTestCase {
    /// `originalAudioVolume <= 0` のクリップの声区間は丸ごと落ちる（無音の下で BGM が下がらない）。
    func test_audibleVoiceRanges_dropsRangesOnSilencedClip() {
        let mutedClip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10, originalAudioVolume: 0)
        let range = ClipDuckRange(clipID: mutedClip.id, sourceID: mutedClip.sourceID,
                                  sourceStart: 1, sourceEnd: 2)

        let result = AudioDuckingFilter.audibleVoiceRanges([range], clips: [mutedClip], muteRanges: [])

        XCTAssertTrue(result.isEmpty, "元音声の音量が 0 のクリップは声区間を持たないとみなす")
    }

    /// 元音量が正のクリップの声区間はそのまま残る（消音区間が無ければ）。
    func test_audibleVoiceRanges_keepsRangesOnAudibleClip() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10, originalAudioVolume: 0.7)
        let range = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 1, sourceEnd: 2)

        let result = AudioDuckingFilter.audibleVoiceRanges([range], clips: [clip], muteRanges: [])

        XCTAssertEqual(result, [range])
    }

    /// 消音区間がまるごと重なる声区間は落ちる。
    func test_audibleVoiceRanges_dropsRangeFullyCoveredByMute() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let range = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 2, sourceEnd: 4)
        let mute = ClipAudioMuteRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 1, sourceEnd: 5)

        let result = AudioDuckingFilter.audibleVoiceRanges([range], clips: [clip], muteRanges: [mute])

        XCTAssertTrue(result.isEmpty, "消音区間に完全に覆われた声区間は聞こえないので落ちる")
    }

    /// 消音区間が声区間の一部だけに掛かるときは、掛かっていない部分だけが残る（穴あけ）。
    func test_audibleVoiceRanges_punchesHoleForPartialMuteOverlap() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let range = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 2, sourceEnd: 8)
        let mute = ClipAudioMuteRange(clipID: clip.id, sourceID: clip.sourceID, sourceStart: 4, sourceEnd: 5)

        let result = AudioDuckingFilter.audibleVoiceRanges([range], clips: [clip], muteRanges: [mute])

        XCTAssertEqual(result.count, 2, "消音区間の前後だけが残る")
        XCTAssertTrue(result.contains { abs($0.sourceStart - 2) < 1e-9 && abs($0.sourceEnd - 4) < 1e-9 })
        XCTAssertTrue(result.contains { abs($0.sourceStart - 5) < 1e-9 && abs($0.sourceEnd - 8) < 1e-9 })
    }

    /// 別クリップ・別素材の消音区間は無関係（`clipID`/`sourceID` が一致するものだけを見る）。
    func test_audibleVoiceRanges_ignoresMuteRangesOnOtherClips() {
        let clipA = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let clipB = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let range = ClipDuckRange(clipID: clipA.id, sourceID: clipA.sourceID, sourceStart: 1, sourceEnd: 2)
        let mute = ClipAudioMuteRange(clipID: clipB.id, sourceID: clipB.sourceID, sourceStart: 1, sourceEnd: 2)

        let result = AudioDuckingFilter.audibleVoiceRanges([range], clips: [clipA, clipB], muteRanges: [mute])

        XCTAssertEqual(result, [range])
    }
}
