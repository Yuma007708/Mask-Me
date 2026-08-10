import XCTest

/// クロップ編集の**排他が実際に効いているか**の end-to-end 確認（XCUITest）。
///
/// `MosaicEditorModelCropTests` / `Tests/MosaicCoreTests/PreviewInteractionPolicyTests` 等の
/// モデル・コア層のテストは「`PreviewInteractionPolicy` が正しい値を返すか」までしか見ない。
/// **各ビューが実際にその値を読んでいるか**（配線そのもの）はここでしか捕まらない
/// （`PreviewInteractionPolicy` の型 doc 参照。「S3 のコアテストは『誰も呼んでいない』場合を
/// 検出できない」——親の指摘）。
///
/// ## 顔タップではなく矩形マスクで確認する
///
/// `-uiTestSeedVideo` が作る種の動画は合成した色帯フレームで、実顔が写っていない
/// （`UITestBootstrap` の doc 参照）。そのため `FacePickOverlay`（`editor.facePick`）は
/// 一度も現れず、顔タップの排他をそのままでは UI から確認できない。
///
/// 代わりに `RectangleDrawingOverlay` の「既存マスクの編集」（`editor.objectMask`。
/// `MosaicEditorModel+Crop.swift` の型 doc の言う `allowsExistingMaskEditing`）で同じことを
/// 確認する。**こちらは顔タップより強い番人でもある**: `FacePickOverlay.isActive` は
/// 元々 `activeTab == .face && !isRectangleToolActive` で、クロップ段に入ると
/// `activeTab = nil` の副作用（`MosaicEditorModel+Dock.swift`）で自然に false へ落ちるため、
/// 配線を忘れても偶然その場では区別が付かない。一方 `allowsExistingMaskEditing` は
/// 元々「ツールの ON/OFF・段に関係なく常時 true」だったので、クロップ中に false へ
/// 落とすのは `PreviewInteractionPolicy` を実際に読んで**初めて**成立する
/// （配線を忘れると素通しで操作できてしまう＝この UI テストが落ちる）。
///
/// 前提: `-uiTestSeedVideo` 付きで起動すると合成した 10 秒の動画で編集画面へ直行する。
final class EditorCropUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedVideo"]
        app.launch()
        XCTAssertTrue(app.otherElements["timeline.clipBand"].waitForExistence(timeout: 120),
                      "編集画面のクリップ帯が出てこない（種の動画の生成か読み込みで失敗）")
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "再生ボタンが出てこない")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed,
                       "読み込みが終わらない（再生ボタンが有効にならない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// **クロップ編集中は、既存の矩形マスクを操作できない。**
    ///
    /// 判定は `isHittable` ではなく「**実際にドラッグして動かないこと**」で見る。
    /// `allowsHitTesting(false)` は指の当たり判定を切るがアクセシビリティ要素は残すため、
    /// `isHittable` は true のままになる（`.accessibilityHidden` を外から掛けても、
    /// `.accessibilityElement(children: .contain)` を持つコンテナには効かなかった）。
    /// 親が実機で両方試して確かめた。守りたいのは「掴んでも動かない」ことなので、
    /// フレームワークの当たり判定の見え方ではなく振る舞いを測る。
    func test_クロップ編集中は矩形マスクを掴んでも動かない() {
        placeRectangleMask()
        let mask = element("editor.objectMask")
        XCTAssertTrue(mask.waitForExistence(timeout: 15), "矩形ができていない")
        goToRoot()
        let before = mask.frame
        XCTAssertGreaterThan(before.width, 0, "前提: 矩形に大きさがある")

        enterCrop()
        XCTAssertTrue(element("editor.crop.handle.bottomRight").isHittable,
                      "クロップ編集中なのにクロップハンドルへ触れない")
        // 矩形の中心を掴んで大きく動かす。排他が効いていれば 1px も動かない。
        let center = mask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1,
                     thenDragTo: center.withOffset(CGVector(dx: 60, dy: 60)))
        cancelCrop()

        let after = mask.frame
        XCTAssertEqual(after.midX, before.midX, accuracy: 1,
                       "クロップ編集中に矩形が横へ動いた（排他が効いていない）")
        XCTAssertEqual(after.midY, before.midY, accuracy: 1,
                       "クロップ編集中に矩形が縦へ動いた（排他が効いていない）")

        // 取消後は従来どおり動かせること（排他が戻っている）。
        let again = mask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        again.press(forDuration: 0.1,
                    thenDragTo: again.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertNotEqual(mask.frame.midX, before.midX, accuracy: 1,
                          "クロップを取り消したのに矩形を動かせないまま（排他が戻っていない）")
    }

    func test_クロップ編集中は矩形ツールの描画面が出ない() {
        placeRectangleMask()
        goToRoot()
        let before = app.otherElements.matching(identifier: "editor.objectMask").count
        XCTAssertEqual(before, 1, "前提: 矩形マスクが 1 個だけ置いてあること")

        enterCrop()
        dragOnPreview()
        let after = app.otherElements.matching(identifier: "editor.objectMask").count
        XCTAssertEqual(after, before,
                       "クロップ編集中にプレビューを払ったら新しい矩形マスクができた"
                       + "（描画面が出ている）")
        cancelCrop()
    }

    /// **取消でクロップ前の見た目（＝出力解像度）へ戻る。**
    ///
    /// クロップは確定するまで合成へは効かない設計（`cropDraft` は下書き）なので、
    /// 「見た目が戻る」を機械的に確かめられる指標として `editor.outputSize` の
    /// `accessibilityValue`（`VideoControlsView` が持つ、書き出し解像度そのもの）を使う。
    func test_取消でクロップ前の見た目へ戻る() {
        goToRoot()
        let original = outputSizeValue()
        XCTAssertFalse(original.isEmpty, "前提: 出力解像度の表示が読めること")

        enterCrop()
        dragCropHandle(shrinking: true)
        cancelCrop()

        XCTAssertEqual(outputSizeValue(), original,
                       "クロップを取り消したのに出力解像度がクロップ前と違う"
                       + "（取消が確定と混ざっている疑い）")
    }

    /// **ハンドルをドラッグして確定すると、出力解像度の表示が変わる。**
    ///
    /// これが唯一の「結線が書き出し経路まで届いていること」の番人（親の指摘）。
    /// コア層のテスト（`CropHandleMathTests` 等）はハンドルの算術だけを見ており、
    /// その結果が実際に `MosaicEditorModel.setCrop` → composition 再構築 →
    /// `outputRenderSize` まで伝わるかは、実タップでしか確認できない。
    func test_ハンドルをドラッグして確定すると出力解像度の表示が変わる() {
        goToRoot()
        let original = outputSizeValue()
        XCTAssertFalse(original.isEmpty, "前提: 出力解像度の表示が読めること")

        enterCrop()
        dragCropHandle(shrinking: true)
        confirmCrop()

        let changed = expectation(for: NSPredicate(format: "value != %@", original),
                                  evaluatedWith: outputSizeElement())
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 30), .completed,
                       "ハンドルをドラッグして確定したのに出力解像度の表示が変わらない"
                       + "（確定が composition 再構築まで届いていない疑い）"
                       + " original=\(original) now=\(outputSizeValue())")
    }

    // MARK: - 操作

    /// ドックで「モザイク」→「矩形」へ降り、プレビューを払って手動矩形を 1 個置く。
    private func placeRectangleMask() {
        openMosaicMenu()
        let rect = app.buttons["矩形"]
        XCTAssertTrue(rect.waitForExistence(timeout: 10), "ドックに「矩形」が無い")
        rect.tap()
        XCTAssertTrue(app.buttons["editor.rectangleTool"].waitForExistence(timeout: 10),
                      "矩形の段にツールのボタンが無い")
        dragOnPreview()
        XCTAssertTrue(element("editor.objectMask").waitForExistence(timeout: 15), "矩形ができていない")
    }

    private func openMosaicMenu() {
        let mosaic = app.buttons["モザイク"]
        XCTAssertTrue(mosaic.waitForExistence(timeout: 15), "ドックに「モザイク」が無い")
        mosaic.tap()
    }

    /// どの段にいても「完了」で `root` へ戻る（`crop` 段だけは確定として振る舞うが、
    /// このヘルパーはクロップ以外の段からの復帰にだけ使う）。
    private func goToRoot() {
        let done = app.buttons["editor.dock.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// `root` から「切り抜き」を押してクロップ編集へ入る。
    private func enterCrop() {
        let crop = app.buttons["切り抜き"]
        XCTAssertTrue(crop.waitForExistence(timeout: 10), "ドックに「切り抜き」が無い")
        crop.tap()
        XCTAssertTrue(app.buttons["editor.crop.confirm"].waitForExistence(timeout: 10),
                      "クロップの段（確定ボタン）に入れていない")
    }

    private func cancelCrop() {
        let cancel = app.buttons["editor.crop.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "クロップの取消ボタンが無い")
        cancel.tap()
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func confirmCrop() {
        let confirm = app.buttons["editor.crop.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "クロップの確定ボタンが無い")
        confirm.tap()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// 右下ハンドルを内側へ引き、クロップ枠を縮める。
    private func dragCropHandle(shrinking: Bool) {
        let handle = element("editor.crop.handle.bottomRight")
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "右下のクロップハンドルが無い")
        let delta: CGFloat = shrinking ? -90 : 90
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: delta, dy: delta)))
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// プレビュー中央を斜めに払う（矩形を描く操作。`TimelineGestureUITests.dragOnPreview` と同じ）。
    private func dragOnPreview() {
        let screen = app.windows.firstMatch.frame
        let start = point(x: screen.midX - 60, y: screen.height * 0.3)
        let end = point(x: screen.midX + 60, y: screen.height * 0.3 + 120)
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - 補助

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func outputSizeElement() -> XCUIElement {
        app.staticTexts["editor.outputSize"]
    }

    private func outputSizeValue() -> String {
        (outputSizeElement().value as? String) ?? ""
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
}
