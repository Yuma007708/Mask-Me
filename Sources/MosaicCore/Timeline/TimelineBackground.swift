import Foundation

/// レターボックス（＝出力枠に素材が収まらないときにできる余白）の埋め方。
///
/// ## これは「余白の見た目」だけを決める
///
/// 素材は絶対に切り取らない（`TimelineAspectRatio` の doc）。収まらないぶんは切るのではなく
/// 余白になるので、その余白を何で埋めるかがここの話である。**配置矩形・顔座標の写像には
/// 一切影響しない**（`TimelineRenderLayout` は素材の置き場所だけを決める）。
///
/// ## ぼかしの安全（この案件で最も重要な点）
///
/// **ぼかしの種は必ず「モザイクを焼いた後」のフレームにすること。** 元映像から作ると、
/// 隠したい顔が余白側に大きく引き伸ばされて出る。ぼかしは隠す手段として不十分なので、
/// 素顔が薄く残った帯が書き出しに混ざることになる。
///
/// プレビューも書き出しも「合成済みフレーム（＝余白込み）を受け取ってから Metal で
/// モザイクを焼く」順序なので、**焼いた後のフレームを種にすれば構造的に安全**である。
/// 種を合成前のフレームへ差し替える変更は、この型の意味を壊す。
///
/// ## 既定は黒
///
/// 従来挙動（`AVMutableVideoCompositionInstruction` の既定の背景色）と一致させてある。
/// 保存済みの下書きに値が無ければ黒として読むので、既存データの見た目は 1 ピクセルも変わらない。
public struct TimelineBackground: Equatable, Sendable, Codable {
    /// 埋め方の種類。
    ///
    /// **`rawValue` は永続化されるので変えないこと**（下書きの復元が壊れる）。
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// 黒で塗る（既定・従来挙動）。
        case black
        /// 指定した色で塗る。
        case color
        /// モザイクを焼いた後のフレームをぼかして敷く。
        case blur

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .black: return "黒"
            case .color: return "色"
            case .blur: return "ぼかし"
            }
        }
    }

    public var kind: Kind
    /// `kind == .color` のときに使う色。**他の種類でも値は保持する**
    /// （黒 → 色 → 黒と往復したときに、選んでいた色が消えないようにするため）。
    public var color: RGBAColor
    /// ぼかしの強さ 0...1。`kind == .blur` のときだけ効く。
    /// 0 でもぼかし扱い（＝素の絵がそのまま敷かれる）にはしない——`clamped` が下限を持つ。
    public var blurStrength: Double

    public static let `default` = TimelineBackground()

    public init(kind: Kind = .black,
                color: RGBAColor = RGBAColor(red: 0.10, green: 0.12, blue: 0.30),
                blurStrength: Double = 0.6) {
        self.kind = kind
        self.color = color
        self.blurStrength = blurStrength
    }

    /// 値を安全な範囲へ収める。**非有限は既定へ落とす**（NaN が描画層まで流れると
    /// 実装依存で化ける。`RGBAColor.clamped` と同じ流儀）。
    ///
    /// ぼかしの強さは **0.25 を下限**にする。
    ///
    /// 0 を許すと「ぼかしを選んだのに何も変わらない」という、設定が壊れているのか
    /// 仕様なのか区別できない状態が作れる。加えて、**弱すぎるぼかしは背景ではなく
    /// 不具合に見える**——実際に 0.2 で書き出した画を見ると、余白にほぼ鮮明な拡大コピーが
    /// 出て「同じ絵が二重に出ている」ようにしか見えなかった（`DiagLetterboxLookTests`
    /// が出す画で確認）。中央に写っているものなので新たな情報が出るわけではないが、
    /// 意図した見た目ではない。
    public var clamped: TimelineBackground {
        var result = self
        result.color = color.clamped
        result.blurStrength = blurStrength.isFinite ? min(max(blurStrength, 0.25), 1) : 0.6
        return result
    }

    /// 実際に塗る色。**`.blur` のときも下地として使う**——ぼかしは素材の端の色を
    /// 引き伸ばすので、素材が枠より極端に小さいと種が足りない領域が出る。そこは
    /// 下地の色で埋める（`.blur` の下地は黒。ぼかしの外周が明るい色に縁取られると
    /// かえって目立つ）。
    public var fillColor: RGBAColor {
        switch kind {
        case .black, .blur: return .black
        case .color: return color.clamped
        }
    }

    /// 余白にぼかしを敷くか。
    public var usesBlur: Bool { kind == .blur }
}
