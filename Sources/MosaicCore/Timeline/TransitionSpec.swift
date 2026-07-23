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
    /// 一度黒画面を挟むフェード。前半で先行クリップが退場し、後半で後続クリップが登場する。
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

    /// 進行度 `progress` における `side` 側クリップの視覚パラメータを返す純関数。
    ///
    /// 端点契約: progress=0 で outgoing が完全表示・incoming が非表示、progress=1 でその逆。
    /// 中間値は線形ランプ（fadeToBlack のみ前半/後半の区分線形）。
    /// progress は [0,1] にクランプされる（NaN は 0 扱い）。
    public func parameters(progress: Double, side: TransitionSide) -> TransitionParameters {
        let p = Self.clampedProgress(progress)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch self {
        case .fadeToBlack:
            // 前半 [0, 0.5] で outgoing が黒へ、後半 [0.5, 1] で incoming が黒から。
            let opacity = side == .outgoing ? max(0, 1 - 2 * p) : max(0, 2 * p - 1)
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
