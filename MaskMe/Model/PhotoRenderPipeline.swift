import Metal
import MosaicCore

/// **写真の絵を作る唯一の関数。** 色調補正・モザイクを常に「色調 → モザイク」の
/// 固定順で通す（`ColorGradeCompositor` の型 doc・崩さない規則 1 と同じ順序。
/// 動画側の描画順「色調 → 顔/矩形モザイク → 背景モザイク → テキスト → 透かし」から、
/// 写真モードにまだ無いテキスト・透かしを除いた形になっている）。
///
/// 中身は既存の `ColorGradeCompositor.apply` / `MosaicRenderer.renderToNewTexture` /
/// `MosaicRenderer.renderBackgroundToNewTexture` を並べるだけ。**写真専用の合成器は
/// 新設しない**（`PhotoRenderPipelineParityTests.testOnlyThreeFilesMayCallCompositors` が
/// この関数・`MosaicPreviewController+Rendering.swift`・`VideoMosaicExporter.swift` の
/// 3 ファイル以外がこれらの合成器を直接呼んでいないことを機械的に固定している）。
///
/// **検出はこの関数の外で、この関数に渡す前の生バッファに対して行うこと。**
/// `ColorGradeCompositor` の規則 3（検出は必ず補正前のバッファで行う）が写真側でも
/// そのまま適用される。`MosaicEditorModel.load(image:)` は `normalized`（生画像）に対して
/// 検出を 1 回だけ行い、この関数の戻り値を検出へ戻すことは無い。
enum PhotoRenderPipeline {
    /// モザイク関連の入力をまとめた束（`render` の引数を `function_parameter_count` の
    /// 上限内へ収めるための集約。意味的なグループ化以上の役割は無い）。
    struct MosaicInput {
        /// 顔モザイクの対象（顔タブが OFF、または選択顔が無ければ空配列）。
        let landmarkSets: [FaceLandmarkSet]
        /// 手動矩形など、顔ランドマーク以外の追加マスク領域。
        let additionalPaths: [FaceMaskBuilder.RegionPath]
        /// 背景モザイクに使うマスク（背景タブが OFF、または未計算なら nil）。
        let backgroundMask: MaskBuffer?
        /// 背景モザイクのブロックサイズ。
        let backgroundBlockSize: Float

        init(landmarkSets: [FaceLandmarkSet] = [],
             additionalPaths: [FaceMaskBuilder.RegionPath] = [],
             backgroundMask: MaskBuffer? = nil,
             backgroundBlockSize: Float = 28) {
            self.landmarkSets = landmarkSets
            self.additionalPaths = additionalPaths
            self.backgroundMask = backgroundMask
            self.backgroundBlockSize = backgroundBlockSize
        }
    }

    /// - Parameters:
    ///   - source: 色調補正・モザイク焼き込み**前**の生テクスチャ（検出には使わないこと）。
    ///   - photoEdit: 適用する写真編集状態。`colorGrade.isIdentity` なら
    ///     `ColorGradeCompositor.apply` が 1 パスも発行しない（ゼロコスト）。
    ///   - renderer: モザイクの焼き込みに使うのと同じ `MosaicRenderer`。
    ///   - mosaic: 顔モザイク・手動矩形・背景モザイクの入力（`MosaicInput`）。
    /// - Returns: 色調補正・モザイクを適用済みのテクスチャ。
    ///   Metal 側の確保に失敗した箇所は直前の結果をそのまま素通しする
    ///   （`ColorGradeCompositor.apply` / `renderToNewTexture` / `renderBackgroundToNewTexture`
    ///   と同じ「失敗時は入力を返す」契約を踏襲する）。
    static func render(
        source: MTLTexture,
        photoEdit: PhotoEditState,
        renderer: MosaicRenderer,
        mosaic: MosaicInput
    ) -> MTLTexture {
        // 1) 色調補正（モザイクより前。`ColorGradeCompositor` の崩さない規則 1）。
        let graded = ColorGradeCompositor.apply(grade: photoEdit.colorGrade, renderer: renderer, input: source)

        var current = graded

        // 2) 顔モザイク（立体メッシュ）＋手動矩形。両者は独立に ON/OFF するが、
        //    1 回の `renderToNewTexture` に両方渡す（従来どおり。2 回描くと重なった部分が
        //    二重にブロック化されて濃さが変わる）。
        if !mosaic.landmarkSets.isEmpty || !mosaic.additionalPaths.isEmpty {
            if let result = renderer.renderToNewTexture(
                input: current, landmarkSets: mosaic.landmarkSets, additionalPaths: mosaic.additionalPaths
            ) {
                current = result.texture
            }
        }

        // 3) 背景モザイク（平面）。人物前景を反転したマスクで背景だけを処理する。
        if let backgroundMask = mosaic.backgroundMask {
            if let out = renderer.renderBackgroundToNewTexture(
                input: current, mask: backgroundMask, block: mosaic.backgroundBlockSize
            ) {
                current = out
            }
        }

        return current
    }
}
