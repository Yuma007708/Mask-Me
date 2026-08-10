import XCTest

/// プレビューのピンチズーム／パンの**指の操作**の検証（XCUITest）。
///
/// `TimelineGestureUITests` と同じ理由でここでしか捕まえられない: 2 本指と 1 本指の
/// どちらがジェスチャを取るかは実際に触らないと決まらない（純ロジックのテストは
/// `PreviewZoomSessionTests` / `PreviewZoomMathTests` が別に固定している）。
///
/// 前提: `-uiTestSeedVideo` 付きで起動すると、合成した 10 秒の動画で編集画面へ
/// 直行する（`UITestBootstrap`）。プレビュー全体の当たり判定は `editor.previewArea`
/// （`EditorView+Preview.swift`。`.accessibilityElement(children: .contain)` 済みなので
/// 子の識別子は上書きしない）で取る。ズームの値は探針 `editor.previewZoom` の
/// `accessibilityValue` を読む（`VideoControlsView.swift` の `editor.currentTime` と同じ流儀）。
final class PreviewZoomUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedVideo"]
        app.launch()
        XCTAssertTrue(app.otherElements["timeline.clipBand"].waitForExistence(timeout: 120),
                      "編集画面のクリップ帯が出てこない（種の動画の生成か読み込みで失敗）")
        XCTAssertTrue(zoomProbe.waitForExistence(timeout: 30), "ズームの探針が出てこない")
        // **要素が出ただけでは足りない。** 編集画面は読み込み完了を待たずに開く
        // （`TimelineGestureUITests` と同じ理由）。再生ボタンが押せるようになった
        // 時点＝読み込み完了を待つ。
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "再生ボタンが出てこない")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed,
                       "読み込みが終わらない（再生ボタンが有効にならない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - ピンチでズーム

    /// ピンチすると拡大される。
    func test_pinchOnPreview_zoomsIn() {
        previewElement().pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertGreaterThan(zoomScale(), 1.000, "ピンチしても探針の倍率が 1 倍のまま")
    }

    /// 縮小方向へピンチしても fit（1 倍）より縮まない。
    func test_pinchOut_neverGoesBelowFit() {
        previewElement().pinch(withScale: 0.3, velocity: -1)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(zoomScale(), 1.000, accuracy: 0.001,
                       "fit より縮む方向へピンチすると 1 倍を割り込んだ")
    }

    // MARK: - ダブルタップでリセット

    /// ダブルタップで等倍へ戻る。
    func test_doubleTapOnPreview_resetsZoom() {
        previewElement().pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertGreaterThan(zoomScale(), 1.000, "前提: ピンチで拡大していること")

        previewElement().doubleTap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(zoomScale(), 1.000, accuracy: 0.001,
                       "ダブルタップしても等倍へ戻らない")
    }

    // MARK: - 矩形ツールとの取り合い

    /// **ピンチで矩形が生えないことの番人。** 矩形ツール ON 中は 1 本指ドラッグで
    /// 新規矩形を作る面が全面に張られる。2 本指ピンチがそこへ誤って拾われると
    /// 「ピンチしたら矩形が 1 個できた」になる（`RectangleDrawingOverlay` の doc 参照）。
    func test_pinchWithRectangleToolOn_doesNotCreateMask() {
        openRectangleRoute()

        let before = app.otherElements.matching(identifier: "editor.objectMask").count
        previewElement().pinch(withScale: 2, velocity: 1)
        Thread.sleep(forTimeInterval: 0.4)
        let after = app.otherElements.matching(identifier: "editor.objectMask").count

        XCTAssertEqual(before, after, "矩形ツール ON 中のピンチで矩形ができてしまった")
    }

    /// 矩形を 1 個置いてからピンチしても、矩形の正規化位置が変わらない
    /// （`isZoomGestureActive` がドラッグ面を切る前提。切れていないと「掴んでいた
    /// 矩形が指 1 本ぶんだけ飛ぶ」——ピンチの片方の指を単独ドラッグとして拾うため）。
    func test_zoomedIn_maskDoesNotJumpOnPinch() {
        openRectangleRoute()
        dragOnPreview()

        let masks = app.otherElements.matching(identifier: "editor.objectMask")
        XCTAssertEqual(masks.count, 1, "前提: 矩形が 1 個置けていること")
        let before = masks.firstMatch.frame

        previewElement().pinch(withScale: 1.6, velocity: 1)
        Thread.sleep(forTimeInterval: 0.4)
        // 拡大自体で矩形の画面上の見た目は動いてよい（絵ごと拡大されるため）。
        // ここで検出したい事故は「指 1 本ぶんだけ飛ぶ」——ピンチを解いて等倍へ
        // 戻したときに、ピンチ前と同じ位置へ戻ることで正規化位置が保たれているかを見る。
        previewElement().doubleTap()
        Thread.sleep(forTimeInterval: 0.4)
        let after = masks.firstMatch.frame

        XCTAssertEqual(before.midX, after.midX, accuracy: 2,
                       "ピンチ前後で矩形の位置が変わった（正規化座標がずれた）")
        XCTAssertEqual(before.midY, after.midY, accuracy: 2,
                       "ピンチ前後で矩形の位置が変わった（正規化座標がずれた）")
    }

    // MARK: - 画面比率変更でリセット

    /// 画面比率を変えるとズームが 1 倍へ戻る（`onChange(of: model.previewImage?.size)`）。
    /// 「比率」はドックの最上段に直接あるツール項目（`VideoTimelineView+Toolbar.aspectRatioItem`）
    /// で、「モザイク」の下ではない。
    func test_afterAspectRatioChange_zoomResets() {
        previewElement().pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertGreaterThan(zoomScale(), 1.000, "前提: ピンチで拡大していること")

        let ratio = app.buttons["比率"]
        XCTAssertTrue(ratio.waitForExistence(timeout: 15), "ドックに「比率」が無い")
        ratio.tap()
        // **要素の型を決め打ちしない**（`TimelineGestureUITests.element(_:)` と同じ理由）。
        let square = app.descendants(matching: .any)
            .matching(identifier: "editor.aspectRatio.1x1").firstMatch
        XCTAssertTrue(square.waitForExistence(timeout: 10), "比率シートに 1:1 が無い")
        square.tap()
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertEqual(zoomScale(), 1.000, accuracy: 0.001,
                       "画面比率を変えてもズームが 1 倍へ戻らない")
    }

    // MARK: - 補助

    private var zoomProbe: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "editor.previewZoom").firstMatch
    }

    /// ピンチ／ダブルタップの対象。**`otherElements` で決め打ちしない**——
    /// `.accessibilityElement(children: .contain)` を付けたコンテナは環境によって
    /// 露出する型が揺れることがあるため、`element(_:)` と同じく型を問わずに探す
    /// （`TimelineGestureUITests.element(_:)` と同じ理由）。
    private func previewElement() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "editor.previewArea").firstMatch
    }

    private func zoomScale() -> Double {
        guard let raw = zoomProbe.value as? String, let scale = Double(raw) else {
            XCTFail("ズームの倍率が読めない（editor.previewZoom の value が数値でない）")
            return .nan
        }
        return scale
    }

    private func openRectangleRoute() {
        openMosaicMenu()
        let rect = app.buttons["矩形"]
        XCTAssertTrue(rect.waitForExistence(timeout: 10), "ドックに「矩形」が無い")
        rect.tap()
    }

    private func openMosaicMenu() {
        let mosaic = app.buttons["モザイク"]
        XCTAssertTrue(mosaic.waitForExistence(timeout: 15), "ドックに「モザイク」が無い")
        mosaic.tap()
    }

    /// プレビュー中央を斜めに払う（矩形を描く操作。`TimelineGestureUITests.dragOnPreview`
    /// と同じ手筋）。
    private func dragOnPreview() {
        let screen = app.windows.firstMatch.frame
        let start = point(x: screen.midX - 60, y: screen.height * 0.3)
        let end = point(x: screen.midX + 60, y: screen.height * 0.3 + 120)
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
}
