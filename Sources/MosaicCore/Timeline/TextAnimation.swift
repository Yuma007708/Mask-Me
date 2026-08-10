import Foundation

/// テキストの出し方（E3）。
///
/// **見た目の数式はこのファイルの `parameters(progress:)` だけが持つ。**
/// プレビューと書き出しは必ず同じ関数を呼ぶこと。トランジション（`TransitionKind`）で
/// 確立した規約と同じで、**数式の二重実装は禁止**である（片方だけ直すと
/// 「プレビューでは滑り込むのに書き出すと出っぱなし」という食い違いが生まれ、
/// 書き出すまで気づけない）。
public enum TextAnimation: String, Codable, Sendable, CaseIterable {
    /// パッと出てパッと消える。
    case none
    /// 出入りで薄く / 濃くなる。
    case fade
    /// 下から滑り込み、下へ滑り出る。
    case slideIn
    /// 小さい状態から膨らんで出る。
    case scaleUp

    /// 出入りにかける時間（秒）。
    ///
    /// **表示時間の半分を超えない**ようにクランプする（0.4 秒のテキストに
    /// 0.3 秒ずつの出入りを付けると、最大不透明度に達しないまま消える）。
    public static let defaultTransitionDuration: Double = 0.3

    public var displayName: String {
        switch self {
        case .none: return "なし"
        case .fade: return "フェード"
        case .slideIn: return "スライド"
        case .scaleUp: return "ズーム"
        }
    }

    /// このテキストの実効的な出入り時間（秒）。表示時間の半分を上限にする。
    ///
    /// **上限のクランプはここが本体である。** `parameters(progress:transitionRatio:)` にも
    /// ratio を 0...0.5 へ収める処理があるが、あれは public API を直接叩かれたときの
    /// 保険で、**こちらのクランプを外しても向こうが吸収してしまう**（実際、変異テストで
    /// ここを固定値へ書き換えても `parameters` 経由のテストは全部緑のままだった）。
    /// 冗長な安全弁は互いを隠すので、**この関数の戻り値そのものをテストで固定する**
    /// （`test_transitionDuration_isCappedAtHalfOfItemDuration`）。
    public func transitionDuration(forItemDuration duration: Double) -> Double {
        guard self != .none, duration.isFinite, duration > 0 else { return 0 }
        return min(Self.defaultTransitionDuration, duration / 2)
    }

    /// 表示区間内の進行度 `progress`（0...1）に対する描画パラメータ。
    ///
    /// **プレビューと書き出しの唯一の入口。**
    ///
    /// - Parameter progress: `(time - compositionStart) / duration`。区間外は呼ばないこと
    ///   （呼ばれても 0...1 へクランプして返す）。
    /// - Parameter transitionRatio: 出入り時間が表示時間に占める割合（0...0.5）。
    ///   `transitionDuration(forItemDuration:) / duration` を渡す。
    public func parameters(progress: Double, transitionRatio: Double) -> TextRenderParameters {
        guard self != .none else { return .identity }
        let clampedProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let ratio = transitionRatio.isFinite ? min(max(transitionRatio, 0), 0.5) : 0
        guard ratio > 0 else { return .identity }

        // 入り: 0 → 1（先頭の ratio ぶん）、出: 1 → 0（末尾の ratio ぶん）。
        // どちらにも掛からない中央部分は 1（完全に表示された状態）。
        let entering = min(clampedProgress / ratio, 1)
        let leaving = min((1 - clampedProgress) / ratio, 1)
        let phase = min(entering, leaving)

        switch self {
        case .none:
            return .identity
        case .fade:
            return TextRenderParameters(opacity: phase, offsetX: 0, offsetY: 0, scale: 1)
        case .slideIn:
            // **入りも出も「下側」から出入りする**（下から上がってきて、下へ抜ける）。
            // 上から入って下へ抜けると通り過ぎる動きになり、字幕としては落ち着かない。
            // 移動量は出力枠の高さに対する比で、表示しきった状態（phase == 1）で 0 になる。
            return TextRenderParameters(opacity: phase, offsetX: 0,
                                        offsetY: 0.08 * (1 - phase), scale: 1)
        case .scaleUp:
            // 0.7 倍から等倍へ。出るときは逆に縮む。
            return TextRenderParameters(opacity: phase, offsetX: 0, offsetY: 0,
                                        scale: 0.7 + 0.3 * phase)
        }
    }
}

/// アニメーション 1 フレームぶんの描画パラメータ。
///
/// `offsetX` / `offsetY` は**出力枠に対する比**（px ではない。`NormalizedPoint` と同じ理由）。
public struct TextRenderParameters: Equatable, Sendable {
    public var opacity: Double
    public var offsetX: Double
    public var offsetY: Double
    public var scale: Double

    public init(opacity: Double, offsetX: Double, offsetY: Double, scale: Double) {
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
    }

    /// 変換なし（完全に表示された状態）。
    public static let identity = TextRenderParameters(opacity: 1, offsetX: 0, offsetY: 0, scale: 1)
}

extension TextItem {
    /// 指定した合成時刻でのこのテキストの描画パラメータ。区間外なら nil。
    ///
    /// **描画側はこれ 1 本だけを呼ぶこと**（進行度の計算を呼び出し側で書くと、
    /// プレビューと書き出しで丸めが揃わない）。
    public func renderParameters(atComposition time: Double) -> TextRenderParameters? {
        guard isVisible(atComposition: time), duration > 0 else { return nil }
        let progress = (time - compositionStart) / duration
        let ratio = animation.transitionDuration(forItemDuration: duration) / duration
        return animation.parameters(progress: progress, transitionRatio: ratio)
    }
}
