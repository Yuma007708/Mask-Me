import Foundation

/// タイムライン UI の座標変換と配置計算（純ロジック）。
///
/// **なぜコア層に置くか**: S9 のタイムライン UI では 4 つの時間表現が同居する。
///
/// 1. 合成時刻（秒。トランジションの重なり込み = `TimelineMapping` の表示タイムライン）
/// 2. 素材時刻（秒。検出キャッシュ・`MosaicApplyRange` のアンカー）
/// 3. 0〜1 正規化位置（`MosaicEditorModel.playbackPosition`）
/// 4. ピクセル（スクロールビュー内の x 座標）
///
/// View にこの算術を散らすと、どの表現の値かが型で区別できないまま混ざる。
/// **UI が直接触れてよい変換は 3⇔4 と「合成時刻→帯の配置」だけ**にし、
/// それらをこのファイルの純関数へ閉じ込める（2 が絡む写像は `TimelineMapping` /
/// `MosaicApplyGate` が引き続き単一情報源）。
public struct TimelineGeometry: Equatable, Sendable {
    /// ズーム段（px/秒）。
    ///
    /// **決め方**: 1 秒あたりの幅がタップ目標（44pt）を大きく割らないことを下限の目安にし、
    /// かつ長尺でもスクロール量が現実的になるよう 2 倍刻みの段で持つ。
    /// - 10 px/秒: 400pt 幅の画面に約 40 秒が収まる（全体把握用）
    /// - 40 px/秒（既定）: 1 秒 = 40pt。分割・トリムの指先精度が 25ms 程度になる
    /// - 160 px/秒: 1 フレーム（1/30 秒）が約 5pt。細かいトリム用
    ///
    /// 可視幅に合わせた自動フィットは採らない（幅の変化＝回転やキーボード表示のたびに
    /// 倍率が変わると、ドラッグ中の px→秒 換算が途中で変わって操作が飛ぶため）。
    public static let zoomLevels: [Double] = [10, 20, 40, 80, 160]
    /// 既定のズーム段（px/秒）。
    public static let defaultPixelsPerSecond: Double = 40

    public static var minimumPixelsPerSecond: Double { zoomLevels[0] }
    public static var maximumPixelsPerSecond: Double { zoomLevels[zoomLevels.count - 1] }

    /// 1 秒あたりのピクセル数。`zoomLevels` の範囲へクランプ済み。
    public let pixelsPerSecond: Double

    public init(pixelsPerSecond: Double = TimelineGeometry.defaultPixelsPerSecond) {
        self.pixelsPerSecond = Self.clampedPixelsPerSecond(pixelsPerSecond)
    }

    /// px/秒 を許容範囲へクランプする。NaN は既定段に落とす
    /// （`TimelineClip.clampedRate` と同じ流儀。NaN は min/max を素通りして
    /// レイアウト全体を NaN 汚染する）。
    public static func clampedPixelsPerSecond(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPixelsPerSecond }
        return min(max(value, minimumPixelsPerSecond), maximumPixelsPerSecond)
    }

    // MARK: - px ⇔ 秒

    /// 合成時刻（秒）→ トラック内 x 座標（px）。
    public func x(forTime seconds: Double) -> Double {
        seconds.isFinite ? seconds * pixelsPerSecond : 0
    }

    /// トラック内 x 座標（px）→ 合成時刻（秒）。
    public func time(forX x: Double) -> Double {
        x.isFinite ? x / pixelsPerSecond : 0
    }

    /// 尺（秒）→ 幅（px）。負の尺は 0 幅に落とす（SwiftUI の frame に負値を渡さない）。
    public func width(forDuration seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds * pixelsPerSecond
    }

    /// 幅（px）→ 尺（秒）。
    public func duration(forWidth width: Double) -> Double {
        guard width.isFinite, width > 0 else { return 0 }
        return width / pixelsPerSecond
    }

    // MARK: - 目盛り

    /// 目盛り間隔の候補（秒）。
    public static let tickIntervalCandidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
    /// 目盛りラベルが重ならない最小間隔（px）。"0:00" 相当のラベル幅から決めた。
    public static let minimumTickSpacing: Double = 36

    /// 目盛りの最大本数。長尺 × 高倍率で目盛りビューが数千個になると描画が詰まるため、
    /// これを超える場合は間隔を倍々にして本数を抑える。
    public static let maximumTicks = 400

    /// 現在のズーム段で使う目盛り間隔（秒）。
    /// 候補のうち「px 換算で `minimumTickSpacing` 以上になる最小のもの」を選ぶ。
    public var tickInterval: Double {
        Self.tickIntervalCandidates.first { $0 * pixelsPerSecond >= Self.minimumTickSpacing }
            ?? Self.tickIntervalCandidates[Self.tickIntervalCandidates.count - 1]
    }

    /// 実際に描く目盛り間隔（秒）。本数が `maximumTicks` に収まるまで倍々に粗くする。
    ///
    /// **描く側とプレイヘッド追従の側が同じ値を使うこと**（別々に計算すると
    /// `scrollTo` の対象 id が存在せず追従が黙って止まる）。
    public func effectiveTickInterval(totalDuration: Double) -> Double {
        var interval = tickInterval
        guard totalDuration.isFinite, totalDuration > 0, interval > 0 else { return interval }
        while totalDuration / interval > Double(Self.maximumTicks) { interval *= 2 }
        return interval
    }

    // MARK: - ズーム段の移動

    /// 一段拡大する（最大段では自分自身を返す）。
    public func zoomedIn() -> TimelineGeometry {
        let next = Self.zoomLevels.first { $0 > pixelsPerSecond }
        return TimelineGeometry(pixelsPerSecond: next ?? pixelsPerSecond)
    }

    /// 一段縮小する（最小段では自分自身を返す）。
    public func zoomedOut() -> TimelineGeometry {
        let previous = Self.zoomLevels.last { $0 < pixelsPerSecond }
        return TimelineGeometry(pixelsPerSecond: previous ?? pixelsPerSecond)
    }
}

/// クリップ帯 1 本ぶんの配置（合成時刻の区間）。
public struct TimelineClipLayout: Equatable, Sendable, Identifiable {
    public let clipID: UUID
    public let sourceID: UUID
    /// クリップ列内での位置（`moveClip(id:toIndex:)` に渡せる index）。
    public let index: Int
    /// 合成タイムライン上のクリップ区間（トランジションの重なり込み）。
    public let spanStart: Double
    public let spanEnd: Double
    /// 帯として描く区間。重なりは**先行クリップが占有**し、後続クリップの帯は
    /// 重なりの終了時刻から始まる（帯どうしを重ねて描かないため）。
    public let bandStart: Double
    public let bandEnd: Double

    public var id: UUID { clipID }
    public var bandDuration: Double { max(0, bandEnd - bandStart) }
    /// クリップの合成尺（帯の幅ではなく、rate 適用後の本来の尺）。
    public var spanDuration: Double { max(0, spanEnd - spanStart) }

    public init(clipID: UUID, sourceID: UUID, index: Int,
                spanStart: Double, spanEnd: Double,
                bandStart: Double, bandEnd: Double) {
        self.clipID = clipID
        self.sourceID = sourceID
        self.index = index
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.bandStart = bandStart
        self.bandEnd = bandEnd
    }
}

/// クリップ間の継ぎ目 1 箇所ぶんの配置。
public struct TimelineJointLayout: Equatable, Sendable, Identifiable {
    /// 先行クリップの id（`TimelineState.transitions` のキーでもある）。
    public let outgoingClipID: UUID
    public let incomingClipID: UUID
    /// 継ぎ目の中心時刻（合成時刻）。トランジションがあれば重なりの中心。
    public let time: Double
    /// 設定済みトランジションの種類。未設定（またはクランプ結果 0）は nil。
    public let kind: TransitionKind?
    /// 実効的な重なり長（秒）。未設定なら 0。
    public let duration: Double

    public var id: UUID { outgoingClipID }

    public init(outgoingClipID: UUID, incomingClipID: UUID,
                time: Double, kind: TransitionKind?, duration: Double) {
        self.outgoingClipID = outgoingClipID
        self.incomingClipID = incomingClipID
        self.time = time
        self.kind = kind
        self.duration = duration
    }
}

/// モザイク適用区間 1 本を、それが属するクリップへ写した合成時刻の区間。
///
/// **1 本の `MosaicApplyRange` は最大 1 つのセグメントにしか写らない（不変条件 I2）。**
/// 区間は `clipID` アンカー（S11）であり、`clipID` は一意だからである。
/// 旧仕様（素材アンカーのみ）では同じ素材を使うクリップの数だけセグメントが現れた。
public struct TimelineApplySpan: Equatable, Sendable, Identifiable {
    public let rangeID: UUID
    public let clipID: UUID
    public let start: Double
    public let end: Double
    /// 端ドラッグ（区間の伸縮）を受け付けるか。
    ///
    /// 写真クリップでは false。写真の素材時刻は `TimelineState.clampedSourceTime` が
    /// 常に 0 へ丸めるため適用区間は必ずクリップ全体 [0, sourceEnd) になり、
    /// `MosaicApplyGate.ranges(replacingRangeID:clipID:...)` の許容誤差判定が常に一致して
    /// **必ず no-op になる**（指を離すと帯が元へ戻るだけで、エラーも無効化表示も出ない）。
    /// UI 側でハンドル自体を出さないことで、この構造的な no-op を明示する。
    public let isEdgeAdjustable: Bool

    public var id: String { "\(rangeID.uuidString)/\(clipID.uuidString)" }
    public var duration: Double { max(0, end - start) }

    public init(rangeID: UUID, clipID: UUID, start: Double, end: Double,
                isEdgeAdjustable: Bool = true) {
        self.rangeID = rangeID
        self.clipID = clipID
        self.start = start
        self.end = end
        self.isEdgeAdjustable = isEdgeAdjustable
    }
}

/// トリムする端。
public enum TimelineTrimEdge: String, Sendable, CaseIterable {
    case start
    case end
}

/// タイムライン UI の配置計算（純関数）。
public enum TimelineBandLayout {
    /// クリップ帯の配置列（タイムライン順）。
    ///
    /// 帯は隣どうしが**接するが重ならない**。トランジションの重なり区間は
    /// 先行クリップの帯が占有し、後続クリップの帯は重なり終了から始まる。
    /// `duration <= min(両クリップ尺)/2` の制約により、後続の帯は必ず
    /// 自身の合成尺の半分以上を保つ（帯が消えることはない）。
    public static func clipLayouts(mapping: TimelineMapping) -> [TimelineClipLayout] {
        let spans = mapping.clipSpans
        return spans.enumerated().map { index, span in
            let overlapEnd = mapping.overlaps.first { $0.incomingClipID == span.clip.id }?.end
            return TimelineClipLayout(clipID: span.clip.id,
                                      sourceID: span.clip.sourceID,
                                      index: index,
                                      spanStart: span.start,
                                      spanEnd: span.end,
                                      bandStart: overlapEnd ?? span.start,
                                      bandEnd: span.end)
        }
    }

    /// クリップ間の継ぎ目の配置列（クリップが N 本なら N-1 件）。
    ///
    /// トランジションの有無は `mapping.overlaps`（合成の単一情報源）から引く。
    /// クランプ結果 0 のトランジションは `overlaps` に載らないため、UI でも
    /// 「未設定」として扱われる（合成結果と表示が食い違わない）。
    public static func jointLayouts(mapping: TimelineMapping) -> [TimelineJointLayout] {
        let spans = mapping.clipSpans
        guard spans.count >= 2 else { return [] }
        return (0..<(spans.count - 1)).map { index in
            let outgoing = spans[index].clip
            let incoming = spans[index + 1].clip
            if let overlap = mapping.overlaps.first(where: { $0.outgoingClipID == outgoing.id }) {
                return TimelineJointLayout(outgoingClipID: outgoing.id,
                                           incomingClipID: incoming.id,
                                           time: (overlap.start + overlap.end) / 2,
                                           kind: overlap.kind,
                                           duration: overlap.duration)
            }
            return TimelineJointLayout(outgoingClipID: outgoing.id,
                                       incomingClipID: incoming.id,
                                       time: spans[index].end,
                                       kind: nil,
                                       duration: 0)
        }
    }

    /// 素材時刻アンカーの適用区間を、合成時刻の区間へ写す（表示用）。
    ///
    /// `MosaicApplyGate.ranges(addingCompositionInterval:)` の逆写像にあたる。
    /// クリップの使用範囲と交差しない区間は結果に現れない。
    /// 結果はクリップのタイムライン順で並ぶ。
    ///
    /// **交差判定は `MosaicApplyGate.clippedInterval(clip:range:)` を呼ぶ**
    /// （`effectiveRanges` と bit 同一。不変条件 I3）。これにより
    /// 「帯が n 本 ⇔ 有効区間が n 個」「帯 0 本 ⇔ ゲートが全区間 OFF」（I1）が成り立つ。
    /// 式をここへ書き写さないこと。
    ///
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合。該当クリップのセグメントは
    ///   `isEdgeAdjustable == false`（端ドラッグが構造的に no-op になるため。
    ///   `TimelineApplySpan.isEdgeAdjustable` の doc 参照）。
    ///   **既定値は必須**（`VideoTimelineView` の既存呼び出しを壊さないため）。
    public static func applySpans(ranges: [MosaicApplyRange],
                                  mapping: TimelineMapping,
                                  photoSourceIDs: Set<UUID> = []) -> [TimelineApplySpan] {
        var result: [TimelineApplySpan] = []
        for span in mapping.clipSpans {
            let clip = span.clip
            for range in ranges {
                guard let clipped = MosaicApplyGate.clippedInterval(clip: clip, range: range) else { continue }
                result.append(TimelineApplySpan(
                    rangeID: range.id,
                    clipID: clip.id,
                    start: span.start + (clipped.start - clip.sourceStart) / clip.rate,
                    end: span.start + (clipped.end - clip.sourceStart) / clip.rate,
                    isEdgeAdjustable: !photoSourceIDs.contains(clip.sourceID)))
            }
        }
        return result
    }

    /// 端ドラッグ後のクリップ使用範囲（素材時刻）。
    ///
    /// ドラッグ量は**合成時刻の差分**で受け取り、`rate` を掛けて素材時刻の差分に写す
    /// （2x のクリップでは帯を 1 秒縮めると素材は 2 秒縮む）。
    /// 結果は「最小合成尺（`TimelineEditOperations.minimumClipDuration`）を割らない」
    /// 範囲へクランプするため、ドラッグが行き過ぎても操作が無反応にならず端で止まる。
    ///
    /// **クランプ可能域が空のクリップでは端トリムを拒否して元の範囲を返す。**
    /// クランプの上下限は「最小合成尺を残す」制約から作るので、合成尺が既に最小尺を
    /// 割っているクリップ（`.start` 側）や素材末尾に張り付いたクリップ（`.end` 側）では
    /// 上限 < 下限になる。そのまま `min` / `max` を掛けると**ドラッグと逆方向へ端が飛ぶ**:
    /// 実測では 10x のクリップ（合成尺 0.05 秒）の左ハンドルを右へ 0.025 秒動かすと
    /// `sourceStart` が 9.5 → 9.0 へ落ち、前クリップと素材使用範囲が重複した。
    /// `MosaicEditorModel.trimClip` のクランプは `sourceEnd` 側だけなので素通しする。
    ///
    /// - Parameter sourceDuration: 素材の実尺（分かる場合）。`end` 側の上限に使う。
    public static func trimmedBounds(clip: TimelineClip,
                                     edge: TimelineTrimEdge,
                                     deltaCompositionSeconds delta: Double,
                                     sourceDuration: Double?) -> (sourceStart: Double, sourceEnd: Double) {
        let original = (sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
        guard delta.isFinite else { return original }
        let minimumSourceSpan = TimelineEditOperations.minimumClipDuration * clip.rate
        switch edge {
        case .start:
            let upperBound = clip.sourceEnd - minimumSourceSpan
            guard upperBound >= 0, upperBound >= clip.sourceStart else { return original }
            let raw = clip.sourceStart + delta * clip.rate
            return (min(max(raw, 0), upperBound), clip.sourceEnd)
        case .end:
            let lowerBound = clip.sourceStart + minimumSourceSpan
            var upperBound = Double.infinity
            if let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 {
                upperBound = sourceDuration
            }
            guard lowerBound <= upperBound else { return original }
            let raw = clip.sourceEnd + delta * clip.rate
            return (clip.sourceStart, min(max(raw, lowerBound), upperBound))
        }
    }

    /// 長押しドラッグ中のクリップを差し込むべき index。
    ///
    /// ドラッグ中クリップの帯の**中心**が移動後にどの帯へ入ったかで判定する
    /// （指の位置ではなく中心を使うことで、掴んだ場所によらず挙動が一定になる）。
    /// 端をはみ出した場合は先頭・末尾へ寄せる。`clipID` が無ければ nil。
    public static func reorderTargetIndex(layouts: [TimelineClipLayout],
                                          clipID: UUID,
                                          translationSeconds: Double) -> Int? {
        guard let current = layouts.first(where: { $0.clipID == clipID }),
              translationSeconds.isFinite, !layouts.isEmpty else { return nil }
        let center = (current.bandStart + current.bandEnd) / 2 + translationSeconds
        if let hit = layouts.firstIndex(where: { center >= $0.bandStart && center < $0.bandEnd }) {
            return layouts[hit].index
        }
        guard let first = layouts.first, let last = layouts.last else { return nil }
        return center < first.bandStart ? first.index : last.index
    }
}

/// クリップ帯 1 本ぶんのサムネイル枠の配置。
public struct TimelineThumbnailSlots: Equatable, Sendable {
    /// 枠の数（1 以上）。
    public let count: Int
    /// 枠 1 つの幅（px）。帯をちょうど埋めるよう `preferredSlotWidth` から調整される。
    public let slotWidth: Double
    /// 各枠の中心に対応する素材時刻（秒。クリップの使用範囲内へクランプ済み）。
    public let sourceTimes: [Double]

    public init(count: Int, slotWidth: Double, sourceTimes: [Double]) {
        self.count = count
        self.slotWidth = slotWidth
        self.sourceTimes = sourceTimes
    }
}

/// サムネイル枠の配置計算。
///
/// **描画（`TimelineClipBandView`）と生成要求（`VideoTimelineView`）が同じ関数を使うこと。**
/// 別々に計算すると要求したキーと描画で引くキーがずれ、生成済みなのに帯が
/// 灰色のまま、という状態になる。
public enum TimelineThumbnailLayout {
    /// 1 クリップあたりのサムネイル枠の上限。
    ///
    /// 長尺 × 高倍率では帯の幅が数万 px になり、枠を素直に並べると 1 クリップで
    /// 数千ビューになる（SwiftUI の `ForEach` は遅延生成しない）。上限を超える場合は
    /// 枠を広げて数を抑える（コマは粗くなるが描画は詰まらない）。
    public static let maximumSlotsPerClip = 60

    /// 素材時刻は `bandOffset = band.start - spanStart` を基準に `clip.sourceStart` から測る。
    ///
    /// **トリム中のプレビューでは「下書きを適用したクリップ」と `spanStart: band.start` を
    /// 渡すこと**（`TimelineClipBandView.previewClip`）。`clip` を未編集のまま渡すと
    /// `.start` 側の外向きトリムで帯に出るコマと確定後に入る映像が食い違う:
    /// `.start` のプレビューは `band.start` を動かさず右端だけ伸ばすので `bandOffset` は
    /// 常に 0 のままで、帯には現行 `sourceStart` から**先**のコマが並ぶのに、実際に
    /// 足されるのは `sourceStart` より**前**の素材になる。下書き適用済みクリップを渡せば
    /// `.start` / `.end` のどちらでもコマと実際の映像が一致する。
    ///
    /// - Parameters:
    ///   - spanStart: 素材時刻の原点にする合成時刻。通常は `TimelineClipLayout.spanStart`、
    ///     プレビューでは `band.start`（＝ `bandOffset` を 0 にする）。
    ///   - band: 実際に描く帯の合成時刻区間（トリム中のプレビューでは差し替わる）。
    ///   - sourceDuration: 素材の実尺（分かる場合）。`.end` 側の外向きトリムでは
    ///     `band` が現行の合成区間を超えて伸びるため、素材時刻の上限を `clip.sourceEnd`
    ///     に固定すると伸ばした領域の全枠が現行 `sourceEnd` の 1 コマに張り付く
    ///     （実測: 6 枠中 4 枠が同一コマ）。この値を渡すと素材実尺まで先のコマを引ける。
    ///     nil のときは `clip.sourceEnd` が上限。
    public static func slots(clip: TimelineClip,
                             spanStart: Double,
                             band: CompositionInterval,
                             geometry: TimelineGeometry,
                             preferredSlotWidth: Double,
                             sourceDuration: Double? = nil) -> TimelineThumbnailSlots {
        let width = geometry.width(forDuration: band.end - band.start)
        let preferred = preferredSlotWidth.isFinite && preferredSlotWidth > 0 ? preferredSlotWidth : 44
        let ideal = width > 0 ? Int((width / preferred).rounded(.up)) : 1
        let count = max(1, min(ideal, maximumSlotsPerClip))
        let slotWidth = max(width, 1) / Double(count)
        let slotDuration = geometry.duration(forWidth: slotWidth)
        let bandOffset = band.start - spanStart
        var ceiling = clip.sourceEnd
        if let sourceDuration, sourceDuration.isFinite, sourceDuration > ceiling { ceiling = sourceDuration }
        let upperBound = max(clip.sourceStart, ceiling.nextDown)
        let times = (0..<count).map { slot -> Double in
            let offsetInSpan = bandOffset + (Double(slot) + 0.5) * slotDuration
            let raw = clip.sourceStart + offsetInSpan * clip.rate
            return min(max(raw, clip.sourceStart), upperBound)
        }
        return TimelineThumbnailSlots(count: count, slotWidth: slotWidth, sourceTimes: times)
    }
}

/// 速度スライダーの対数スケール変換。
///
/// スライダー値 0...1 を `TimelineClip.rateRange`（0.1x〜10x）へ **log10 で等間隔**に写す。
/// 線形スケールだと 1x 未満（0.1〜1）が全体の 1 割しか占めず、スロー側がまともに
/// 操作できない。対数なら 0.5 がちょうど 1.0x になり、0.1x と 10x が対称に並ぶ。
public enum TimelineRateScale {
    private static var logLowerBound: Double { log10(TimelineClip.rateRange.lowerBound) }
    private static var logUpperBound: Double { log10(TimelineClip.rateRange.upperBound) }

    /// そのクリップに UI から設定してよい再生倍率の上限。
    ///
    /// 合成尺 = 素材使用尺 / rate なので rate を上げるほど帯は縮む。
    /// 合成尺が `TimelineEditOperations.minimumClipDuration` を割ったクリップは
    /// **端トリムを一切受け付けられなくなる**（`TimelineBandLayout.trimmedBounds` が
    /// クランプ可能域が空になるため元の範囲を返す）。
    ///
    /// `TimelineEditOperations.setRate` 側にこの制約は入れていない（S1 で確立した
    /// 「rate は `rateRange` にクランプするだけ」という契約を既存テストが固定しており、
    /// 下書き復元・undo で入ってくる値まで拒否すると状態が復元できなくなる）。
    /// 代わりに**倍率を選ぶ UI がここを上限にする**ことで到達させない。
    ///
    /// 素材使用尺が壊れている（非有限・0 以下）クリップでは等速を返す。
    public static func maximumRate(forClip clip: TimelineClip) -> Double {
        let span = clip.sourceEnd - clip.sourceStart
        guard span.isFinite, span > 0 else { return 1.0 }
        let cap = span / TimelineEditOperations.minimumClipDuration
        guard cap.isFinite else { return TimelineClip.rateRange.upperBound }
        return min(max(cap, TimelineClip.rateRange.lowerBound), TimelineClip.rateRange.upperBound)
    }

    /// スライダー値（0...1）→ 再生倍率。範囲外・NaN は等速側へ寄せてクランプする。
    public static func rate(forSliderValue value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(max(value, 0), 1)
        return TimelineClip.clampedRate(pow(10, logLowerBound + (logUpperBound - logLowerBound) * clamped))
    }

    /// 再生倍率 → スライダー値（0...1）。`rate(forSliderValue:)` の逆写像。
    public static func sliderValue(forRate rate: Double) -> Double {
        let clamped = TimelineClip.clampedRate(rate)
        let value = (log10(clamped) - logLowerBound) / (logUpperBound - logLowerBound)
        return value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}
