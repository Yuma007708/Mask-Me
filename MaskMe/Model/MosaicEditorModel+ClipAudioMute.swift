import Foundation
import MosaicCore

#if canImport(Metal)

/// クリップ内消音区間（区間ミュート）のプレイヘッド起点トグル。
///
/// `MosaicEditorModel+Timeline.swift` が file_length の閾値に張り付いているため
/// 分けてある（`MosaicEditorModel+ClipAudioMute` は同ファイルの一部という位置づけ）。
extension MosaicEditorModel {
    /// プレイヘッド位置の消音をトグルする（`TimelineVolumeSheet` の「この区間を消音」）。
    ///
    /// - 既にプレイヘッドが消音区間の中にいるなら、その区間を丸ごと取り除く
    ///   （「消音を解除」）。
    /// - そうでなければ、プレイヘッドから `defaultDuration` 秒（クリップ末尾で
    ///   クランプ）の消音区間を追加する。
    ///
    /// 判定・編集はどちらも `TimelineState` の編集ラッパ（`ClipAudioMuteGate` 経由）を
    /// 通す。座標系（プレイヘッド → 素材時刻）の変換は `TimelineMapping.sourceLocations(at:)`
    /// だけを使い、自前の式は書かない（トランジションの重なり内でも対象クリップの
    /// 素材時刻を正しく引くため）。
    public func toggleClipAudioMute(id: UUID, atCompositionTime time: Double,
                                    defaultDuration: Double = 2) {
        guard let clip = timeline.clips.first(where: { $0.id == id }) else { return }
        if let sourceTime = sourceTime(forClipID: id, atCompositionTime: time),
           let existing = timeline.clipAudioMuteRanges.first(where: {
               $0.clipID == id && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
           }) {
            applyTimelineEdit { $0.removingClipAudioMuteRange(id: existing.id) }
            return
        }
        guard let spanStart = timeline.mapping.clipStartTime(clipID: id) else { return }
        let spanEnd = spanStart + clip.duration
        let from = min(max(time, spanStart), spanEnd)
        let to = min(from + defaultDuration, spanEnd)
        guard to > from else { return }
        applyTimelineEdit { $0.addingClipAudioMuteRange(fromCompositionTime: from, to: to) }
    }

    /// いま指定クリップのプレイヘッド位置が消音区間の中か（ボタンのラベル切り替え用）。
    public func isClipAudioMuted(id: UUID, atCompositionTime time: Double) -> Bool {
        guard let sourceTime = sourceTime(forClipID: id, atCompositionTime: time) else { return false }
        return timeline.clipAudioMuteRanges.contains {
            $0.clipID == id && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
        }
    }

    /// 合成時刻 → 指定クリップの素材時刻。そのクリップが写らない時刻なら nil。
    ///
    /// `TimelineMapping.sourceLocation(at:)` は重なり内で常に後続（incoming）側を返すため、
    /// 先行（outgoing）側クリップを選んでいるときに取り違える。`sourceLocations(at:)` で
    /// 両側から対象クリップを探すことでこれを避ける。
    private func sourceTime(forClipID clipID: UUID, atCompositionTime time: Double) -> Double? {
        timeline.mapping.sourceLocations(at: time)
            .first { $0.location.clipID == clipID }?.location.time
    }
}

#endif
