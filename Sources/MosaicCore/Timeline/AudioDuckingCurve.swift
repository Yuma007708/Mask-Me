import Foundation

/// 声区間（`ClipDuckRange`）から、BGM の音量を下げる合成時刻のノード列を作る純関数。
///
/// **素材時刻 → 合成時刻の変換は `TimelineMapping.compositionTime(clipID:sourceTime:)` のみを
/// 使う。** 自前の式（`sourceTime / rate` 等）を書くと `rate ≠ 1` のクリップでノードの位置が
/// ずれる（実績: 適用区間・消音区間の写像でも同じ理由で `TimelineMapping` を経由させている）。
/// attack/release は合成時刻（実時間）の長さとして足す（rate に依存しない: 「声の 0.12 秒前から
/// 下げ始める」は聞こえ方の話であって素材上の時間ではない）。
public enum AudioDuckingCurve {
    /// 声区間の**前**から下げ始める合成時刻の長さ（秒）。声の頭が埋もれないための先行。
    public static let attack: Double = 0.12
    /// 声区間の**後**に元の音量へ戻すまでの合成時刻の長さ（秒）。
    public static let release: Double = 0.35

    /// ノード 1 個（合成時刻 + そのときの BGM ゲイン）。
    public struct Node: Equatable, Sendable {
        public let time: Double
        public let gain: Float
    }

    /// `ranges` から `[start-attack: 1.0] → [start: gain] → [end: gain] → [end+release: 1.0]` の
    /// ノード列を作る。
    ///
    /// - Parameters:
    ///   - ranges: 声区間（素材時刻アンカー）。
    ///   - gain: 声区間内で BGM に掛ける音量（`AudioItem.duckingGain`）。**素の音量より上げない**
    ///     ように `0...1` へクランプする。
    ///   - mapping: 素材時刻 → 合成時刻の唯一の変換経路。
    ///   - songStart: BGM が鳴っている合成時刻の開始（`AudioItem.compositionStart`）。
    ///   - songEnd: BGM が鳴っている合成時刻の終了（`AudioItem.compositionEnd`）。
    ///
    /// **不変条件**（呼び出し側・テストの契約）: 返るノードは時刻が厳密に単調増加し、
    /// ゲインは常に `[gain, 1]` に収まり、`songStart...songEnd` の外へは出ず、
    /// 近接する声区間どうしでノードが重ならない（重なりそうなら 1 本の平坦区間へ統合する）。
    public static func nodes(ranges: [ClipDuckRange],
                             gain: Float,
                             mapping: TimelineMapping,
                             songStart: Double,
                             songEnd: Double) -> [Node] {
        guard songStart.isFinite, songEnd.isFinite, songStart < songEnd else { return [] }
        let clampedGain = gain.isFinite ? min(max(gain, 0), 1) : 1

        let spans = compositionSpans(ranges: ranges, mapping: mapping)
        guard !spans.isEmpty else { return [] }
        let ducked = duckedSpans(from: spans, songStart: songStart, songEnd: songEnd)
        return ducked.flatMap { nodes(for: $0, gain: clampedGain) }
    }

    /// 声区間を合成時刻区間へ写す（写像不能・逆転は捨てる）。開始・終了とも
    /// `compositionTime` を通す（終了は半開区間の右端なので、クリップ終端ちょうどのときは
    /// `.nextDown` で「その手前」を渡す。式を自前で作るのではなく、渡す `sourceTime` を
    /// 半開区間の内側に収めるだけ）。
    private static func compositionSpans(ranges: [ClipDuckRange],
                                         mapping: TimelineMapping) -> [(start: Double, end: Double)] {
        var spans: [(start: Double, end: Double)] = []
        for range in ranges {
            guard let span = mapping.clipSpans.first(where: { $0.clip.id == range.clipID }) else { continue }
            let clip = span.clip
            guard clip.sourceID == range.sourceID else { continue }
            let clampedStart = max(range.sourceStart, clip.sourceStart)
            let clampedEnd = min(range.sourceEnd, clip.sourceEnd)
            guard clampedStart < clampedEnd else { continue }
            let endProbe = clampedEnd < clip.sourceEnd ? clampedEnd : clampedEnd.nextDown
            guard let compStart = mapping.compositionTime(clipID: clip.id, sourceTime: clampedStart),
                  let compEnd = mapping.compositionTime(clipID: clip.id, sourceTime: endProbe),
                  compStart.isFinite, compEnd.isFinite, compStart < compEnd else { continue }
            spans.append((compStart, compEnd))
        }
        return spans.sorted { $0.start < $1.start }
    }

    /// 1 声区間ぶんの「下げている区間」。
    private struct DuckedSpan {
        var loweredStart: Double
        var loweredEnd: Double
        var attackStart: Double
        var releaseEnd: Double
    }

    /// attack/release を足し、曲の範囲へクランプしたうえで、近接（attack/release が重なる）
    /// 区間どうしを 1 本の平坦区間へ統合する。
    private static func duckedSpans(from spans: [(start: Double, end: Double)],
                                    songStart: Double, songEnd: Double) -> [DuckedSpan] {
        var result: [DuckedSpan] = []
        for span in spans {
            let loweredStart = max(songStart, span.start)
            let loweredEnd = min(songEnd, span.end)
            guard loweredStart < loweredEnd else { continue }
            let attackStart = max(songStart, span.start - attack)
            let releaseEnd = min(songEnd, span.end + release)
            if let last = result.last, attackStart <= last.releaseEnd {
                result[result.count - 1].loweredEnd = max(last.loweredEnd, loweredEnd)
                result[result.count - 1].releaseEnd = max(last.releaseEnd, releaseEnd)
            } else {
                result.append(DuckedSpan(loweredStart: loweredStart, loweredEnd: loweredEnd,
                                         attackStart: attackStart, releaseEnd: releaseEnd))
            }
        }
        return result
    }

    /// 1 つの下げ区間をノード列へ変換する。境界クランプで attack/release が潰れた
    /// （`loweredStart`/`loweredEnd` と同時刻になった）ときはその端のノードを省く
    /// （厳密な単調増加を保つため。重複時刻のノードは作らない）。
    private static func nodes(for span: DuckedSpan, gain: Float) -> [Node] {
        var result: [Node] = []
        if span.attackStart < span.loweredStart {
            result.append(Node(time: span.attackStart, gain: 1))
        }
        result.append(Node(time: span.loweredStart, gain: gain))
        result.append(Node(time: span.loweredEnd, gain: gain))
        if span.releaseEnd > span.loweredEnd {
            result.append(Node(time: span.releaseEnd, gain: 1))
        }
        return result
    }
}
