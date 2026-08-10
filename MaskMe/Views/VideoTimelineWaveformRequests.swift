import AVFoundation
import MosaicCore
import SwiftUI

/// 波形の解析要求（`VideoTimelineView` の一部）。
///
/// サムネイル要求（本体側）と分けてあるのは、必要な仕組みがまるで違うため。
/// あちらは可視範囲・生成予算・スクロール追随が要るが、波形は素材時刻に
/// アンカーした固定長のピーク列なので**1 素材 1 回で終わる**。
extension VideoTimelineView {
    /// タイムラインに載っている素材の波形を解析する。
    ///
    /// **1 素材につき 1 回で終わる**（`TimelineWaveformStore` が門番する）ので、
    /// サムネイルのような可視範囲・予算の絞り込みは要らない。サムネイル要求と
    /// 同じデバウンスに相乗りしているのは、クリップが増減した直後にまとめて
    /// 呼びたいのがどちらも同じタイミングだから。
    func requestWaveformsIfNeeded() {
        for sourceID in Set(model.timeline.clips.map(\.sourceID)) {
            guard let asset = model.sources[sourceID] else { continue }
            waveforms.requestIfNeeded(sourceID: sourceID, asset: asset)
        }
    }
}
