import Foundation

/// モザイクを適用する素材時刻の区間（半開区間 [sourceStart, sourceEnd)）。
///
/// 検出キャッシュと同じ理屈で**素材時刻アンカー**にしてあるため、
/// クリップの分割・並べ替え・速度変更後も区間を更新せずに自動追従する。
/// UI が扱う合成時刻の区間は `MosaicApplyGate.ranges(addingCompositionInterval:...)` で
/// 素材アンカーへ分解してから保存する（合成時刻のまま保存する誤実装を禁止）。
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
    public static func ranges(addingCompositionInterval from: Double, to: Double,
                              mapping: TimelineMapping,
                              existing: [MosaicApplyRange]) -> [MosaicApplyRange] {
        guard from < to else { return existing }
        var result = existing
        for span in mapping.clipSpans {
            let overlapStart = max(from, span.start)
            let overlapEnd = min(to, span.end)
            guard overlapStart < overlapEnd else { continue }
            let clip = span.clip
            let rawStart = clip.sourceStart + (overlapStart - span.start) * clip.rate
            let rawEnd = clip.sourceStart + (overlapEnd - span.start) * clip.rate
            let sourceStart = min(max(rawStart, clip.sourceStart), clip.sourceEnd)
            let sourceEnd = min(max(rawEnd, clip.sourceStart), clip.sourceEnd)
            guard sourceStart < sourceEnd else { continue }
            result.append(MosaicApplyRange(sourceID: clip.sourceID,
                                           sourceStart: sourceStart,
                                           sourceEnd: sourceEnd))
        }
        return merged(result)
    }

    /// 指定した id の区間を取り除く。見つからない場合は変更なし。
    public static func removingRange(id: UUID, from ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        ranges.filter { $0.id != id }
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
