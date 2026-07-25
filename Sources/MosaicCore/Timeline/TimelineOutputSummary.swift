import CoreGraphics
import Foundation

/// 出力フォーマットについて、UI で注意表示を出すための判定（純関数）。
///
/// 出力解像度（renderSize）は先頭クリップ基準で決まり、他のクリップは
/// アスペクトフィット（レターボックス）で収まる。並べ替えで先頭が変わると
/// 出力解像度も変わるが、ユーザーには何も伝わっていなかった。
///
/// **renderSize そのものの算出は `VideoCompositionFactory.renderSize(for:)`（アプリ層）に
/// 単一実装のまま残す。** ここに再実装すると分岐が二重管理になり、片方だけ直して
/// 表示と実出力が食い違う事故になる。ここは算出済みの renderSize を受け取るだけ。
public enum TimelineOutputSummary {
    /// 「縮小されている」と見なす下限。
    /// スケールがちょうど 1.0 付近の浮動小数点誤差で注意表示が点滅しないようにする
    /// （1e-9 未満の縮小はユーザーにとって等倍と区別できない）。
    private static let scaleEpsilon: CGFloat = 1e-9

    /// 出力枠（`renderSize`）より大きく、縮小されて収まるクリップの index 集合。
    ///
    /// 判定は `AspectFit.placement`（`scale = min(幅比, 高さ比)`）と同じ写像に揃えてあり、
    /// `scale < 1` のとき縮小されると見なす。等倍・拡大（出力枠より小さい素材）は含まない。
    ///
    /// 非有限・非正のサイズは判断材料が無いので無視する（`AspectFit` と同じ倒し方）:
    /// - `renderSize` が不正なら空配列
    /// - 個々の `displaySizes` の要素が不正ならその index を飛ばす
    ///
    /// - Parameters:
    ///   - renderSize: 出力解像度（先頭クリップ基準で算出済みのもの）。
    ///   - displaySizes: クリップの表示サイズ（向き適用後）。`clips` と同じ順序。
    /// - Returns: 縮小されるクリップの index（昇順）。
    public static func downscaledIndices(renderSize: CGSize, displaySizes: [CGSize]) -> [Int] {
        guard renderSize.width.isFinite, renderSize.height.isFinite,
              renderSize.width > 0, renderSize.height > 0 else { return [] }
        return displaySizes.indices.filter { index in
            let size = displaySizes[index]
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return false }
            let scale = min(renderSize.width / size.width, renderSize.height / size.height)
            return scale < 1 - scaleEpsilon
        }
    }
}
