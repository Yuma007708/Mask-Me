import Metal
import MosaicCore

/// **写真の絵を作る唯一の関数。** 色調補正・モザイク・テキスト・透かしを常に
/// 「回転 → 色調 → 顔/矩形モザイク → 背景モザイク → テキスト → 透かし」の固定順で通す
/// （`ColorGradeCompositor` の型 doc・崩さない規則 1・4、動画側の描画順と同じ順序 +
/// 写真モード底上げ 第5段で先頭に回転を追加。
/// `Tests/MosaicCoreTests/RenderStageOrderTests.swift` がこの順序をソース走査で固定する）。
///
/// **回転を先頭に置くのは「回転してもテキスト/ステッカー・透かしは回らない」を構造で
/// 満たすため。** テキスト・透かしは回転後のフレーム座標で最後に載るので、
/// 「回転したかどうか」で分岐するコードが 1 つも要らない。
///
/// 中身は既存の `MosaicRenderer.renderOrientedToNewTexture` / `ColorGradeCompositor.apply` /
/// `MosaicRenderer.renderToNewTexture` / `MosaicRenderer.renderBackgroundToNewTexture` /
/// `TextOverlayCompositor.apply` / `WatermarkCompositor.apply` を並べるだけ。
/// **写真専用の合成器は新設しない**（`PhotoRenderPipelineParityTests
/// .testOnlyThreeFilesMayCallCompositors` が
/// この関数・`MosaicPreviewController+Rendering.swift`・`VideoMosaicExporter.swift` の
/// 3 ファイル以外がこれらの合成器を直接呼んでいないことを機械的に固定している）。
///
/// **検出はこの関数の外で、この関数に渡す前の生バッファに対して行うこと。**
/// `ColorGradeCompositor` の規則 3（検出は必ず補正前のバッファで行う）が写真側でも
/// そのまま適用される。`MosaicEditorModel.load(image:)` は `normalized`（生画像）に対して
/// 検出を 1 回だけ行い、この関数の戻り値を検出へ戻すことは無い。
/// **回転で再検出もしない**（上下逆・横倒しの顔は検出率が落ちるので、再検出は検出退行）。
///
/// **`needsWatermark` の判定はここで行わない。** 呼び出し側（`renderPreview()`）が
/// `entitlements.isPro` を見て渡す（`PhotoRenderPipelineParityTests
/// .testPhotoRenderPipelineDoesNotReadEntitlements` が固定している）。
enum PhotoRenderPipeline {
    /// モザイク関連の入力をまとめた束（`render` の引数を `function_parameter_count` の
    /// 上限内へ収めるための集約。意味的なグループ化以上の役割は無い）。
    struct MosaicInput {
        /// 顔モザイクの対象（顔タブが OFF、または選択顔が無ければ空配列）。
        ///
        /// **素材フレーム基準のまま渡すこと（`layout.remapStill` を呼び出し側で
        /// 掛けないこと）。** 回転後のフレームへの写像はこの関数の内部で
        /// `layout.remapStill(landmarkSets)` として 1 回だけ行う（二重に掛けると
        /// 顔がずれて素通しになる）。
        let landmarkSets: [FaceLandmarkSet]
        /// 手動矩形など、顔ランドマーク以外の追加マスク領域。
        ///
        /// **すでに合成（＝回転後）フレーム基準のピクセル座標で焼き込み済みであること。**
        /// `MosaicEditorModel.objectMaskPaths(for:atComposition:)` が
        /// `ObjectMaskResolver.placements(...)` 経由で `layout.remapStill` を掛けた
        /// 矩形を、回転後の出力サイズで焼き込んでいる（写像は `ObjectMaskResolver` 側の
        /// 責務——`objectMaskPlacements` の doc 参照）。ここで再度写像は掛けない。
        let additionalPaths: [FaceMaskBuilder.RegionPath]
        /// 背景モザイクに使うマスク（背景タブが OFF、または未計算なら nil）。
        ///
        /// **素材フレーム基準のまま渡すこと。** `layout.remapStill(backgroundMask)` を
        /// この関数の内部で 1 回だけ掛ける（人物/背景セグメンテーションは回転前の
        /// 生画像に対して行われているため）。
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

    /// テキスト・透かし関連の入力をまとめた束（`MosaicInput` と同じ理由の集約。
    /// `render` の引数を `function_parameter_count` の上限内へ収める）。
    struct OverlayInput {
        /// `renderer.device` に紐づいたテキスト・透かしのラスタライズキャッシュ。
        let cache: TextOverlayCache
        /// 無料プランなら `true`（課金 P2）。判定そのものはここでは行わず、
        /// 呼び出し側が渡す値をそのまま使う。
        let needsWatermark: Bool

        init(cache: TextOverlayCache, needsWatermark: Bool) {
            self.cache = cache
            self.needsWatermark = needsWatermark
        }
    }

    /// - Parameters:
    ///   - source: 回転・色調補正・モザイク焼き込み**前**の生テクスチャ（検出には使わないこと）。
    ///   - photoEdit: 適用する写真編集状態。`colorGrade.isIdentity` なら
    ///     `ColorGradeCompositor.apply` が 1 パスも発行しない（ゼロコスト）。
    ///     `photoEdit.renderableTextItems` が空ならテキスト段もゼロコスト
    ///     （`TextOverlayCompositor.apply` はループが 0 回で `input` をそのまま返す）。
    ///     `photoEdit.orientation.isIdentity` なら回転段も 1 パスも発行しない
    ///     （`MosaicRenderer.renderOriented` と同じゼロコスト契約）。
    ///   - renderer: モザイクの焼き込みに使うのと同じ `MosaicRenderer`。
    ///   - layout: `MosaicEditorModel.renderLayout` をそのまま渡すこと。**この関数の中で
    ///     `TimelineRenderLayout` を新たに組み立てないこと**（UI 入力側が使うレイアウトと
    ///     別インスタンスになり、将来 `stillPlacement`（クロップ）が入ったとき描画だけ
    ///     取り残される）。顔ランドマーク・背景マスクの回転後フレームへの写像に使う
    ///     （`layout.remapStill(...)`。**`layout.remap(..., clipID: nil)` と書かないこと**——
    ///     `clipID: nil` は「クリップ未登録」の意味であって静止画の意味ではなく、
    ///     `stillPlacement`/`stillOrientation` を無視して回転が黙って効かなくなる）。
    ///   - mosaic: 顔モザイク・手動矩形・背景モザイクの入力（`MosaicInput`）。
    ///   - overlay: テキスト・透かしの入力（`OverlayInput`）。
    /// - Returns: 回転・色調補正・モザイク・テキスト・透かしを適用済みのテクスチャ。
    ///   Metal 側の確保に失敗した箇所は直前の結果をそのまま素通しする
    ///   （`renderOriented` / `ColorGradeCompositor.apply` / `renderToNewTexture` /
    ///   `renderBackgroundToNewTexture` / `TextOverlayCompositor.apply` /
    ///   `WatermarkCompositor.apply` と同じ「失敗時は入力を返す」契約を踏襲する）。
    ///
    /// `layout` の既定値は `.identity`（回転無し・素材フレーム基準のまま素通し）。
    /// 写真モード底上げ 第1〜3段で書かれた既存テスト（`PhotoTextBurnInTests` /
    /// `PhotoWatermarkBurnInTests`）は `layout` を渡さずに直接呼んでおり、既定値を
    /// 無変換にすることでそれらの挙動を 1 バイトも変えない
    /// （`renderPreview()` は必ず `MosaicEditorModel.renderLayout` を明示で渡す）。
    static func render(
        source: MTLTexture,
        photoEdit: PhotoEditState,
        renderer: MosaicRenderer,
        layout: TimelineRenderLayout = .identity,
        mosaic: MosaicInput,
        overlay: OverlayInput
    ) -> MTLTexture {
        // 0) 回転（写真モード底上げ 第5段）。**必ず色調補正より前。** ここを先頭に置くことで
        //    テキスト・透かし（末尾の段）は「回転後のフレーム座標」にそのまま乗るので
        //    「回転してもテキスト/透かしは回らない」が条件分岐なしで成り立つ。
        let orientation = layout.stillOrientation
        let rotated = orientation.isIdentity
            ? source
            : (renderer.renderOrientedToNewTexture(input: source, orientation: orientation) ?? source)

        // 1) 色調補正（モザイクより前。`ColorGradeCompositor` の崩さない規則 1）。
        let graded = ColorGradeCompositor.apply(grade: photoEdit.colorGrade, renderer: renderer, input: rotated)

        var current = graded

        // 2) 顔モザイク（立体メッシュ）＋手動矩形。両者は独立に ON/OFF するが、
        //    1 回の `renderToNewTexture` に両方渡す（従来どおり。2 回描くと重なった部分が
        //    二重にブロック化されて濃さが変わる）。
        //    顔ランドマークは素材フレーム基準のまま渡ってくるので、回転後フレームへ
        //    ここで 1 回だけ写す（`additionalPaths` は呼び出し側ですでに写像済み。
        //    `MosaicInput` の doc 参照）。
        let orientedLandmarks = layout.remapStill(mosaic.landmarkSets)
        if !orientedLandmarks.isEmpty || !mosaic.additionalPaths.isEmpty {
            if let result = renderer.renderToNewTexture(
                input: current, landmarkSets: orientedLandmarks, additionalPaths: mosaic.additionalPaths
            ) {
                current = result.texture
            }
        }

        // 3) 背景モザイク（平面）。人物前景を反転したマスクで背景だけを処理する。
        //    セグメンテーションは回転前の生画像に対して行われているため、ここで
        //    マスクを回転後フレームへ写してから使う（`MaskBuffer.oriented` は
        //    90 度単位・補間なしで画素を完全保存する）。
        if let backgroundMask = mosaic.backgroundMask {
            let orientedMask = layout.remapStill(backgroundMask)
            if let out = renderer.renderBackgroundToNewTexture(
                input: current, mask: orientedMask, block: mosaic.backgroundBlockSize
            ) {
                current = out
            }
        }

        // 4) テキスト・ステッカー。「どれが出ているか」の判断はここでは行わない
        //    （`photoEdit.renderableTextItems` を経由済みの配列をそのまま渡す）。
        current = TextOverlayCompositor.apply(
            items: photoEdit.renderableTextItems, at: 0, renderer: renderer, cache: overlay.cache, input: current
        )

        // 5) 無料プランの透かし（課金 P2）。常に最後に重ねる。
        if overlay.needsWatermark {
            current = WatermarkCompositor.apply(renderer: renderer, cache: overlay.cache, input: current)
        }

        return current
    }
}
