import Foundation

/// BGM（`AudioItem`）の編集操作と正規化（E2）。
///
/// 適用区間の編集（`TimelineStateApplyRangeEditing.swift`）と同じ契約に従う:
/// **失敗時は self をそのまま返す**（呼び出し側は状態比較だけで「変わったか」を判定できる）。
///
/// **クリップ編集への追従は存在しない。** BGM は合成時刻アンカーなので、
/// split / remove / move / trim / rate のどれもここを呼ばない（`AudioItem` 型の doc 参照）。
extension TimelineState {
    /// BGM を 1 本追加する。
    ///
    /// `atCompositionTime` から素材の全長ぶん置く。**次の曲とぶつかる場合はそこで切る**
    /// （後ろへ押しのけない。押しのけると、置いただけで既存の BGM の位置が動く）。
    /// 置ける幅が `AudioItem.minimumDuration` 未満なら何もしない。
    ///
    /// - Parameter sourceDuration: 音源の実尺（秒）。曲の頭から使う。
    public func addingAudioItem(sourceID: UUID, sourceDuration: Double,
                                atCompositionTime start: Double) -> TimelineState {
        guard sourceDuration.isFinite, sourceDuration > 0,
              start.isFinite, start >= 0 else { return self }
        // この位置より後ろで一番近い曲の頭（＝ここまでしか置けない）。
        let nextStart = audioItems
            .filter { $0.compositionStart > start }
            .map(\.compositionStart)
            .min() ?? .infinity
        // 置こうとした位置が既存の曲の内側なら置かない（重ならない規則）。
        guard !audioItems.contains(where: {
            start >= $0.compositionStart && start < $0.compositionEnd
        }) else { return self }
        let available = min(sourceDuration, nextStart - start)
        guard available >= AudioItem.minimumDuration else { return self }
        var next = self
        next.audioItems = Self.normalizedAudioItems(audioItems + [
            AudioItem(sourceID: sourceID, sourceStart: 0, sourceEnd: available,
                      compositionStart: start)
        ])
        return next
    }

    /// 指定した BGM を取り除く。
    public func removingAudioItem(id: UUID) -> TimelineState {
        guard audioItems.contains(where: { $0.id == id }) else { return self }
        var next = self
        next.audioItems = audioItems.filter { $0.id != id }
        return next
    }

    /// 指定した BGM を合成時刻で `delta` 秒だけ平行移動する。
    ///
    /// **隣の曲をすり抜けない**（ぶつかる手前でクランプする）。0 秒より前へも行かない。
    /// クランプの結果 1 mm も動かないなら self を返す（no-op を編集履歴へ積まない）。
    ///
    /// 合成尺の**右端はここでは見ない**。BGM は合成時刻アンカーなので、いったん尺の外へ
    /// 出しても縮んだタイムラインを伸ばせば戻ってくる（`AudioItem` 型の doc の温存規則）。
    public func movingAudioItem(id: UUID, byCompositionDelta delta: Double) -> TimelineState {
        guard delta.isFinite, delta != 0,
              let index = audioItems.firstIndex(where: { $0.id == id }) else { return self }
        let item = audioItems[index]
        let others = audioItems.filter { $0.id != id }
        let lowerBound = others
            .filter { $0.compositionEnd <= item.compositionStart }
            .map(\.compositionEnd)
            .max() ?? 0
        let upperBound = others
            .filter { $0.compositionStart >= item.compositionEnd }
            .map(\.compositionStart)
            .min() ?? .infinity
        let desired = item.compositionStart + delta
        let clamped = min(max(desired, max(lowerBound, 0)), upperBound - item.duration)
        guard clamped.isFinite, abs(clamped - item.compositionStart) > 1e-9 else { return self }
        var next = self
        next.audioItems[index].compositionStart = clamped
        next.audioItems = Self.normalizedAudioItems(next.audioItems)
        return next
    }

    /// 指定した BGM の端を合成時刻で `delta` 秒だけ動かす（つまみの伸縮）。
    ///
    /// **BGM に倍速は無いので、合成時刻の伸縮はそのまま素材時刻の伸縮になる。**
    /// 素材の端（`sourceStart >= 0`・音源の実尺）と隣の曲でクランプする。
    ///
    /// - Parameter sourceDuration: 音源の実尺（秒）。右端をここより先へは伸ばせない。
    ///   取得できない場合は現在の `sourceEnd` を上限として渡すこと（伸ばせないだけで壊れない）。
    public func trimmingAudioItem(id: UUID, edge: TimelineTrimEdge,
                                  byCompositionDelta delta: Double,
                                  sourceDuration: Double) -> TimelineState {
        guard delta.isFinite, delta != 0, sourceDuration.isFinite,
              let index = audioItems.firstIndex(where: { $0.id == id }) else { return self }
        let item = audioItems[index]
        let others = audioItems.filter { $0.id != id }
        var next = item
        switch edge {
        case .start:
            // 左端: 素材の頭（sourceStart = 0）と、手前の曲の終端でクランプ。
            let previousEnd = others
                .filter { $0.compositionEnd <= item.compositionStart }
                .map(\.compositionEnd)
                .max() ?? 0
            let minDelta = max(-item.sourceStart, previousEnd - item.compositionStart)
            let maxDelta = item.duration - AudioItem.minimumDuration
            let applied = min(max(delta, minDelta), maxDelta)
            guard abs(applied) > 1e-9 else { return self }
            next.compositionStart += applied
            next.sourceStart += applied
        case .end:
            // 右端: 素材の尻と、次の曲の頭でクランプ。
            let nextStart = others
                .filter { $0.compositionStart >= item.compositionEnd }
                .map(\.compositionStart)
                .min() ?? .infinity
            let minDelta = AudioItem.minimumDuration - item.duration
            let maxDelta = min(sourceDuration - item.sourceEnd, nextStart - item.compositionEnd)
            guard maxDelta.isFinite else { return self }
            let applied = min(max(delta, minDelta), maxDelta)
            guard abs(applied) > 1e-9 else { return self }
            next.sourceEnd += applied
        }
        guard next.duration >= AudioItem.minimumDuration else { return self }
        // duration が変わった（伸縮した）ので、古いフェード値のままだと重ならない
        // 規則（`AudioItem.clampFades` の doc）を破り得る。ここで丸め直す。
        next.clampFades()
        var result = self
        result.audioItems[index] = next
        result.audioItems = Self.normalizedAudioItems(result.audioItems)
        return result
    }

    /// 指定した BGM の音量（0...1 へクランプ）を設定する。
    public func settingAudioVolume(id: UUID, volume: Float) -> TimelineState {
        guard let index = audioItems.firstIndex(where: { $0.id == id }) else { return self }
        let clamped = min(max(volume, 0), 1)
        guard clamped != audioItems[index].volume else { return self }
        var next = self
        next.audioItems[index].volume = clamped
        return next
    }

    /// 指定した BGM のフェードイン／アウト時間（秒）を設定する（E2-2）。
    ///
    /// **上限は再生尺の半分**（`AudioItem.clampedFade` の doc）。それぞれ独立に丸めるので、
    /// 呼び出し側は「両方 duration/2 いっぱいまで」を渡してもぶつからない。
    public func settingAudioFade(id: UUID, fadeIn: Double, fadeOut: Double) -> TimelineState {
        guard let index = audioItems.firstIndex(where: { $0.id == id }) else { return self }
        let item = audioItems[index]
        let clampedIn = AudioItem.clampedFade(fadeIn, duration: item.duration)
        let clampedOut = AudioItem.clampedFade(fadeOut, duration: item.duration)
        guard clampedIn != item.fadeInDuration || clampedOut != item.fadeOutDuration else { return self }
        var next = self
        next.audioItems[index].fadeInDuration = clampedIn
        next.audioItems[index].fadeOutDuration = clampedOut
        return next
    }

    /// 合成尺で切った、実際に鳴る BGM だけを返す（表示と書き出しの唯一の入口）。
    ///
    /// **`audioItems` を直接 composition や帯へ渡さないこと。** クリップを消して縮んだ
    /// タイムラインの外へ挿入しにいく（`AudioItem.clipped(toTotalDuration:)` の doc 参照）。
    /// 適用区間における `MosaicApplyGate.effectiveRanges` と同じ役目である。
    public func effectiveAudioItems(totalDuration: Double) -> [AudioItem] {
        audioItems.compactMap { $0.clipped(toTotalDuration: totalDuration) }
    }

    /// BGM 列を不変条件（I-A1〜I-A3）へ正規化する。
    ///
    /// 1. `compositionStart` 昇順に並べ替える
    /// 2. 非有限・負の開始位置・最小長未満を落とす
    /// 3. 音量を 0...1 へクランプする
    /// 4. **重なりは後発の頭を削って詰める**（前の曲を優先。後ろへ押しのけない）
    ///
    /// 4 は最後の砦であって主たる防御ではない。編集操作の側がぶつからない位置へ
    /// クランプするのが本筋で、ここは手で書き換えられた下書き・将来の不整合が
    /// 実行系へ流れるのを止めるためにある。
    static func normalizedAudioItems(_ items: [AudioItem]) -> [AudioItem] {
        var result: [AudioItem] = []
        for item in items.sorted(by: { $0.compositionStart < $1.compositionStart }) {
            guard item.sourceStart.isFinite, item.sourceEnd.isFinite,
                  item.compositionStart.isFinite, item.compositionStart >= 0,
                  item.sourceStart >= 0,
                  item.duration >= AudioItem.minimumDuration else { continue }
            var next = item
            next.volume = min(max(item.volume, 0), 1)
            if let last = result.last, next.compositionStart < last.compositionEnd {
                let shift = last.compositionEnd - next.compositionStart
                next.compositionStart += shift
                next.sourceStart += shift
                guard next.duration >= AudioItem.minimumDuration else { continue }
            }
            // 最後の砦: 手で書き換えられた下書き・将来の不整合で fadeIn/Out が
            // duration/2 を超えていても、ここで必ず丸め直す。
            next.clampFades()
            result.append(next)
        }
        return result
    }
}
