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

    /// 指定した素材時刻にモザイクを適用すべきかを返す。
    ///
    /// `ranges` が**空なら常に true**（範囲指定なし = 全区間適用の既存挙動互換）。
    /// 判定は半開区間 [sourceStart, sourceEnd)。
    public static func isActive(ranges: [MosaicApplyRange], sourceID: UUID, sourceTime: Double) -> Bool {
        guard !ranges.isEmpty else { return true }
        return ranges.contains {
            $0.sourceID == sourceID && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
        }
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
