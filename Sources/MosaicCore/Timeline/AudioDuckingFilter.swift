import Foundation

/// 「実際に声が聞こえる区間」だけに検出結果を絞り込む純関数。
///
/// **BGM を下げてよいのは、下げなくても本来聞こえるはずの声がある区間だけ。**
/// 次の 2 つを検出結果から捨てる（無音の下で BGM が下がる事故を防ぐ）:
/// - `clip.originalAudioVolume <= 0` のクリップの区間（そもそも元音声が聞こえない）
/// - `ClipAudioMuteGate` が消音している素材時刻部分（ユーザーが明示的に消音した区間）
///
/// **消音判定は `ClipAudioMuteGate` を通す。** 半開区間・`clipID`/`sourceID` の一致判定を
/// ここへ書き写すと、`ClipAudioMuteRange` 側の規則が変わったときにこちらが追従し損なう。
public enum AudioDuckingFilter {
    /// `ranges` から、無音クリップの区間・消音区間に掛かる部分を取り除いた結果。
    ///
    /// 消音区間が声区間の一部だけに掛かる場合は、声区間をその分だけ**穴あけ**して残す
    /// （全部を捨てない）。
    public static func audibleVoiceRanges(_ ranges: [ClipDuckRange],
                                          clips: [TimelineClip],
                                          muteRanges: [ClipAudioMuteRange]) -> [ClipDuckRange] {
        ranges.flatMap { range -> [ClipDuckRange] in
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID,
                  clip.originalAudioVolume > 0 else { return [] }
            return subtractingMutedPortion(of: range, muteRanges: muteRanges)
        }
    }

    /// 1 声区間から、その区間に掛かる消音区間ぶんを穴あけした残りの区間列。
    ///
    /// 交差の有無は `ClipAudioMuteGate.isMuted` の判定条件（`clipID`/`sourceID` の一致 +
    /// 半開区間）と同じものを見るが、削る幅は 2 つの具体的な区間（声区間・消音区間）の
    /// 交差なので `min`/`max` の素直な区間演算で求める（`isMuted` はある 1 時刻が消音か
    /// どうかの述語であり、区間どうしの交差そのものは返さないため、ここでは委譲できない）。
    private static func subtractingMutedPortion(of range: ClipDuckRange,
                                                muteRanges: [ClipAudioMuteRange]) -> [ClipDuckRange] {
        let holes = muteRanges
            .filter { $0.clipID == range.clipID && $0.sourceID == range.sourceID }
            .compactMap { mute -> (start: Double, end: Double)? in
                let start = max(mute.sourceStart, range.sourceStart)
                let end = min(mute.sourceEnd, range.sourceEnd)
                guard start < end else { return nil }
                return (start, end)
            }
            .sorted { $0.start < $1.start }
        guard !holes.isEmpty else { return [range] }

        var pieces: [ClipDuckRange] = []
        var cursor = range.sourceStart
        for hole in holes {
            if cursor < hole.start {
                pieces.append(ClipDuckRange(clipID: range.clipID, sourceID: range.sourceID,
                                            sourceStart: cursor, sourceEnd: hole.start))
            }
            cursor = max(cursor, hole.end)
        }
        if cursor < range.sourceEnd {
            pieces.append(ClipDuckRange(clipID: range.clipID, sourceID: range.sourceID,
                                        sourceStart: cursor, sourceEnd: range.sourceEnd))
        }
        return pieces
    }
}
