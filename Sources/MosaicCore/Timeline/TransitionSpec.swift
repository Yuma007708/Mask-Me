import CoreGraphics
import Foundation

/// トランジションで重なり合う 2 クリップのどちら側かを表す。
public enum TransitionSide: String, Codable, CaseIterable, Sendable {
    /// 先行クリップ（画面から退場していく側）。
    case outgoing
    /// 後続クリップ（画面に登場してくる側）。
    case incoming
}

/// トランジションのある進行度における、片側クリップの視覚パラメータ。
///
/// 座標系は画面全体を [0,1]×[0,1] とする正規化座標。
/// `TransitionKind.parameters(progress:side:)` だけが生成する（手組みしない）。
public struct TransitionParameters: Equatable, Sendable {
    /// 不透明度（0 = 非表示、1 = 完全表示）。フェード系のみ 1 以外になる。
    public let opacity: Double
    /// 平行移動量（正規化座標単位）。スライド系のみ非ゼロになる。
    public let translation: CGVector
    /// 画面上で実際に見える領域（正規化座標）。ワイプ系のみ全画面以外になる。
    /// 判定は半開区間 [minX, maxX) × [minY, maxY)（タイムラインの半開区間契約と同じ流儀）。
    public let visibleRect: CGRect

    public init(opacity: Double, translation: CGVector, visibleRect: CGRect) {
        self.opacity = opacity
        self.translation = translation
        self.visibleRect = visibleRect
    }
}

/// トランジションの種類。
///
/// `parameters(progress:side:)` が全種類の**視覚変換の単一情報源**である。
/// S8 では AVVideoComposition の instruction ランプ生成（opacityRamp / transformRamp /
/// cropRectangleRamp）と、重なり区間のランドマーク座標変換の**両方**がこの関数を呼ぶ。
/// 同じ数式を別の場所に二重実装してはならない（ランプと座標変換のずれはモザイク漏れになる）。
public enum TransitionKind: String, Codable, CaseIterable, Sendable {
    /// 一度黒画面を挟むフェード。暗転 → 黒を保つ（`blackHoldFraction`）→ 明転の 3 段。
    case fadeToBlack
    /// 2 クリップを直接クロスフェード。
    case crossfade
    /// 画面が左へ流れるスライド（後続クリップが右から入り、先行クリップは左へ抜ける）。
    case slideLeft
    /// 画面が右へ流れるスライド（後続クリップが左から入り、先行クリップは右へ抜ける）。
    case slideRight
    /// 境界線が右端から左へ掃引するワイプ（後続クリップが右側から現れる）。
    case wipeLeft
    /// 境界線が左端から右へ掃引するワイプ（後続クリップが左側から現れる）。
    case wipeRight

    /// `fadeToBlack` で**完全な黒を保つ**区間が、トランジション全体に占める割合。
    ///
    /// 0 だと黒は progress=0.5 の一瞬しか出ず、暗転がそのまま明転に折り返すため
    /// 「黒を挟んだ」という印象が残らない（実機で確認して 2026-07-29 に導入）。
    /// 暗転 `(1-hold)/2` → 黒 `hold` → 明転 `(1-hold)/2` の 3 段になる。
    ///
    /// この値を変えると `rampBreakpoints` の分割点も自動で追従する
    /// （分割点を手で書かないこと。ランプと数式がずれるとモザイクが漏れる）。
    public static let blackHoldFraction: Double = 0.3

    /// `fadeToBlack` の暗転（および明転）1 段ぶんが占める割合。
    /// = `(1 - blackHoldFraction) / 2`。黒ホールドの両端の分割点でもある。
    static let fadeToBlackRampFraction: Double = (1 - blackHoldFraction) / 2

    /// トランジションを新規に付けるときの既定の尺（秒）。
    ///
    /// `fadeToBlack` は暗転・黒・明転の 3 段を通すため、他と同じ 0.5 秒では
    /// 各段が 0.15〜0.18 秒しかなく黒が視認できない。ここだけ長くする。
    /// 実際に採用される値は隣り合うクリップ尺による上限でクランプされる
    /// （`TimelineState.maximumTransitionDuration(afterClipID:)`）。
    public var defaultDuration: Double {
        self == .fadeToBlack ? 1.0 : 0.5
    }

    /// 進行度 `progress` における `side` 側クリップの視覚パラメータを返す純関数。
    ///
    /// 端点契約: progress=0 で outgoing が完全表示・incoming が非表示、progress=1 でその逆。
    /// 中間値は線形ランプ（fadeToBlack のみ暗転／黒ホールド／明転の区分線形）。
    /// progress は [0,1] にクランプされる（NaN は 0 扱い）。
    public func parameters(progress: Double, side: TransitionSide) -> TransitionParameters {
        let p = Self.clampedProgress(progress)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch self {
        case .fadeToBlack:
            // [0, r] で outgoing が黒へ、[1-r, 1] で incoming が黒から。
            // その間 [r, 1-r] は両側 0 = 完全な黒（r = fadeToBlackRampFraction）。
            let r = Self.fadeToBlackRampFraction
            let opacity = side == .outgoing
                ? max(0, min(1, (r - p) / r))
                : max(0, min(1, (p - (1 - r)) / r))
            return TransitionParameters(opacity: opacity, translation: .zero, visibleRect: unit)
        case .crossfade:
            let opacity = side == .outgoing ? 1 - p : p
            return TransitionParameters(opacity: opacity, translation: .zero, visibleRect: unit)
        case .slideLeft:
            let dx = side == .outgoing ? -p : 1 - p
            return TransitionParameters(opacity: 1, translation: CGVector(dx: dx, dy: 0), visibleRect: unit)
        case .slideRight:
            let dx = side == .outgoing ? p : p - 1
            return TransitionParameters(opacity: 1, translation: CGVector(dx: dx, dy: 0), visibleRect: unit)
        case .wipeLeft:
            let rect = side == .outgoing
                ? CGRect(x: 0, y: 0, width: 1 - p, height: 1)
                : CGRect(x: 1 - p, y: 0, width: p, height: 1)
            return TransitionParameters(opacity: 1, translation: .zero, visibleRect: rect)
        case .wipeRight:
            let rect = side == .outgoing
                ? CGRect(x: p, y: 0, width: 1 - p, height: 1)
                : CGRect(x: 0, y: 0, width: p, height: 1)
            return TransitionParameters(opacity: 1, translation: .zero, visibleRect: rect)
        }
    }

    /// 正規化座標の点（ランドマーク等）にトランジションの視覚変換を適用する。
    ///
    /// translation 適用後の点が `visibleRect` の外（半開区間判定）、
    /// または不透明度 0 の場合は nil を返す（= その顔は画面上で不可視。モザイク不要）。
    /// `parameters(progress:side:)` と同じ数式を共有するため、S8 のランプと必ず一致する。
    public func transformPoint(_ point: CGPoint, progress: Double, side: TransitionSide) -> CGPoint? {
        let params = parameters(progress: progress, side: side)
        guard params.opacity > 0 else { return nil }
        let moved = CGPoint(x: point.x + params.translation.dx, y: point.y + params.translation.dy)
        guard moved.x >= params.visibleRect.minX, moved.x < params.visibleRect.maxX,
              moved.y >= params.visibleRect.minY, moved.y < params.visibleRect.maxY else { return nil }
        return moved
    }

    /// 進行度を [0,1] にクランプする。NaN は開始状態（0）に落とす
    /// （`TimelineClip.clampedRate` と同じ流儀で min/max の素通りを防ぐ）。
    public static func clampedProgress(_ progress: Double) -> Double {
        progress.isNaN ? 0 : min(max(progress, 0), 1)
    }

    /// 区分線形ランプの分割点（progress 昇順・両端を含む）。
    ///
    /// AVFoundation のランプ（`setOpacityRamp` / `setTransformRamp` /
    /// `setCropRectangleRamp`）は**区間内を線形補間する**ため、`parameters` が
    /// 折れ線になる種類（`fadeToBlack`）は折れ点で区間を割らないと再現できない。
    /// S8 の `VideoCompositionFactory` はこの分割点だけを見てランプを分割し、
    /// 各区間の端点値を `parameters(progress:side:)` から取る（分割点の知識も
    /// 数式も二重実装しない）。
    ///
    /// `fadeToBlack` の折れ点は黒ホールドの両端（`blackHoldFraction` から導出）。
    /// 定数を直接書かないので、ホールド割合を変えれば instruction の分割も追従する。
    ///
    /// 「各区間の中で `parameters` が本当に線形か」は
    /// `TransitionRampTests` が全種類・全区間について中点で検証している。
    public var rampBreakpoints: [Double] {
        guard self == .fadeToBlack else { return [0, 1] }
        let r = Self.fadeToBlackRampFraction
        return [0, r, 1 - r, 1]
    }

    // MARK: - ランドマークの視覚変換（重なり区間の union 用）

    /// 片側クリップの顔ランドマークに、この進行度の視覚変換を適用する。
    ///
    /// 重なり区間では画面に 2 クリップが同時に映るため、両側の顔にモザイクが要る。
    /// 呼び出し側は `TimelineMapping.sourceLocations(at:)` の各要素についてこれを呼び、
    /// 結果を連結（union）して描画・書き出しへ渡す。
    ///
    /// - 完全に不可視（不透明度 0）の側は空を返す。
    /// - 1 点でも可視領域に残る顔は**全点を平行移動して残す**。ワイプの境界を跨ぐ顔で
    ///   点を間引くとメッシュが壊れるため、はみ出しぶんはモザイクが余分に載る側に倒す
    ///   （モザイクの過剰適用は安全側、不足は事故）。
    /// - 可視判定・移動量ともに `transformPoint` / `parameters` を使う（数式の単一情報源）。
    public func visibleLandmarks(_ sets: [FaceLandmarkSet],
                                 progress: Double,
                                 side: TransitionSide) -> [FaceLandmarkSet] {
        let params = parameters(progress: progress, side: side)
        guard params.opacity > 0 else { return [] }
        let dx = Float(params.translation.dx)
        let dy = Float(params.translation.dy)
        return sets.compactMap { set in
            let anyVisible = set.points.contains { point in
                transformPoint(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                               progress: progress, side: side) != nil
            }
            guard anyVisible else { return nil }
            guard dx != 0 || dy != 0 else { return set }
            return FaceLandmarkSet(
                points: set.points.map { FaceLandmark(x: $0.x + dx, y: $0.y + dy, z: $0.z) },
                confidence: set.confidence)
        }
    }

    // MARK: - 2 レイヤ合成（AVVideoComposition のレイヤ順）

    /// 重なり区間を「前面 = outgoing / 背面 = incoming」の 2 レイヤで合成するとき、
    /// **背面レイヤ**に設定すべき不透明度。
    ///
    /// AVFoundation のレイヤ合成は前面から順に over 合成する:
    ///
    ///     結果 = a_front·F + (1 − a_front)·(a_back·B)
    ///
    /// 一方 `parameters` が表す意図は「a_out·O + a_in·I（残りは黒）」なので、
    /// 前面（outgoing）に a_out をそのまま与えたうえで、背面には
    /// `a_back = a_in / (1 − a_out)` を与えると意図と厳密に一致する。
    /// a_out = 1（スライド・ワイプのように 2 クリップが**画面上で重ならない**種類）は
    /// 除算が定義できないので a_in をそのまま使う（重なりが無いので前面が背面を
    /// 隠すだけであり、どちらでも結果は同じ）。
    ///
    /// 具体値: crossfade は常に 1（= 正しいクロスフェード。素直に a_in = p を
    /// 与えると中間で黒が透けて暗くなる）、fadeToBlack は暗転区間と黒ホールド区間で 0・
    /// 明転区間で `(p−(1−r))/r`（黒を挟む意図がそのまま出る）、slide/wipe は 1。
    /// いずれも `rampBreakpoints` の各区間内で progress の線形関数になるため、
    /// AVFoundation の線形ランプで誤差なく表現できる（`TransitionRampTests` が固定）。
    ///
    /// **区間の内部でだけ評価すること。** 端点は a_out = 1 になり得て 0/0
    /// （crossfade の p=0 など）になる。ランプの端点値は `incomingLayerOpacityRamp`
    /// が内部の 2 点から外挿して求める。
    func incomingLayerOpacityInside(progress: Double) -> Double {
        let outgoing = parameters(progress: progress, side: .outgoing).opacity
        let incoming = parameters(progress: progress, side: .incoming).opacity
        let denominator = 1 - outgoing
        // 前面が画面全体を不透明で覆う種類（slide/wipe）は割れない。これらは
        // 「前面が translate / crop で画面の一部しか占めない」ので、覆われていない
        // 領域には背面がそのまま出るのが意図（= a_in をそのまま使う）。
        guard denominator > 0 else { return incoming }
        return min(1, max(0, incoming / denominator))
    }

    /// `rampBreakpoints` の 1 区間ぶんの、背面（incoming）レイヤの不透明度ランプ端点。
    ///
    /// 端点そのものは 0/0（a_out = 1 かつ a_in = 0）になり得るため、**区間内部の
    /// 2 点（1/4 と 3/4）を評価して線形外挿する**。区間内が線形であることは
    /// `rampBreakpoints` の契約そのもので、`TransitionRampTests` が全種類について
    /// 中点検証で固定している。
    public func incomingLayerOpacityRamp(from lower: Double,
                                         to upper: Double) -> (start: Double, end: Double) {
        let span = upper - lower
        guard span > 0 else {
            let value = incomingLayerOpacityInside(progress: lower)
            return (value, value)
        }
        let first = incomingLayerOpacityInside(progress: lower + span * 0.25)
        let second = incomingLayerOpacityInside(progress: lower + span * 0.75)
        let start = min(1, max(0, 1.5 * first - 0.5 * second))
        let end = min(1, max(0, 1.5 * second - 0.5 * first))
        return (start, end)
    }
}

/// クリップ境界 1 箇所に付くトランジションの指定。
///
/// `TimelineState.transitions` では**先行クリップの id** をキーに保持される。
/// duration は「min(両クリップ合成尺)/2 以下」の制約を持つ（`TimelineState` の編集操作がクランプし、
/// `TimelineMapping` も防御的に同じ制約でクランプする）。
public struct TransitionSpec: Codable, Equatable, Sendable {
    /// トランジションの最小尺（秒）。編集操作のクランプ結果がこれを下回る場合は破棄される。
    public static let minimumDuration: Double = 0.1

    public var kind: TransitionKind
    /// 重なり区間の長さ（秒）。
    public var duration: Double

    public init(kind: TransitionKind, duration: Double) {
        self.kind = kind
        self.duration = duration
    }
}
