import Foundation

/// タイムラインのクリップ配列に対する編集操作の純関数群。
///
/// すべての関数は入力配列を変更せず、新しい配列を返す。
/// 操作が不正（範囲外・制約違反など）な場合は**元の配列をそのまま返す**ことで、
/// 呼び出し側が「変更されたかどうか」を配列比較だけで判定できるようにしている。
public enum TimelineEditOperations {
    /// クリップ 1 本あたりの最小合成尺（秒）。
    /// 分割・トリムの結果がこれを下回る操作は拒否する。
    public static let minimumClipDuration: Double = 0.1

    /// 指定した合成時刻でクリップを 2 分割する。
    ///
    /// 分割点の素材時刻 m により [sourceStart, m) と [m, sourceEnd) に分け、
    /// 前半は元クリップの `id` を維持、後半は新しい `id` を持つ。
    /// 両者は同じ `sourceID`・`rate`・`originalAudioVolume` を引き継ぐ
    /// （素材基準の検出キャッシュを分割後も共有するため）。
    ///
    /// 次の場合は分割せず元の配列を返す:
    /// - 合成時刻が範囲外、またはクリップ境界ちょうど（前半が 0 秒になる）
    /// - 分割後のいずれかの側が最小合成尺（`minimumClipDuration`）未満になる
    public static func split(clips: [TimelineClip], at compositionTime: Double) -> [TimelineClip] {
        let mapping = TimelineMapping(clips: clips)
        guard let location = mapping.sourceLocation(at: compositionTime),
              let index = clips.firstIndex(where: { $0.id == location.clipID }),
              let clipStart = mapping.clipStartTime(clipID: location.clipID) else { return clips }
        let clip = clips[index]
        let frontDuration = compositionTime - clipStart
        let backDuration = clip.duration - frontDuration
        guard frontDuration >= minimumClipDuration, backDuration >= minimumClipDuration else { return clips }

        var front = clip
        front.sourceEnd = location.time
        let back = TimelineClip(sourceID: clip.sourceID,
                                sourceStart: location.time,
                                sourceEnd: clip.sourceEnd,
                                originalAudioVolume: clip.originalAudioVolume,
                                rate: clip.rate)
        var result = clips
        result.replaceSubrange(index...index, with: [front, back])
        return result
    }

    /// 指定したクリップを取り除く。
    ///
    /// 成功時、他のクリップの内容と相対順序は保存される。
    /// タイムラインを空にはできないため、最後の 1 本を消そうとした場合と
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func remove(clips: [TimelineClip], clipID: UUID) -> [TimelineClip] {
        guard clips.count > 1, clips.contains(where: { $0.id == clipID }) else { return clips }
        return clips.filter { $0.id != clipID }
    }

    /// 指定したクリップを `toIndex` の位置へ並べ替える。
    ///
    /// 成功時、各クリップの内容は保存され順序だけが変わる。
    /// 範囲外の `toIndex` は [0, count-1] にクランプする。
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func move(clips: [TimelineClip], clipID: UUID, toIndex: Int) -> [TimelineClip] {
        guard let fromIndex = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        let destination = min(max(toIndex, 0), clips.count - 1)
        guard fromIndex != destination else { return clips }
        var result = clips
        let clip = result.remove(at: fromIndex)
        result.insert(clip, at: destination)
        return result
    }

    /// 指定したクリップの素材使用範囲を変更する。
    ///
    /// 成功時、`id`・`sourceID`・`rate`・`originalAudioVolume` と他クリップは保存される。
    /// 次の場合は変更せず元の配列を返す:
    /// - `clipID` が見つからない
    /// - `sourceStart` が負、または `sourceStart >= sourceEnd`
    /// - 変更後の合成尺が最小合成尺（`minimumClipDuration`）未満になる
    public static func trim(clips: [TimelineClip], clipID: UUID,
                            sourceStart: Double, sourceEnd: Double) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        guard sourceStart >= 0, sourceStart < sourceEnd,
              (sourceEnd - sourceStart) / clips[index].rate >= minimumClipDuration else { return clips }
        var result = clips
        result[index].sourceStart = sourceStart
        result[index].sourceEnd = sourceEnd
        return result
    }

    /// 指定したクリップの再生倍率を設定する。
    ///
    /// 倍率は `TimelineClip.rateRange`（0.1〜10）にクランプされる。
    /// 成功時、素材使用範囲と他クリップは保存される（合成尺は倍率に応じて変わる）。
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func setRate(clips: [TimelineClip], clipID: UUID, rate: Double) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].rate = TimelineClip.clampedRate(rate)
        return result
    }
}
