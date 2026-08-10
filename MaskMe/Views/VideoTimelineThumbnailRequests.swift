import AVFoundation
import MosaicCore
import SwiftUI

// MARK: - サムネイル要求

extension VideoTimelineView {
    /// サムネイル再要求をデバウンスして積む。**再要求のトリガはすべてここを通す。**
    ///
    /// 抑止条件（`TimelineThumbnailStore.canGenerate`）は store 側だけが握っており、
    /// `request` は抑止中でもキューに積むだけで生成を始めない。したがってトリガを増やしても
    /// HW デコーダの制約（同時 1 バッチ・再生中は生成しない）は壊れない。
    /// 実コストは `refreshThumbnailRequests` の走査 CPU だけなので、そこをデバウンスと
    /// 可視範囲限定で抑える。
    func scheduleThumbnailRefresh() {
        thumbnailRefreshTask?.cancel()
        thumbnailRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.thumbnailRefreshDelay)
            guard !Task.isCancelled else { return }
            refreshThumbnailRequests()
            requestWaveformsIfNeeded()
        }
    }

    /// **可視範囲 ± 1 画面**の帯を埋めるサムネイルをまとめて要求する。
    ///
    /// 全長を走査していた版は、長尺 × 高倍率で毎回数千枠を回したうえに
    /// 予算（`thumbnailRequestLimit`）を画面外の枠に使ってしまっていた。
    /// 枠の列挙と優先度（可視中心からの距離）は `TimelineThumbnailPlanner.plan`
    /// （描画側と同じ `TimelineThumbnailLayout.slots` を通す純関数）に任せる。
    ///
    /// **`needsGeneration` で絞ってから `thumbnailRequestLimit` を掛ける順序を保つこと。**
    /// 逆にするとキャッシュ済みも予算を数え、常に同じ順の先頭 2 クリップが予算を食い切って
    /// 3 本目以降が何度 refresh しても 1 件も要求されない（実測: pps=160 / 20 秒クリップ）。
    /// 抑止中（再生・プレビューのデコード中）でもキューには積む（store 側が判断する）。
    /// body からは呼ばない（描画の副作用にしない）。
    func refreshThumbnailRequests() {
        let clips = model.timeline.clips
        let planned = TimelineThumbnailPlanner.plan(
            layouts: clipLayouts, clips: clips, geometry: geometry,
            visibleRange: TimelineScrollMath.visibleTimeRange(viewport: requestViewport,
                                                              geometry: geometry),
            marginFactor: 1.0,
            preferredSlotWidth: Double(TimelineMetrics.thumbnailSlotWidth),
            sourceDurations: sourceDurations(clips: clips))
        var jobs: [TimelineThumbnailStore.Request] = []
        for slot in planned {
            guard let url = model.sourceURL(forSourceID: slot.sourceID) else { continue }
            // planner は素材実尺クランプを掛けない（キャッシュキーを揃えるのは呼び出し側）。
            let sourceTime = model.timeline.clampedSourceTime(slot.sourceTime, sourceID: slot.sourceID)
            guard thumbnails.needsGeneration(sourceID: slot.sourceID, sourceTime: sourceTime) else { continue }
            jobs.append(TimelineThumbnailStore.Request(sourceID: slot.sourceID, url: url,
                                                       sourceTime: sourceTime))
            if jobs.count >= Self.thumbnailRequestLimit { break }
        }
        guard !jobs.isEmpty else { return }
        thumbnails.request(jobs)
    }

    /// 要求に使うビューポート。初回レイアウト前（幅 0）は先頭 1 画面ぶんで代用する
    /// （幅 0 のままだと可視レンジが空になり、1 枚も要求されないまま止まる）。
    var requestViewport: TimelineViewport {
        guard viewport.visibleWidth <= 0 else { return viewport }
        return TimelineViewport(scrollOffset: 0,
                                visibleWidth: min(Double(contentWidth), 400),
                                contentWidth: Double(contentWidth))
    }

    /// 素材実尺（sourceID → 秒）。外向きトリムのプレビューで枠が現行 `sourceEnd` の
    /// 1 コマに張り付かないよう planner へ渡す。
    func sourceDurations(clips: [TimelineClip]) -> [UUID: Double] {
        var durations: [UUID: Double] = [:]
        for clip in clips where durations[clip.sourceID] == nil {
            guard let seconds = model.sourceDuration(forClipID: clip.id) else { continue }
            durations[clip.sourceID] = seconds
        }
        return durations
    }
}
