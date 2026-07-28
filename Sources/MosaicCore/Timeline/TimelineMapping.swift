import Foundation

/// 合成タイムライン上の時刻と、素材内の時刻を相互変換する。
///
/// この変換を一箇所に閉じ込めることで、既存の時刻ベース API
/// （`lookupFaces(at:)` など）の呼び出し側の構造を変えずに済む。
public struct TimelineMapping: Sendable {
    /// 合成時刻がどのクリップのどの素材時刻に対応するかを表す。
    public struct SourceLocation: Equatable, Sendable {
        public let clipID: UUID
        public let sourceID: UUID
        /// 素材内での時刻（秒）。
        public let time: Double

        public init(clipID: UUID, sourceID: UUID, time: Double) {
            self.clipID = clipID
            self.sourceID = sourceID
            self.time = time
        }
    }

    /// トランジションの重なりを考慮した素材位置（`sourceLocations(at:)` の要素）。
    public struct SourceLocationInTransition: Equatable, Sendable {
        public let location: SourceLocation
        /// 重なり内での役割（先行/後続）。重なり外の単独クリップでは nil。
        public let side: TransitionSide?
        /// 重なり内での進行度（0..1）。重なり外では nil。
        /// S8 はこの値をそのまま `TransitionKind.parameters(progress:side:)` /
        /// `transformPoint(_:progress:side:)` に渡す。
        public let progress: Double?

        public init(location: SourceLocation, side: TransitionSide?, progress: Double?) {
            self.location = location
            self.side = side
            self.progress = progress
        }
    }

    /// クリップと、その合成タイムライン上の区間。
    /// `MosaicApplyGate` の合成時刻区間 → 素材区間の分解などが使う。
    public struct ClipSpan: Equatable, Sendable {
        public let clip: TimelineClip
        /// 合成タイムライン上の開始時刻。
        public let start: Double
        /// 合成タイムライン上の終了時刻（半開区間 [start, end) の外側）。
        public var end: Double { start + clip.duration }

        public init(clip: TimelineClip, start: Double) {
            self.clip = clip
            self.start = start
        }
    }

    /// 隣接する 2 クリップの実効的な重なり（トランジション適用後）。
    ///
    /// **合成タイムラインの重なりモデルの単一情報源**である。S8 の
    /// `TimelineCompositionBuilder`（A/B トラック交互配置）と
    /// `VideoCompositionFactory`（instruction のランプ範囲）は、重なりの開始時刻・
    /// 長さ・種類をここからしか取らない（builder 側で独自にクランプ計算を持つと、
    /// 顔位置の写像とフレームの合成がずれてモザイクが漏れる）。
    public struct Overlap: Equatable, Sendable {
        /// 先行（画面から抜ける）クリップの id。`TimelineState.transitions` のキーでもある。
        public let outgoingClipID: UUID
        /// 後続（画面に入る）クリップの id。
        public let incomingClipID: UUID
        public let kind: TransitionKind
        /// 合成タイムライン上の重なり開始時刻（= 後続クリップの開始時刻）。
        public let start: Double
        /// 合成タイムライン上の重なり終了時刻（= **先行クリップの `ClipSpan.end` そのもの**。
        /// 半開区間 [start, end) の外側）。
        ///
        /// **`start + duration` で作らないこと。** `start` は「先行クリップ終端 − D」を
        /// 丸めた値なので、そこへ D を足し戻しても先行クリップ終端と bit 一致しない
        /// （実測で ±1.11e-16 秒ずれる）。ずれた 1 フレームでは `overlap(at:)` と
        /// `sourceLocations(at:)` の重なり判定が食い違い、重なり中なのに片側キャッシュ
        /// 経路へ落ちる（＝ライブ検出の抑止も外れ、合成済みフレームの検出結果が素材キーで
        /// 書かれうる）。同じ値を 2 通りに計算しないため、`end` は先行クリップの span 終端を
        /// そのまま持つ。
        public let end: Double
        /// クランプ後の実効的な重なり長（秒）。`end − start` の派生値であり、
        /// 進行度（progress）の分母として `sourceLocations(at:)` と
        /// `VideoCompositionFactory` の両方がこれを使う（分母を別々に作らない）。
        /// 0 のトランジションは `overlaps` に載らない。
        public var duration: Double { end - start }

        public init(outgoingClipID: UUID, incomingClipID: UUID,
                    kind: TransitionKind, start: Double, end: Double) {
            self.outgoingClipID = outgoingClipID
            self.incomingClipID = incomingClipID
            self.kind = kind
            self.start = start
            self.end = end
        }
    }

    /// クリップと、その合成タイムライン上の開始位置。
    private struct Entry {
        let clip: TimelineClip
        let start: Double
        var end: Double { start + clip.duration }
    }

    private let entries: [Entry]
    public let totalDuration: Double
    /// トランジションによる実効的な重なり（タイムライン順）。
    public let overlaps: [Overlap]

    public init(clips: [TimelineClip]) {
        self.init(clips: clips, transitions: [:])
    }

    /// トランジション付きの写像を構築する。
    ///
    /// duration D のトランジションを持つペアは後続クリップの開始を D 秒前倒しして重ねる
    /// （`totalDuration = Σ合成尺 − ΣD`）。D は防御的に [0, min(両クリップ合成尺)/2] へ
    /// クランプする（`TimelineState` が保証する制約と同じ。/2 の上限により、隣り合う
    /// 重なり区間同士が連鎖して交差しないことが保証される）。
    /// NaN の duration は min/max を素通りして totalDuration を汚染するため、
    /// `TimelineClip.clampedRate` と同じ流儀で 0（トランジションなし）に落とす。
    public init(clips: [TimelineClip], transitions: [UUID: TransitionSpec]) {
        var acc = 0.0
        var built: [Entry] = []
        var builtOverlaps: [Overlap] = []
        built.reserveCapacity(clips.count)
        for (index, clip) in clips.enumerated() {
            built.append(Entry(clip: clip, start: acc))
            acc += clip.duration
            // この時点の acc は、いま積んだ Entry の `end`（= start + clip.duration）と
            // **同じ式・同じ値**なので bit 一致する。Overlap.end にはこれを渡す
            // （`start + duration` で作り直すと 1 ulp ずれる。Overlap.end の doc 参照）。
            let outgoingEnd = acc
            if index + 1 < clips.count, let spec = transitions[clip.id] {
                let cap = min(clip.duration, clips[index + 1].duration) / 2
                let duration = spec.duration.isNaN ? 0 : spec.duration
                let clamped = min(max(duration, 0), cap)
                acc -= clamped
                // クランプ後の重なりが 0 のトランジションは合成上存在しない
                // （= A/B 交互配置も instruction のランプも作らない）。
                if clamped > 0 {
                    builtOverlaps.append(Overlap(outgoingClipID: clip.id,
                                                 incomingClipID: clips[index + 1].id,
                                                 kind: spec.kind,
                                                 start: acc,
                                                 end: outgoingEnd))
                }
            }
        }
        self.entries = built
        self.totalDuration = acc
        self.overlaps = builtOverlaps
    }

    /// 合成時刻が属する重なり（半開区間 [start, end)）。重なり外は nil。
    ///
    /// `sourceLocations(at:)` が 2 要素を返す区間と厳密に一致する
    /// （どちらも同じ `init` のクランプ結果に由来する）。
    public func overlap(at compositionTime: Double) -> Overlap? {
        overlaps.first { compositionTime >= $0.start && compositionTime < $0.end }
    }

    /// 全クリップとその合成区間（タイムライン順。トランジションがあれば区間は重なる）。
    public var clipSpans: [ClipSpan] {
        entries.map { ClipSpan(clip: $0.clip, start: $0.start) }
    }

    /// 合成時刻 → 素材内の位置。範囲外なら nil。
    ///
    /// クリップ境界は次のクリップに属する（半開区間 [start, end)）。
    /// 合成時刻内オフセットに再生倍率を掛けて素材時刻へ写す
    /// （2x のクリップでは合成 1 秒が素材 2 秒に対応する）。
    ///
    /// トランジションの重なり内では**後続（incoming）側を返す**
    /// （検出キャッシュの主参照は新しい方の映像を優先する。両側が必要な場合は
    /// `sourceLocations(at:)` を使う）。
    ///
    /// rate ≠ 1 では乗算の丸め上がりで計算値が `sourceEnd`（半開区間の外）に
    /// 達し得るため、返却値を [sourceStart, sourceEnd.nextDown] にクランプして
    /// 「区間内の合成時刻は必ず区間内の素材時刻に写る」契約を守る。
    public func sourceLocation(at compositionTime: Double) -> SourceLocation? {
        guard compositionTime >= 0, compositionTime < totalDuration else { return nil }
        // 後ろから探すことで、重なり内では開始の遅い方（incoming）が先に見つかる。
        for entry in entries.reversed() where entry.start <= compositionTime {
            if compositionTime < entry.end {
                return location(for: entry, at: compositionTime)
            }
        }
        return nil
    }

    /// トランジションの重なりを含めて、合成時刻に写る素材位置を全て返す。
    ///
    /// - 重なり外: 1 要素（side / progress は nil）
    /// - 重なり内 [後続開始, 先行終了): 先行（outgoing）→後続（incoming）の順に 2 要素。
    ///   progress は `(t − 重なり開始) / D` で、半開区間契約により [0, 1) の値を取る。
    ///
    /// S8 では重なり内の両クリップの顔をこの結果で引き、progress を
    /// `TransitionKind` の純関数に渡して座標変換・union する。
    public func sourceLocations(at compositionTime: Double) -> [SourceLocationInTransition] {
        guard compositionTime >= 0, compositionTime < totalDuration else { return [] }
        // init のクランプ（D ≤ min(両クリップ尺)/2）により、同時に重なるのは高々 2 本。
        let hits = entries.filter { $0.start <= compositionTime && compositionTime < $0.end }
        guard let first = hits.first, let last = hits.last else { return [] }
        guard hits.count >= 2 else {
            return [SourceLocationInTransition(location: location(for: first, at: compositionTime),
                                              side: nil, progress: nil)]
        }
        let overlapStart = last.start
        let overlapDuration = first.end - overlapStart
        let rawProgress = overlapDuration > 0 ? (compositionTime - overlapStart) / overlapDuration : 0
        let progress = min(max(rawProgress, 0), 1)
        return [
            SourceLocationInTransition(location: location(for: first, at: compositionTime),
                                       side: .outgoing, progress: progress),
            SourceLocationInTransition(location: location(for: last, at: compositionTime),
                                       side: .incoming, progress: progress)
        ]
    }

    /// 表示タイムライン（トランジションの重なり込み = この写像の合成時刻）の時刻を、
    /// 編集タイムライン（重なりなし = `init(clips:)` の写像）の時刻へ変換する。
    ///
    /// `TimelineEditOperations` の合成時刻はすべて重なりなしの編集タイムラインで解釈されるため、
    /// UI が表示上の時刻でクリップ操作を行うときはこの変換を挟む
    /// （`TimelineState.splitting(atDisplayTime:)` が内部で使う）。
    /// 重なり内の帰属は `sourceLocation(at:)` と同じく後続（incoming）側。範囲外は nil。
    public func editTime(forDisplayTime displayTime: Double) -> Double? {
        guard displayTime >= 0, displayTime < totalDuration else { return nil }
        var editStart = 0.0
        var result: Double?
        for entry in entries {
            if entry.start <= displayTime, displayTime < entry.end {
                // 後のエントリで上書きすることで、重なり内は incoming 側に帰属させる。
                result = editStart + (displayTime - entry.start)
            }
            editStart += entry.clip.duration
        }
        return result
    }

    /// 素材内の時刻 → 合成時刻。素材時刻オフセットを再生倍率で割って写す。
    /// そのクリップの使用範囲外の素材時刻を渡した場合は nil。
    /// `sourceLocation` と対称に、クリップの使用範囲は素材時刻の半開区間 [sourceStart, sourceEnd)
    /// として扱う（終端ちょうどの素材時刻は次のクリップ側に属するため nil）。
    ///
    /// 除算の丸め上がりで計算値がクリップの合成終端（次クリップ側）に達し得るため、
    /// 返却値をクリップの合成区間の終端手前（`.nextDown`）にクランプする。
    public func compositionTime(clipID: UUID, sourceTime: Double) -> Double? {
        guard let entry = entries.first(where: { $0.clip.id == clipID }) else { return nil }
        guard sourceTime >= entry.clip.sourceStart, sourceTime < entry.clip.sourceEnd else { return nil }
        let raw = entry.start + (sourceTime - entry.clip.sourceStart) / entry.clip.rate
        return min(raw, entry.end.nextDown)
    }

    /// クリップの合成タイムライン上の開始位置。
    public func clipStartTime(clipID: UUID) -> Double? {
        entries.first(where: { $0.clip.id == clipID })?.start
    }

    /// クリップ内の合成時刻を素材時刻へ写す（ulp クランプ込みの共通処理）。
    private func location(for entry: Entry, at compositionTime: Double) -> SourceLocation {
        let offset = compositionTime - entry.start
        let raw = entry.clip.sourceStart + offset * entry.clip.rate
        let time = max(entry.clip.sourceStart, min(raw, entry.clip.sourceEnd.nextDown))
        return SourceLocation(clipID: entry.clip.id,
                              sourceID: entry.clip.sourceID,
                              time: time)
    }
}
