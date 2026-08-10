import Metal
import MosaicCore

/// 色調補正（明るさ・コントラスト・彩度・暖かみ）を焼き込む、プレビュー・書き出し共通の合成手順。
///
/// `TextOverlayCompositor` と役割が近い（プレビュー・書き出し両経路が同じ純粋な
/// 合成手順を通すことで、境界フレームでの結果の食い違いを防ぐ）ので同じ流儀に揃えてある。
///
/// **崩さない規則（この案件で必ず守ること）:**
/// 1. **補正はモザイクより後段に置かない。** 呼び出し側は `input` にモザイク焼き込み前の
///    生テクスチャを渡し、この関数の戻り値をモザイクの入力にすること。逆順（補正 → モザイク
///    ではなく モザイク → 補正）にすると、モザイクのブロック平均が補正後の色を平均する形になり、
///    ブロック境界の色がタイル同士で食い違う実測は無いが、少なくとも「検出は補正前を見る」
///    という下の規則 3 が成立しなくなる（検出用バッファと描画用バッファが同じ経路を通る場合に
///    限り影響する。現状は別バッファなので実害は無いが、将来 1 本化するときの罠になる）。
/// 2. **補正はモザイクの幾何に影響しない。** ここで作るのは色調補正**だけ**の out-of-place
///    パス（`MosaicRenderer.renderColorGrade`）であり、モザイクのブロック位置・回転・
///    マスク形状には一切触れない。モザイクを掛けた領域の画素は、補正の有無で色は変わっても
///    「どのブロックがどこに乗るか」は変わらない。
/// 3. **検出は必ず補正前のバッファで行う。** プレビューは `detectionCGImage(from:)`、
///    書き出しは `frame.sourceBuffer`（`MosaicPreviewController+Rendering` /
///    `VideoMosaicExporter` 参照）を検出に渡しており、どちらもこの合成器を通す前の
///    生バッファである。**この関数の戻り値を検出へ渡してはならない。** コントラストを
///    0 にする（一面グレー）ような極端な補正を検出後のバッファへ適用すると、顔検出が
///    落ちてモザイクがそもそも掛からず素通しになる（プライバシーアプリとして最悪の失敗）。
/// 4. **透かしは常に最後。** 描画順は「色調補正 → モザイク → テキスト → 透かし」固定。
///    `WatermarkCompositor` はこの合成器より後、かつ `needsWatermark` の判定は補正の
///    値を一切見ない（`ExportWatermark` の座標・不透明度は補正と無関係）。
enum ColorGradeCompositor {
    /// - Parameters:
    ///   - grade: 適用する色調補正。`.identity` なら**1 パスも発行せず** `input` を
    ///     そのまま返す（既存プロジェクトへ完全にゼロコストであることの保証点）。
    ///   - renderer: モザイクの焼き込みに使うのと同じ `MosaicRenderer`
    ///     （同じ Metal デバイス／コマンドキューを共有する）。
    ///   - input: モザイク焼き込み**前**の生テクスチャ（検出には使わないこと）。
    /// - Returns: 補正済みテクスチャ。`grade.isIdentity` または Metal 側の確保に
    ///   失敗した場合は `input` をそのまま返す（補正が効かないだけで描画自体は止めない）。
    static func apply(grade: ColorGrade, renderer: MosaicRenderer, input: MTLTexture) -> MTLTexture {
        guard !grade.isIdentity else { return input }
        return renderer.renderColorGradeToNewTexture(input: input, grade: grade) ?? input
    }
}
