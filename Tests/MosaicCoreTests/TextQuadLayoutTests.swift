import XCTest
@testable import MosaicCore

/// E3-2: `TextQuadLayout`（px 換算の唯一の入口）と `Sequence.visibleTextItems`
/// （`TimelineState.visibleTextItems` と `VideoMosaicExporter` が共有する選択ロジック）。
final class TextQuadLayoutTests: XCTestCase {
    // MARK: - TextQuadLayout.compute

    /// fontSize は出力枠**高さ**に対する比。等倍時（scale 1）は
    /// `rasterSize` を `(fontSize * canvasHeight) / referenceFontPoints` で一様に縮小する。
    func test_compute_scalesUniformlyByCanvasHeight() {
        let style = TextStyle(fontSize: 0.1)  // 出力枠高さの 10%
        let layout = TextQuadLayout.compute(
            center: .center,
            style: style,
            rasterSize: (width: 400, height: 200),
            canvasSize: (width: 1920, height: 1080),
            renderParameters: .identity
        )
        let expectedScale = (0.1 * 1080) / TextRasterConstants.referenceFontPoints
        XCTAssertNotNil(layout)
        XCTAssertEqual(layout?.width ?? 0, 400 * expectedScale, accuracy: 1e-9)
        XCTAssertEqual(layout?.height ?? 0, 200 * expectedScale, accuracy: 1e-9)
    }

    /// 出力枠に対する解像度が違っても（プレビュー 720px 幅 vs 書き出し原寸）、
    /// 同じ `fontSize` なら文字が画面に占める比率は同じでなければならない
    /// （プレビューと書き出しで文字の大きさが食い違わない、という設計要件そのもの）。
    func test_compute_sameFontSizeRatio_acrossDifferentCanvasResolutions() {
        let style = TextStyle(fontSize: 0.08)
        let raster = (width: 300.0, height: 150.0)

        let preview = TextQuadLayout.compute(
            center: .center, style: style, rasterSize: raster,
            canvasSize: (width: 720, height: 405), renderParameters: .identity)
        let export = TextQuadLayout.compute(
            center: .center, style: style, rasterSize: raster,
            canvasSize: (width: 1920, height: 1080), renderParameters: .identity)

        XCTAssertNotNil(preview)
        XCTAssertNotNil(export)
        // 高さに対する比が両解像度で一致する。
        let previewRatio = (preview?.height ?? 0) / 405
        let exportRatio = (export?.height ?? 0) / 1080
        XCTAssertEqual(previewRatio, exportRatio, accuracy: 1e-9)
    }

    /// `center` は出力枠に対する 0...1。矩形は中心基準に置かれる。
    func test_compute_centersQuadOnNormalizedCenter() {
        let layout = TextQuadLayout.compute(
            center: NormalizedPoint(x: 0.5, y: 0.5),
            style: TextStyle(fontSize: TextStyle.defaultFontSize),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: 1000, height: 1000),
            renderParameters: .identity
        )
        XCTAssertNotNil(layout)
        let midX = (layout?.originX ?? 0) + (layout?.width ?? 0) / 2
        let midY = (layout?.originY ?? 0) + (layout?.height ?? 0) / 2
        XCTAssertEqual(midX, 500, accuracy: 1e-6)
        XCTAssertEqual(midY, 500, accuracy: 1e-6)
    }

    /// `renderParameters.scale` はビットマップの一様スケールへそのまま乗る（scaleUp アニメーション）。
    func test_compute_appliesAnimationScale() {
        let identity = TextQuadLayout.compute(
            center: .center, style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: 1000, height: 1000), renderParameters: .identity)
        let halfScale = TextQuadLayout.compute(
            center: .center, style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: 1000, height: 1000),
            renderParameters: TextRenderParameters(opacity: 1, offsetX: 0, offsetY: 0, scale: 0.5))

        XCTAssertNotNil(identity)
        XCTAssertNotNil(halfScale)
        XCTAssertEqual(halfScale?.width ?? 0, (identity?.width ?? 0) * 0.5, accuracy: 1e-9)
    }

    /// `renderParameters.opacity` はそのまま `layout.opacity` へ運ばれる。
    func test_compute_carriesOpacityThrough() {
        let layout = TextQuadLayout.compute(
            center: .center, style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: 1000, height: 1000),
            renderParameters: TextRenderParameters(opacity: 0.42, offsetX: 0, offsetY: 0, scale: 1))
        XCTAssertEqual(layout?.opacity ?? -1, 0.42, accuracy: 1e-9)
    }

    /// 非有限・0 以下の入力は必ず nil（NaN 汚染をこの関数の境界で止める）。
    func test_compute_rejectsNonFiniteAndZeroSizedInputs() {
        XCTAssertNil(TextQuadLayout.compute(
            center: .center, style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 0, height: 100),
            canvasSize: (width: 1000, height: 1000), renderParameters: .identity))
        XCTAssertNil(TextQuadLayout.compute(
            center: .center, style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: .nan, height: 1000), renderParameters: .identity))
        XCTAssertNil(TextQuadLayout.compute(
            center: NormalizedPoint(x: .infinity, y: 0.5), style: TextStyle(fontSize: 0.1),
            rasterSize: (width: 200, height: 100),
            canvasSize: (width: 1000, height: 1000), renderParameters: .identity))
    }

    // MARK: - Sequence.visibleTextItems

    private func item(_ text: String = "t", start: Double, duration: Double) -> TextItem {
        TextItem(text: text, compositionStart: start, duration: duration)
    }

    /// `TimelineState.visibleTextItems` と同じ選択規則（半開区間・compositionStart 昇順）を、
    /// 素の配列に対しても提供する（`VideoMosaicExporter` が `TimelineState` を経由せず
    /// `[TextItem]` だけを受け取るための共有経路）。
    func test_visibleTextItems_filtersToHalfOpenIntervalAndSortsByStart() {
        let items = [
            item("late", start: 5, duration: 2),
            item("early", start: 0, duration: 3)
        ]
        let visible = items.visibleTextItems(atComposition: 1, totalDuration: 10)
        XCTAssertEqual(visible.map(\.text), ["early"])

        let bothVisible = items.visibleTextItems(atComposition: 5, totalDuration: 10)
        // "late" が start=5 で可視、"early" は [0,3) なので 5 は含まない。
        XCTAssertEqual(bothVisible.map(\.text), ["late"])
    }

    /// `TimelineState.visibleTextItems` を経由しても、配列版と結果が一致すること
    /// （二重実装ではなく同じ経路であることの回帰テスト）。
    func test_timelineStateVisibleTextItems_matchesArrayExtension() {
        let source = UUID()
        let items = [item("a", start: 0, duration: 4), item("b", start: 2, duration: 4)]
        let state = TimelineState(
            clips: [TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)],
            textItems: items,
            sources: [source: TimelineSource(id: source, kind: .video)]
        )
        let time = 3.0
        let totalDuration = 10.0
        XCTAssertEqual(
            state.visibleTextItems(atComposition: time, totalDuration: totalDuration).map(\.id),
            state.textItems.visibleTextItems(atComposition: time, totalDuration: totalDuration).map(\.id)
        )
    }
}
