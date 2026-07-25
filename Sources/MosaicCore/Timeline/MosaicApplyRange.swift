import Foundation

/// モザイクを適用する素材時刻の区間（半開区間 [sourceStart, sourceEnd)）。
///
/// 検出キャッシュと同じ理屈で**素材時刻アンカー**にしてあるため、
/// クリップの分割・並べ替え・速度変更後も区間を更新せずに自動追従する。
/// UI が扱う合成時刻の区間は `MosaicApplyGate.ranges(addingCompositionInterval:...)` で
/// 素材アンカーへ分解してから保存する（合成時刻のまま保存する誤実装を禁止）。
///
/// **区間の編集も素材時刻で行うこと。** 「合成時刻の区間列から作り直す」実装は、
/// 合成時刻から復元できるのが「今どれかのクリップが使っている素材範囲」だけなので、
/// クリップ使用範囲外の素材区間（トリムで一時的にクリップから外れた区間など）を
/// 必ず落とす。実測: クリップ A=source[0,2)・B=source[3,5) に対し適用区間
/// source[1,4) をハンドルに触っただけで source[2,3) が消滅した。
/// 編集の入口は `MosaicApplyGate.ranges(replacingRangeID:clipID:...)` の 1 本だけで、
/// これは**掴んだクリップが使っている素材区間だけ**を差し替える。
///
/// **写真素材の適用区間はクリップ全体（素材 [0, sourceEnd)）を覆う。**
/// 写真クリップの素材時刻は `TimelineState.clampedSourceTime` が常に 0 へ丸める
/// （全フレーム同一なので検出キャッシュを 1 エントリに集約する設計）ため、
/// 合成時刻由来の素材アンカー（例 [1,2)）を保存すると `isActive` が 0 を見て
/// **絶対にヒットしない**。静止画に対する秒単位のモザイク ON/OFF を捨てる代わりに、
/// 「素材時刻アンカー」という不変条件を全素材で保つ。
///
/// **どのクリップの使用範囲とも交差しなくなった区間（孤児区間）は消さずに温存する。**
/// トリム・分割・クリップ削除で一時的に外れただけの区間を消すと、トリムを戻しても
/// undo しても復活しないからである。代わりに**ゲート判定の側で除外**する
/// （`MosaicApplyGate.effectiveRanges(_:mapping:)`）。この分担により
/// 「画面に見えている帯（`TimelineBandLayout.applySpans`）とゲートの挙動が必ず一致する」
/// という不変条件が保たれる（孤児区間を放置してゲートに通すと、帯 0 本＝削除不能なのに
/// 全区間 OFF という復帰不能な状態になる。S10 レビューの実測事故）。
public struct MosaicApplyRange: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// 素材の識別子（`TimelineClip.sourceID` と同じ空間）。
    public let sourceID: UUID
    /// 素材内での適用開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での適用終了位置（秒）。この時刻ちょうどは区間外（半開区間）。
    public var sourceEnd: Double

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: Double, sourceEnd: Double) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

/// UI が指定する合成時刻の半開区間 [start, end)。
///
/// `Range<Double>` を使わないのは、`lowerBound > upperBound` で実行時トラップする
/// （ジェスチャ由来の値では起こり得る）ため。この型は不正な区間をそのまま持てて、
/// 受け側（`TimelineState.replacingApplyRange`）が捨てる。
public struct CompositionInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// 有限かつ start < end。
    public var isValid: Bool { start.isFinite && end.isFinite && start < end }
}

/// モザイク適用範囲のゲート判定と区間編集の純関数群。
///
/// ゲートは検出 lookup の**後段・描画直前**に置く（区間外でもライブ検出は継続して
/// キャッシュを埋める設計のため、lookup 側に入れてはならない）。
public enum MosaicApplyGate {
    /// 同一 sourceID の区間マージで「隣接」とみなす許容誤差（秒）。
    /// クリップ分割由来の区間は境界が浮動小数点誤差でずれ得るため厳密一致にしない。
    private static let mergeTolerance: Double = 1e-9

    /// 「いまのタイムラインで実際に効いている適用区間」だけに絞る（S10 レビュー修正）。
    ///
    /// **ゲート判定に渡す区間は必ずこの関数を通すこと。** 顔の素材別ゲート・合成時刻
    /// ゲート・エクスポートの 3 経路が同じ結果になる唯一の担保であり、絞り込みを
    /// 呼び出し側で書き直す（＝二重実装する）ことは禁止する。
    ///
    /// **なぜ要るか（孤児区間の事故）**: 適用区間は素材時刻アンカーなので、トリム・分割・
    /// クリップ削除で「どのクリップの使用範囲とも交差しない」状態になり得る（区間データは
    /// `MosaicApplyRange` 型の doc どおり**温存する**設計なので、そのまま残る）。このとき
    /// 帯 UI（`TimelineBandLayout.applySpans`）は 0 本になって区間を選択・削除できないのに、
    /// `applyRanges` は非空なのでゲートだけが全時刻で false になり、**モザイクが全区間で
    /// 消えたまま undo 以外に戻せなくなる**。実測: 4 秒素材に区間 source[1,2) を置き、
    /// 左端を 2.5 までトリムしただけで帯 1 本 → 0 本・ゲート ON 比率 0.24988 → 0.0。
    ///
    /// 絞り込み後が空なら「区間指定なし」（＝全区間適用の既存挙動）に戻る。これにより
    /// **「画面に見えている帯とゲートの挙動が必ず一致する」**（帯 n 本 ⇔ 有効区間 n 個、
    /// 帯 0 本 ⇔ ゲート常時 ON）という不変条件が成立する。
    ///
    /// 交差判定は `TimelineBandLayout.applySpans` と**同じ式**（同一 sourceID の
    /// `max(range.sourceStart, clip.sourceStart) < min(range.sourceEnd, clip.sourceEnd)` の
    /// 半開区間交差、両端が有限）である。ここだけ式が違うと「帯は出ているのにゲートが
    /// 閉じる」1 ulp 事故が復活する（S8 の `Overlap.end` の前科）。
    ///
    /// 計算量は O(クリップ数 × 区間数)。**毎フレーム呼ばない**こと。
    /// `MosaicEditorModel` は `timeline` の didSet で 1 回だけ計算してキャッシュし、
    /// `VideoMosaicExporter` は export 開始時に 1 回だけ計算する
    /// （実測: 50 クリップ × 100 区間で 0.14〜0.18ms／回。タイムライン変更時 1 回なら
    /// 無視できるが、30fps 描画やエクスポートの全フレームで回す量ではない）。
    public static func effectiveRanges(_ ranges: [MosaicApplyRange],
                                       mapping: TimelineMapping) -> [MosaicApplyRange] {
        guard !ranges.isEmpty else { return ranges }
        let spans = mapping.clipSpans
        guard !spans.isEmpty else { return [] }
        return ranges.filter { range in
            spans.contains { span in
                let clip = span.clip
                guard clip.sourceID == range.sourceID else { return false }
                let start = max(range.sourceStart, clip.sourceStart)
                let end = min(range.sourceEnd, clip.sourceEnd)
                return start.isFinite && end.isFinite && start < end
            }
        }
    }

    /// 指定した素材時刻にモザイクを適用すべきかを返す。
    ///
    /// `ranges` には `effectiveRanges(_:mapping:)` の結果を渡すこと
    /// （生の `TimelineState.applyRanges` を渡すと孤児区間で全区間 OFF になる）。
    ///
    /// `ranges` が**空なら常に true**（範囲指定なし = 全区間適用の既存挙動互換）。
    /// 判定は半開区間 [sourceStart, sourceEnd)。
    ///
    /// **非有限の `sourceTime` はフェイルオープン**（true）にする。写像が壊れた時刻で
    /// 「顔にはモザイクが乗らないが手動矩形と背景モザイクは乗る」という、経路ごとに
    /// フェイル方向が食い違う状態を作らないため（合成時刻ゲート側は非有限時刻で
    /// フェイルオープンする）。プロジェクトの原則どおり**過剰適用が安全側・不足が事故**の
    /// 方向へ倒す。実害としては、NaN 時刻では `lookupFaces` も空を返すので描かれる顔は無い。
    public static func isActive(ranges: [MosaicApplyRange], sourceID: UUID, sourceTime: Double) -> Bool {
        guard !ranges.isEmpty else { return true }
        guard sourceTime.isFinite else { return true }
        return ranges.contains {
            $0.sourceID == sourceID && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
        }
    }

    /// 指定した**合成時刻**でモザイクを適用すべきかを返す（S10）。
    ///
    /// 素材アンカーを持たない効果——手動矩形（`manualRegions`）と背景モザイク——の
    /// 唯一の判定入口である。これらは合成タイムライン全体に対する設定で素材ごとの
    /// 時刻を持たないため、素材別の `isActive(ranges:sourceID:sourceTime:)` を
    /// そのまま使えない。判定規則は
    ///
    /// > **その合成時刻に映っている素材のうち、1 つでも適用区間内なら適用する。**
    ///
    /// トランジションの重なり区間（2 素材が同時に映る）で片方だけ区間内のときは
    /// 適用側へ倒す近似になる。重なりは高々トランジション尺であり、かつ
    /// **モザイクの過剰適用は安全側・不足は事故**なのでこの方向で確定させる。
    ///
    /// 顔ランドマークはこの関数を通さない。顔は素材ごとに引くので
    /// `isActive(ranges:sourceID:sourceTime:)` で**素材別に**ゲートできる
    /// （`MosaicEditorModel.displayFaces(at:matching:)`）。
    ///
    /// **フェイルオープンする条件**（いずれも「ゲート以前の従来経路」＝挙動不変にする）:
    /// - `ranges` が空（範囲指定なし = 全区間適用。`effectiveRanges` が孤児区間を
    ///   落とした結果の空も含む）
    /// - 写像が 1 つも解決できない（クリップ未構築・非有限時刻・空タイムライン）
    ///
    /// **顔の素材別ゲート（`isActive(ranges:sourceID:sourceTime:)`）もフェイル方向が
    /// これと揃っている**（非有限の素材時刻でフェイルオープン、クリップ未構築なら
    /// `effectiveRanges` が空を返してフェイルオープン）。片方だけフェイルクローズだと
    /// 「顔にはモザイクが乗らないが手動矩形と背景モザイクは乗る」という中途半端な絵になる。
    ///
    /// 写像範囲外の有限時刻（合成尺ちょうどの終端・負値。再生終端や AVPlayer の実測
    /// 時刻の揺らぎで日常的に発生する）はタイムラインの端へクランプしてから写像する。
    /// これは `MosaicEditorModel.resolveSourceTime(atComposition:)` および
    /// `VideoMosaicExporter.resolveLocation(_:at:)` と**同じ規則**である
    /// （ここだけ規則が違うと終端フレームでプレビューとエクスポートの ON/OFF が食い違う）。
    ///
    /// **既知の解像度限界**: rate < 1 のクリップでは、区間終端 `to` の直前 2 ulp
    /// （実測 7.105e-15 秒）が OFF になることがある。合成時刻→素材時刻の写像
    /// （`TimelineMapping.location(for:at:)`）が double 解像度で単射でないためで、
    /// S10 のゲートの誤りではない。ズレ幅は 1/60 秒フレームの 4.3e-13 倍であり、
    /// 実フレームの PTS がそこに当たることは事実上ない。
    ///
    /// - Parameter ranges: `effectiveRanges(_:mapping:)` を通した区間。
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合。素材時刻を 0 へ clamp する
    ///   （`TimelineState.clampedSourceTime` と同じ規則。写真の適用区間は
    ///   `MosaicApplyRange` 型の doc どおり素材 [0, sourceEnd) を覆う）。
    ///   **既定値は置かない**: 渡し漏れると同一写真素材の複数クリップ構成で判定が
    ///   無言で反転する（実測で true ⇄ false が入れ替わる）ため、渡し忘れを
    ///   コンパイルエラーにする。
    public static func isActive(ranges: [MosaicApplyRange],
                                mapping: TimelineMapping,
                                compositionTime: Double,
                                photoSourceIDs: Set<UUID>) -> Bool {
        gateState(ranges: ranges, mapping: mapping, compositionTime: compositionTime,
                  photoSourceIDs: photoSourceIDs).isActive
    }

    /// 合成時刻ゲートの判定結果と、その内訳（どの素材が適用対象か）。
    public struct CompositionGateState: Equatable, Sendable {
        /// 素材アンカーを持たない効果（手動矩形・背景モザイク）を適用するか。
        public let isActive: Bool
        /// その合成時刻に映っている素材のうち、適用区間内と判定されたものの素材ID集合。
        /// フェイルオープン時（区間指定なし・写像不能）は「映っている素材すべて」
        /// （写像不能なら空集合）になる。
        ///
        /// **用途**: トランジションの重なり区間で片方の素材だけ ON→OFF に変わった
        /// フレームを検出するため。`isActive` は「どれか 1 つでも ON」なので、
        /// 重なり中に片側が落ちても真偽値は true のまま変わらず、エクスポートの
        /// 強制再検出（`gateChanged`）が発火しない＝古い union が居座る。
        public let activeSourceIDs: Set<UUID>

        public init(isActive: Bool, activeSourceIDs: Set<UUID>) {
            self.isActive = isActive
            self.activeSourceIDs = activeSourceIDs
        }
    }

    /// `isActive(ranges:mapping:compositionTime:photoSourceIDs:)` と同じ判定を、
    /// 内訳（適用対象の素材ID集合）付きで返す。判定規則の実体はこの 1 本だけ。
    public static func gateState(ranges: [MosaicApplyRange],
                                 mapping: TimelineMapping,
                                 compositionTime: Double,
                                 photoSourceIDs: Set<UUID>) -> CompositionGateState {
        var locations = mapping.sourceLocations(at: compositionTime)
        if locations.isEmpty, compositionTime.isFinite, mapping.totalDuration > 0 {
            let clamped = min(max(compositionTime, 0), mapping.totalDuration.nextDown)
            locations = mapping.sourceLocations(at: clamped)
        }
        let visible = Set(locations.map(\.location.sourceID))
        guard !ranges.isEmpty else { return CompositionGateState(isActive: true, activeSourceIDs: visible) }
        guard !locations.isEmpty else { return CompositionGateState(isActive: true, activeSourceIDs: []) }
        var active: Set<UUID> = []
        for entry in locations {
            let sourceID = entry.location.sourceID
            let sourceTime = photoSourceIDs.contains(sourceID) ? 0 : entry.location.time
            if isActive(ranges: ranges, sourceID: sourceID, sourceTime: sourceTime) {
                active.insert(sourceID)
            }
        }
        return CompositionGateState(isActive: !active.isEmpty, activeSourceIDs: active)
    }

    /// UI が指定した合成時刻の区間 [from, to) を素材アンカーへ分解して `existing` に追加する。
    ///
    /// 区間が複数クリップを跨ぐ場合は素材ごとのセグメントに分割される。
    /// 追加後、同一 sourceID の重複・隣接区間はマージして正規化する。
    /// マージ結果の id は**入力順で最初に現れた区間**の id を引き継ぐ
    /// （既存 → 新規セグメントの順で処理するため、既存区間があればその id が保たれ、
    /// 前方に伸ばす操作でも UI の選択が飛ばない）。
    /// `from >= to` の場合は `existing` をそのまま返す。
    ///
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合（`TimelineState.photoSourceIDs`）。
    ///   該当クリップに触れる区間は素材 [0, sourceEnd) に丸める（型の doc 参照）。
    public static func ranges(addingCompositionInterval from: Double, to: Double,
                              mapping: TimelineMapping,
                              existing: [MosaicApplyRange],
                              photoSourceIDs: Set<UUID> = []) -> [MosaicApplyRange] {
        guard from < to else { return existing }
        var result = existing
        for span in mapping.clipSpans {
            guard let interval = sourceInterval(in: span, from: from, to: to,
                                                isPhoto: photoSourceIDs.contains(span.clip.sourceID))
            else { continue }
            result.append(MosaicApplyRange(sourceID: span.clip.sourceID,
                                           sourceStart: interval.start,
                                           sourceEnd: interval.end))
        }
        return merged(result)
    }

    /// 掴んだセグメント（`rangeID` × `clipID`）の素材区間だけを差し替える（端ドラッグの確定）。
    ///
    /// **合成時刻での作り直しをしない理由**は `MosaicApplyRange` 型の doc を参照。
    /// 当該クリップの使用範囲と交差する部分だけを新区間へ置き換え、
    /// クリップ使用範囲の外にある素材区間（他クリップぶん・どのクリップも使っていない
    /// 区間）はそのまま残す。結果は同一 sourceID 内でマージ・正規化される。
    ///
    /// 次の場合は `existing` をそのまま返す（他の編集操作と同じ「失敗時は無変更」契約）:
    /// - 区間が不正（`CompositionInterval.isValid` が false）
    /// - `rangeID` / `clipID` が不在、または両者の素材が食い違う
    /// - 差し替え結果が現在の素材区間と一致する（ハンドルに触っただけのドラッグ量 0。
    ///   ここで弾かないと id 再発行だけで `Equatable` が differ になり、undo 履歴が汚れる）
    public static func ranges(replacingRangeID id: UUID,
                              clipID: UUID,
                              compositionInterval interval: CompositionInterval,
                              mapping: TimelineMapping,
                              existing: [MosaicApplyRange],
                              photoSourceIDs: Set<UUID> = []) -> [MosaicApplyRange] {
        guard interval.isValid,
              let index = existing.firstIndex(where: { $0.id == id }),
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }),
              existing[index].sourceID == span.clip.sourceID,
              let replacement = sourceInterval(in: span, from: interval.start, to: interval.end,
                                               isPhoto: photoSourceIDs.contains(span.clip.sourceID))
        else { return existing }
        let range = existing[index]
        // 当該クリップが使っている素材区間（= 掴んだセグメントの実体）。
        let occupiedStart = max(range.sourceStart, span.clip.sourceStart)
        let occupiedEnd = min(range.sourceEnd, span.clip.sourceEnd)
        var pieces: [(start: Double, end: Double)] = []
        if occupiedStart < occupiedEnd {
            if abs(occupiedStart - replacement.start) <= mergeTolerance,
               abs(occupiedEnd - replacement.end) <= mergeTolerance { return existing }
            if range.sourceStart < occupiedStart { pieces.append((range.sourceStart, occupiedStart)) }
            if occupiedEnd < range.sourceEnd { pieces.append((occupiedEnd, range.sourceEnd)) }
        } else {
            pieces.append((range.sourceStart, range.sourceEnd))
        }
        pieces.append(replacement)
        pieces.sort { $0.start < $1.start }
        // 元の id は先頭の断片へ継がせる（マージ後も id 継承の先勝ちで保たれ、
        // UI の選択と undo の差分が最小になる）。位置も元の index のまま差し替えることで
        // `merged` の並び（sourceID の初出順）が変わらない。
        let rebuilt = pieces.enumerated().map { offset, piece in
            MosaicApplyRange(id: offset == 0 ? range.id : UUID(), sourceID: range.sourceID,
                             sourceStart: piece.start, sourceEnd: piece.end)
        }
        var result = existing
        result.replaceSubrange(index...index, with: rebuilt)
        return merged(result)
    }

    /// 指定した id の区間を取り除く。見つからない場合は変更なし。
    public static func removingRange(id: UUID, from ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        ranges.filter { $0.id != id }
    }

    /// 合成時刻区間 [from, to) と 1 クリップの交差を素材時刻区間へ写す。
    /// 交差しない場合と潰れた区間は nil。写真素材はクリップ全体を覆う区間に丸める。
    private static func sourceInterval(in span: TimelineMapping.ClipSpan,
                                       from: Double, to: Double,
                                       isPhoto: Bool) -> (start: Double, end: Double)? {
        let overlapStart = max(from, span.start)
        let overlapEnd = min(to, span.end)
        guard overlapStart < overlapEnd else { return nil }
        let clip = span.clip
        guard !isPhoto else { return clip.sourceEnd > 0 ? (0, clip.sourceEnd) : nil }
        let rawStart = clip.sourceStart + (overlapStart - span.start) * clip.rate
        let rawEnd = clip.sourceStart + (overlapEnd - span.start) * clip.rate
        let sourceStart = min(max(rawStart, clip.sourceStart), clip.sourceEnd)
        let sourceEnd = min(max(rawEnd, clip.sourceStart), clip.sourceEnd)
        guard sourceStart < sourceEnd else { return nil }
        return (sourceStart, sourceEnd)
    }

    /// マージ中の 1 区間の作業状態。`index` は入力配列内の位置（id の先勝ち判定に使う）。
    private struct MergeAccumulator {
        var index: Int
        var id: UUID
        var start: Double
        var end: Double
    }

    /// 同一 sourceID の重複・隣接区間をマージして正規化する。
    ///
    /// マージ結果の id は入力順で最初（`index` 最小）の区間の id を引き継ぐ。
    /// 結果は sourceID の初出順・各 sourceID 内は sourceStart 昇順で並ぶ。
    /// ソートは同値の sourceStart を入力順でタイブレークし決定的にする
    /// （`sorted(by:)` の安定性は言語仕様上保証されないため）。
    private static func merged(_ ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        var order: [UUID] = []
        var groups: [UUID: [(index: Int, range: MosaicApplyRange)]] = [:]
        for (index, range) in ranges.enumerated() {
            if groups[range.sourceID] == nil { order.append(range.sourceID) }
            groups[range.sourceID, default: []].append((index, range))
        }
        var result: [MosaicApplyRange] = []
        for sourceID in order {
            guard let group = groups[sourceID] else { continue }
            let sorted = group.sorted {
                $0.range.sourceStart == $1.range.sourceStart
                    ? $0.index < $1.index
                    : $0.range.sourceStart < $1.range.sourceStart
            }
            var current: MergeAccumulator?
            for member in sorted {
                if var accumulated = current, member.range.sourceStart <= accumulated.end + mergeTolerance {
                    accumulated.end = max(accumulated.end, member.range.sourceEnd)
                    if member.index < accumulated.index {
                        accumulated.index = member.index
                        accumulated.id = member.range.id
                    }
                    current = accumulated
                } else {
                    if let accumulated = current {
                        result.append(MosaicApplyRange(id: accumulated.id, sourceID: sourceID,
                                                       sourceStart: accumulated.start, sourceEnd: accumulated.end))
                    }
                    current = MergeAccumulator(index: member.index, id: member.range.id,
                                               start: member.range.sourceStart, end: member.range.sourceEnd)
                }
            }
            if let accumulated = current {
                result.append(MosaicApplyRange(id: accumulated.id, sourceID: sourceID,
                                               sourceStart: accumulated.start, sourceEnd: accumulated.end))
            }
        }
        return result
    }
}
