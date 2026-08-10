import CoreGraphics
import Foundation

/// 「そのバケットで**素材のどの範囲を見て**検出したか」（＝被覆）の判定。
///
/// ## なぜ要るか（プライバシー事故を塞ぐ）
///
/// `shouldDetectPreviewFrame` は「そのバケットに検出エントリがあるか」だけでライブ検出を
/// スキップする。ところが**見えている素材の範囲を狭める操作**（`ClipTransform` の
/// 拡大＝フレーム外への切り取り、切り抜き `CropRect`）が入ると、
///
/// 1. 拡大した状態で再生する → ライブ検出はフレーム外の顔を見られない
/// 2. それでもそのバケットに「検出済み」エントリが入る
/// 3. 縮小に戻す → エントリがあるのでそのバケットは二度と検出されない
/// 4. 端にいた顔が**素通しのまま固定**される
///
/// という穴になる。そこで検出エントリに「そのとき見えていた素材領域」を持たせ、
/// **記録済み可視領域 ⊇ 要求可視領域**のときだけ検出済みとみなす。
/// 拡大（可視領域が縮む）では被覆が成立するので再検出は走らず（ピンチのたびに
/// 全再走査にならない）、縮小（可視領域が広がる）でだけ再検出が走る。
///
/// ## 汎用の形にしてある（`ClipTransform` 専用にしない）
///
/// 判定は**正規化 CGRect 同士**でしか行わない。可視領域をどう求めたか
/// （変形なら `ClipTransform.visibleSourceRect(placement:)`、切り抜きなら crop 矩形）は
/// この型の関知するところではない。切り抜きも「見えている範囲を狭める」同じ穴を作るため、
/// 台帳はどちらからも共用する。
public enum DetectionCoverage {
    /// 素材全体（＝可視領域を狭める操作が無いときの被覆）。
    public static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 被覆判定の許容誤差。
    ///
    /// 可視領域は配置矩形からの割り算で毎回作り直されるため、同じ状態でも最下位ビットが
    /// 揺れる。許容 0 だと同じ幾何のまま毎フレーム再検出になる。一方で許容を大きく取ると
    /// 「新しく見えるようになった端の顔」を検出済みとみなして素通しにする。
    /// **検出の退行は誤モザイクより重い**ので、再計算誤差だけを吸える最小に寄せてある
    /// （`DetectionCoverageTests.test_わずかに広い要求は被覆されない` が 1e-6 で固定）。
    public static let tolerance: CGFloat = 1e-9

    /// `recorded`（記録済み可視領域）が `requested`（要求可視領域）を被覆しているか。
    ///
    /// - 非有限な値が混ざったら **false**（＝再検出する側）へ倒す。判断材料が無いときは
    ///   安全側＝「見ていないかもしれない」に寄せる。
    /// - `requested` が空（何も見えていない）なら true。見えていないものは検出しようがない。
    public static func covers(recorded: CGRect, requested: CGRect,
                              tolerance: CGFloat = DetectionCoverage.tolerance) -> Bool {
        guard isFinite(recorded), isFinite(requested) else { return false }
        let have = recorded.standardized
        let want = requested.standardized
        guard want.width > 0, want.height > 0 else { return true }
        guard have.width > 0, have.height > 0 else { return false }
        return have.minX - tolerance <= want.minX
            && have.minY - tolerance <= want.minY
            && have.maxX + tolerance >= want.maxX
            && have.maxY + tolerance >= want.maxY
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }
}
