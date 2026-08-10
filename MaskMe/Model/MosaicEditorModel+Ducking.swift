import AVFoundation
import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` の BGM ダッキング（E2-3）編集 API。
///
/// `MosaicEditorModel+Timeline.swift` が file_length の閾値に張り付いているため
/// 分けてある（`MosaicEditorModel+Audio` / `MosaicEditorModel+ClipAudioMute` と同じ理由）。
/// 声区間の検出は `AudioWaveformAnalyzer`（`TimelineWaveformStore` の波形表示と同じ実装。
/// 別実装にしない）→ `AudioDuckingDetector.voiceRanges` の順で行い、結果は
/// `applyTimelineEdit` 経由で `timeline.clipDuckRanges` へ書く（undo/redo・下書きに載る）。
extension MosaicEditorModel {
    /// 全クリップの声区間を検出し直し、`timeline.clipDuckRanges` を丸ごと置き換える
    /// （「もう一度検出する」の入口）。
    ///
    /// **無音クリップの区間・区間ミュートに掛かる部分の絞り込みはここでは行わない。**
    /// `AudioMixFactory` が書き出し・プレビュー再構築のたびに
    /// `AudioDuckingFilter.audibleVoiceRanges` を通して絞り込む（音量やミュートを
    /// 後から変えても、保存済みの検出結果を書き換えずに追随させるため。
    /// `AudioMixFactory.make(clipDuckRanges:)` の doc 参照）。
    public func redetectDucking() async {
        var analyzed: [UUID: AudioWaveform] = [:]
        var ranges: [ClipDuckRange] = []
        for clip in timeline.clips {
            guard let asset = sources[clip.sourceID] else { continue }
            let waveform: AudioWaveform
            if let cached = analyzed[clip.sourceID] {
                waveform = cached
            } else {
                waveform = await AudioWaveformAnalyzer.analyze(asset: asset)
                analyzed[clip.sourceID] = waveform
            }
            ranges.append(contentsOf: AudioDuckingDetector.voiceRanges(waveform: waveform, clip: clip))
        }
        applyTimelineEdit { state in
            var next = state
            next.clipDuckRanges = ranges
            return next
        }
    }

    /// 指定 BGM のダッキングを ON/OFF する（`TimelineVolumeSheet` の「声に合わせて下げる」トグル）。
    ///
    /// - ON: **まだ声区間を検出していなければ**（`clipDuckRanges` が空なら）検出してから
    ///   `gain` を設定する。既に区間があれば解析し直さない（区間データは温存する規約。
    ///   `ClipDuckRange` 型の doc 参照）。
    /// - OFF: `duckingGain` を `1`（下げない）へ戻すだけ。**区間データは消さない**
    ///   （再 ON で解析し直さずに済むように）。
    public func setDuckingEnabled(audioItemID: UUID, enabled: Bool, gain: Float) async {
        guard enabled else {
            setDuckingGain(audioItemID: audioItemID, gain: 1)
            return
        }
        if timeline.clipDuckRanges.isEmpty {
            await redetectDucking()
        }
        setDuckingGain(audioItemID: audioItemID, gain: gain)
    }

    /// 指定 BGM のダッキング量（弱 0.5 / 中 0.25 / 強 0.125）を設定する。
    /// `1` を渡すと事実上 OFF と同じ（`AudioItem.duckingGain` の doc 参照）。
    public func setDuckingGain(audioItemID: UUID, gain: Float) {
        applyTimelineEdit { state in
            guard let index = state.audioItems.firstIndex(where: { $0.id == audioItemID }) else {
                return state
            }
            var next = state
            next.audioItems[index].duckingGain = gain
            return next
        }
    }
}

#endif
