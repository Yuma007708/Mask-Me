import Foundation

/// スクロールビューの現在の見え方（px 単位）。
///
/// **座標系は「トラック内 x」で統一する（`.padding(.horizontal, 16)` の内側）。**
/// つまり合成時刻 0 の位置が x = 0 であり、`TimelineGeometry.x(forTime:)` と同じ原点。
/// アプリ層は `scrollOffset = contentOffset.x - leadingInset`、
/// `contentWidth = トラック本体の幅（余白を含めない）` を渡すこと。
///
/// 先頭余白が見えている状態・ラバーバンドでは `scrollOffset` が負になり得るので
/// **符号は潰さない**（負にすると「余白ぶん戻っている」情報が消える）。
/// 幅は負を 0 に落とす（SwiftUI の frame に負値を渡さないための下流保護）。
public struct TimelineViewport: Equatable, Sendable {
    /// コンテンツ先頭（トラック内 x = 0）からの表示開始 px。負もあり得る。
    public let scrollOffset: Double
    /// 可視幅（px）。
    public let visibleWidth: Double
    /// コンテンツ全幅（px。トラック本体の幅）。
    public let contentWidth: Double

    public init(scrollOffset: Double, visibleWidth: Double, contentWidth: Double) {
        self.scrollOffset = scrollOffset.isFinite ? scrollOffset : 0
        self.visibleWidth = visibleWidth.isFinite ? max(0, visibleWidth) : 0
        self.contentWidth = contentWidth.isFinite ? max(0, contentWidth) : 0
    }

    /// スクロール可能量（px）。コンテンツが可視幅に収まるなら 0。
    public var scrollableWidth: Double { max(0, contentWidth - visibleWidth) }
}

/// タイムラインのスクロール・ズーム・サムネイル要求の算術（純関数）。
///
/// `TimelineViewGeometry.swift` が「時刻 ⇔ px」を持つのに対し、こちらは
/// **「スクロール位置と可視範囲」**を扱う。View 側に散らすと、ピンチ中の
/// アンカー保持やサムネイル予算の判断が毎回書き直されて壊れるため純ロジックへ寄せる。
///
/// ## 余白（`.padding(.horizontal, 16)`）の扱い
///
/// `zoomAnchor` → `scrollOffset` の往復では、先頭余白ぶんの定数は
/// `x(forTime:)` 側と `viewportX` 側の**両辺に等しく乗るので相殺される**
/// （アンカー保持だけなら余白を無視しても結果は変わらない）。
/// 一方 `visibleTimeRange` は `scrollOffset` を直接秒へ換算するため相殺されない。
/// **どちらも「トラック内 x」で渡す**のが唯一の正解。
public enum TimelineScrollMath {
    /// ピンチのズーム量子（既定 6%）。
    ///
    /// 連続ズームをそのまま反映すると 1 フレームごとに全帯のレイアウトが変わり、
    /// サムネイル枠の数まで毎回変わる。倍率を等比の刻みへ丸めることで、
    /// 見た目の滑らかさを保ったまま再レイアウト回数を落とす。
    public static let defaultZoomQuantumRatio: Double = 1.06

    // MARK: - 可視範囲

    /// 表示中の合成時刻レンジ。
    ///
    /// 先頭余白が見えている間は下限が負になる（そのまま返す。
    /// 「0 より前が見えている」という情報を持つのが呼び出し側に都合がよい）。
    public static func visibleTimeRange(viewport: TimelineViewport,
                                        geometry: TimelineGeometry) -> ClosedRange<Double> {
        let start = geometry.time(forX: viewport.scrollOffset)
        let end = geometry.time(forX: viewport.scrollOffset + viewport.visibleWidth)
        return start...max(start, end)
    }

    // MARK: - ズームのアンカー保持

    /// ズーム変更で保つアンカー。プレイヘッドが可視ならそれ、外なら可視中心。
    ///
    /// プレイヘッドを優先するのは「いま見ている再生位置を中心に拡大したい」が
    /// 支配的な操作だから。可視外のときに使うと画面が飛ぶので中心へ落とす。
    ///
    /// - Returns: `time` は合成時刻、`viewportX` は可視領域左端からの px
    ///   （`0...visibleWidth` にクランプ済み）。
    public static func zoomAnchor(playheadTime: Double,
                                  viewport: TimelineViewport,
                                  geometry: TimelineGeometry) -> (time: Double, viewportX: Double) {
        let visible = visibleTimeRange(viewport: viewport, geometry: geometry)
        if playheadTime.isFinite, visible.contains(playheadTime) {
            let offsetInViewport = geometry.x(forTime: playheadTime) - viewport.scrollOffset
            return (playheadTime, min(max(offsetInViewport, 0), viewport.visibleWidth))
        }
        let center = (visible.lowerBound + visible.upperBound) / 2
        return (center, viewport.visibleWidth / 2)
    }

    /// アンカーを保つために必要な新スクロール位置（px）。
    ///
    /// `0...max(0, contentWidth - visibleWidth)` へクランプする
    /// （余白の中まで戻す必要はないので下限は 0 でよい）。
    /// 非有限値はすべて 0 とみなす（NaN をスクロール位置に流すと
    /// `ScrollViewReader` が黙って無反応になる）。
    ///
    /// - Parameters:
    ///   - geometry: **ズーム変更後**の geometry を渡すこと（変更前を渡すと当然ずれる）。
    ///   - contentWidth: 変更後のコンテンツ全幅。
    public static func scrollOffset(anchorTime: Double,
                                    anchorViewportX: Double,
                                    geometry: TimelineGeometry,
                                    contentWidth: Double,
                                    visibleWidth: Double) -> Double {
        let anchorX = geometry.x(forTime: anchorTime)
        let viewportX = anchorViewportX.isFinite ? anchorViewportX : 0
        let content = contentWidth.isFinite ? max(0, contentWidth) : 0
        let visible = visibleWidth.isFinite ? max(0, visibleWidth) : 0
        let upperBound = max(0, content - visible)
        let raw = anchorX - viewportX
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), upperBound)
    }

    /// `ScrollViewReader.scrollTo(id, anchor:)` に渡す `UnitPoint.x`。
    ///
    /// iOS 16 には `scrollPosition` / `contentOffset` の直接指定が無く、
    /// スクロール位置を作れるのは「id + anchor」だけ。コンテンツ全体を 1 要素として
    /// 掴んでいる場合、スクロール量の割合がそのまま anchor の x になる。
    ///
    /// `f = scrollOffset / (contentWidth - visibleWidth)` を `0...1` へクランプ。
    /// スクロール不要（`contentWidth <= visibleWidth`）・非有限は 0。
    public static func anchorUnitPointX(scrollOffset: Double,
                                        contentWidth: Double,
                                        visibleWidth: Double) -> Double {
        guard scrollOffset.isFinite, contentWidth.isFinite, visibleWidth.isFinite else { return 0 }
        let scrollable = contentWidth - visibleWidth
        guard scrollable > 0 else { return 0 }
        let fraction = scrollOffset / scrollable
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    // MARK: - ピンチズーム

    /// ピンチ倍率 → 新 px/秒（連続値）。
    ///
    /// **iOS 16 では `MagnifyGesture`（`startLocation` 付き）が使えない**ため、
    /// ジェスチャからは倍率しか取れない。位置は呼び出し側が `zoomAnchor` で補う。
    ///
    /// 量子化は「倍率」に対して掛ける（絶対 px/秒 のグリッドへ吸着させると、
    /// ジェスチャ開始時 `magnification == 1` でも値が跳ぶ）。
    /// そのため `magnification == 1` は必ず `base` そのもの（クランプのみ）を返す。
    ///
    /// - Parameters:
    ///   - base: ジェスチャ開始時点の px/秒。
    ///   - magnification: `MagnificationGesture` の倍率（1 が等倍）。
    ///     非有限・0 以下は等倍として扱う。
    ///   - quantumRatio: 量子の比。1 以下・非有限なら量子化しない。
    public static func pixelsPerSecond(base: Double,
                                       magnification: Double,
                                       quantumRatio: Double = defaultZoomQuantumRatio) -> Double {
        let clampedBase = TimelineGeometry.clampedPixelsPerSecond(base)
        guard magnification.isFinite, magnification > 0 else { return clampedBase }
        guard quantumRatio.isFinite, quantumRatio > 1 else {
            return clampedZoom(clampedBase * magnification, magnification: magnification)
        }
        let steps = (log(magnification) / log(quantumRatio)).rounded()
        guard steps.isFinite else { return clampedBase }
        return clampedZoom(clampedBase * pow(quantumRatio, steps), magnification: magnification)
    }

    /// オーバーフローした倍率を「拡大なら最大段・縮小なら最小段」へ寄せる。
    /// `TimelineGeometry.clampedPixelsPerSecond` は非有限を既定段（40）に落とすため、
    /// そのまま通すと 1e300 倍のピンチが縮小として現れる。
    private static func clampedZoom(_ raw: Double, magnification: Double) -> Double {
        if raw.isFinite { return TimelineGeometry.clampedPixelsPerSecond(raw) }
        return magnification >= 1
            ? TimelineGeometry.maximumPixelsPerSecond
            : TimelineGeometry.minimumPixelsPerSecond
    }

    // MARK: - 並べ替え中の自動スクロール

    /// 並べ替えドラッグ中の自動スクロール速度（px/秒。正が右送り）。
    ///
    /// 端から `edgeInset` 以内で線形に立ち上がり、端で `maximumSpeed` になる。
    /// 段階的（0 か最大か）にすると指を止めた位置で速度が跳ぶため線形にする。
    ///
    /// `edgeInset * 2 > visibleWidth` のときは `visibleWidth / 2` まで詰める
    /// （左右の帯が重なると中央でも自動スクロールが止まらなくなる）。
    /// 非有限・0 以下の入力はすべて「自動スクロールしない（0）」。
    ///
    /// - Parameter fingerX: 可視領域左端からの指の x（px）。
    public static func autoScrollVelocity(fingerX: Double,
                                          visibleWidth: Double,
                                          edgeInset: Double,
                                          maximumSpeed: Double) -> Double {
        guard fingerX.isFinite, visibleWidth.isFinite, visibleWidth > 0,
              edgeInset.isFinite, edgeInset > 0,
              maximumSpeed.isFinite, maximumSpeed > 0 else { return 0 }
        let inset = min(edgeInset, visibleWidth / 2)
        guard inset > 0 else { return 0 }
        if fingerX < inset {
            return -maximumSpeed * min(1, (inset - fingerX) / inset)
        }
        let trailingEdge = visibleWidth - inset
        if fingerX > trailingEdge {
            return maximumSpeed * min(1, (fingerX - trailingEdge) / inset)
        }
        return 0
    }
}

// MARK: - サムネイル要求の計画

/// サムネイル 1 枠ぶんの生成要求。
public struct TimelineThumbnailSlotRequest: Equatable, Sendable {
    public let clipID: UUID
    public let sourceID: UUID
    /// 枠中心の素材時刻（秒）。`TimelineThumbnailLayout.slots` と同じ値。
    public let sourceTime: Double
    /// 小さいほど先に生成すべき。可視中心からの距離（秒）。
    public let priority: Double

    public init(clipID: UUID, sourceID: UUID, sourceTime: Double, priority: Double) {
        self.clipID = clipID
        self.sourceID = sourceID
        self.sourceTime = sourceTime
        self.priority = priority
    }
}

/// 可視範囲からサムネイル生成要求を組み立てる（純関数）。
///
/// **素材時刻は必ず `TimelineThumbnailLayout.slots` を経由して出す。**
/// 描画側（`TimelineClipBandView`）と別式で出すと、要求したキーと描画で引くキーが
/// ずれて「生成済みなのに帯が灰色のまま」になる。
public enum TimelineThumbnailPlanner {
    /// 可視レンジの前後に余分に読む割合（可視レンジ長に対する比）。
    public static let defaultMarginFactor: Double = 0.5

    /// 可視レンジ ± margin に入る枠を、可視中心に近い順で返す。
    ///
    /// **件数の上限はここで掛けない。** キャッシュ済みを除外する前に切ると、
    /// 先頭 2 クリップが予算を食い切って 3 本目以降が永久に要求されない
    /// （`VideoTimelineView.refreshThumbnailRequests` のコメントにある実測バグ）。
    /// 上限はアプリ層が `needsGeneration` で絞ってから掛けること。
    ///
    /// 返す `sourceTime` は素材使用範囲へのクランプ済み（`slots` の仕様）だが、
    /// **素材実尺でのクランプ（`TimelineState.clampedSourceTime`）は掛けていない**。
    /// キャッシュキーを揃えるため、アプリ層が要求前に同じクランプを通すこと。
    ///
    /// - Parameters:
    ///   - layouts: `TimelineBandLayout.clipLayouts(mapping:)` の結果。
    ///   - clips: `layouts` の `clipID` を引くための現在のクリップ列。
    ///   - visibleRange: `visibleTimeRange(viewport:geometry:)` の結果（合成時刻）。
    ///   - marginFactor: 先読み割合。負・非有限は 0 として扱う。
    ///   - sourceDurations: 素材実尺（sourceID → 秒）。外向きトリムのプレビューで
    ///     `slots` が現行 `sourceEnd` より先のコマを引けるようにするために渡す。
    public static func plan(layouts: [TimelineClipLayout],
                            clips: [TimelineClip],
                            geometry: TimelineGeometry,
                            visibleRange: ClosedRange<Double>,
                            marginFactor: Double = defaultMarginFactor,
                            preferredSlotWidth: Double = 44,
                            sourceDurations: [UUID: Double]) -> [TimelineThumbnailSlotRequest] {
        guard !layouts.isEmpty, !clips.isEmpty else { return [] }
        let span = max(0, visibleRange.upperBound - visibleRange.lowerBound)
        let factor = marginFactor.isFinite ? max(0, marginFactor) : 0
        let margin = span * factor
        let lower = visibleRange.lowerBound - margin
        let upper = visibleRange.upperBound + margin
        let center = (visibleRange.lowerBound + visibleRange.upperBound) / 2
        var indexed: [(order: Int, request: TimelineThumbnailSlotRequest)] = []

        for layout in layouts {
            guard layout.bandEnd >= lower, layout.bandStart <= upper,
                  let clip = clips.first(where: { $0.id == layout.clipID }) else { continue }
            let slots = TimelineThumbnailLayout.slots(
                clip: clip,
                spanStart: layout.spanStart,
                band: CompositionInterval(start: layout.bandStart, end: layout.bandEnd),
                geometry: geometry,
                preferredSlotWidth: preferredSlotWidth,
                sourceDuration: sourceDurations[clip.sourceID])
            let slotDuration = geometry.duration(forWidth: slots.slotWidth)
            for (slot, sourceTime) in slots.sourceTimes.enumerated() {
                let slotCenter = layout.bandStart + (Double(slot) + 0.5) * slotDuration
                guard slotCenter >= lower, slotCenter <= upper else { continue }
                indexed.append((indexed.count,
                                TimelineThumbnailSlotRequest(clipID: layout.clipID,
                                                             sourceID: layout.sourceID,
                                                             sourceTime: sourceTime,
                                                             priority: abs(slotCenter - center))))
            }
        }
        // 同順位はタイムライン順で安定させる（Swift の sort は非安定）。
        return indexed
            .sorted { $0.request.priority == $1.request.priority
                ? $0.order < $1.order
                : $0.request.priority < $1.request.priority }
            .map(\.request)
    }
}
