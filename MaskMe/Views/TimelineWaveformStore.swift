import AVFoundation
import MosaicCore
import SwiftUI

/// 素材ごとの音声波形を作って持つ置き場。
///
/// サムネイル（`TimelineThumbnailStore`）と同じ流儀:
/// - 解析は `Task.detached` の中で行い MainActor をブロックしない。書き込みだけ戻る。
/// - **同じ素材を二重に解析しない**（`inFlight` で門番する）。
/// - 素材が入れ替わったら捨てる（`reset`）。
///
/// サムネイルと違うのは **1 素材につき 1 回で終わる**こと。波形は素材時刻に
/// アンカーした固定長のピーク列なので（`AudioWaveform` の doc）、ズームしても
/// トリムしても作り直す必要が無い。したがってスクロールに追随する要求の仕組みも、
/// 生成予算も要らない。
@MainActor
final class TimelineWaveformStore: ObservableObject {
    @Published private(set) var waveforms: [UUID: AudioWaveform] = [:]

    private var inFlight: Set<UUID> = []

    func waveform(for sourceID: UUID) -> AudioWaveform? { waveforms[sourceID] }

    /// まだ持っていない素材の解析を始める。**同じ素材を二重に投げても 1 回しか走らない。**
    ///
    /// 解析の実体は `AudioWaveformAnalyzer`（BGM ダッキングの検出と共有する唯一の実装。
    /// 同ファイル冒頭 doc 参照）。ここは「MainActor をブロックせず、同じ素材を二重に
    /// 解析しない」門番の役目に絞る。
    func requestIfNeeded(sourceID: UUID, asset: AVAsset) {
        guard waveforms[sourceID] == nil, !inFlight.contains(sourceID) else { return }
        inFlight.insert(sourceID)
        Task.detached(priority: .utility) {
            let waveform = await AudioWaveformAnalyzer.analyze(asset: asset)
            await MainActor.run {
                self.waveforms[sourceID] = waveform
                self.inFlight.remove(sourceID)
            }
        }
    }

    /// 素材が入れ替わったら捨てる（別素材の波形を描かない）。
    func reset() {
        waveforms.removeAll()
        inFlight.removeAll()
    }
}
