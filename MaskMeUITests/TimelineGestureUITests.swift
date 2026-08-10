import XCTest

/// タイムラインの**指の操作**の検証（XCUITest）。
///
/// ここでしか捕まえられないのは「ジェスチャの取り合い」である。誰が pan を取るかは
/// 実際に触らないと決まらないため、純ロジックのテスト（`TimelineScrollMathTests`）では
/// 素通りする。実際にこの層をすり抜けた事故:
///
/// - クリップ帯の並べ替えが `.gesture` だったため、**クリップの上を払っても
///   横スクロールしなかった**（= 中央固定のシークが効かない）
/// - 再生中は追従スクロールが毎フレーム引き戻すため、**再生中のスワイプが効かなかった**
///
/// 前提: `-uiTestSeedVideo` 付きで起動すると、合成した 10 秒の動画で編集画面へ
/// 直行する（`UITestBootstrap`）。写真ライブラリを触らないので素材の中身が変わらず、
/// 段ごとの座標を指定したドラッグが安定する。
final class TimelineGestureUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 段の識別子（`VideoTimelineView.trackStack`）。
    private enum Track {
        static let ruler = "timeline.ruler"
        static let clipBand = "timeline.clipBand"
        static let jointLane = "timeline.jointLane"
        static let applyTrack = "timeline.applyTrack"
    }

    /// 払う距離（px）。既定ズーム 40px/秒 なので約 3 秒ぶん動く。
    private static let swipeDistance: CGFloat = 120
    /// 「動いた」と見なす下限（秒）。ズーム段が変わっても成り立つよう緩く取る。
    private static let movedThreshold = 0.5
    /// 「動いていない」と見なす上限（秒）。1 コマ（1/30 秒）の誤差は許す。
    private static let stillThreshold = 0.1

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedVideo"]
        app.launch()
        // 合成動画の生成 → 読み込み → composition 構築を待つ。
        XCTAssertTrue(app.otherElements[Track.clipBand].waitForExistence(timeout: 120),
                      "編集画面のクリップ帯が出てこない（種の動画の生成か読み込みで失敗）")
        XCTAssertTrue(currentTimeElement.waitForExistence(timeout: 30))
        // **要素が出ただけでは足りない。** 編集画面は読み込み完了を待たずに開く
        // （重い初期処理——先頭フレーム・背景マスク・顔シード探索——を同期で
        // 走らせると遷移が止まるため、非同期にしてある）。この時点のクリップ帯は
        // 幅 1px のプレースホルダで、再生も previewController 未構築で効かない。
        // 再生ボタンが押せるようになった時点＝`model.isLoading` が下りた時点を待つ。
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "再生ボタンが出てこない")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"),
                               evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed,
                       "読み込みが終わらない（再生ボタンが有効にならない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 払ってシーク

    /// クリップ帯を払うとシークする。**取り合いの事故が最初に出た場所。**
    func test_swipeOnClipBand_seeks() {
        let before = currentTime()
        swipeLeft(on: Track.clipBand)
        let after = currentTime()
        XCTAssertGreaterThan(after - before, Self.movedThreshold,
                             "クリップ帯を左へ払っても再生位置が進まない（pan が奪われている）")
    }

    /// 目盛り帯を払うとシークする（こちらはスクラブのジェスチャを外した段）。
    func test_swipeOnRuler_seeks() {
        let before = currentTime()
        swipeLeft(on: Track.ruler)
        XCTAssertGreaterThan(currentTime() - before, Self.movedThreshold)
    }

    /// 右へ払うと戻る（左右どちらも効く。片方向だけ効く実装を弾く）。
    func test_swipeRightOnClipBand_seeksBackward() {
        swipeLeft(on: Track.clipBand)
        swipeLeft(on: Track.clipBand)
        let before = currentTime()
        XCTAssertGreaterThan(before, Self.movedThreshold, "前提: 一度進んでいること")
        swipeRight(on: Track.clipBand)
        XCTAssertLessThan(currentTime() - before, -Self.movedThreshold)
    }

    // MARK: - 払った後に止まること

    /// 払って指を離したら**再生位置が静止する**。
    ///
    /// 追従（再生位置 → スクロール）と払ってシーク（スクロール → 再生位置）に不動点が
    /// 無いと、`scrollTo` の着地誤差ぶんの往復が永久に続く
    /// （ユーザー報告「シークの仕方によってクリップが左右に動いて止まらない」）。
    /// シークの往復が恒等でない（実フレーム時刻でフレーム格子へ丸められる）ことが原因で、
    /// 値の比較だけでは閉じない。`TimelineScrollContainer` の doc 参照。
    func test_afterSwipe_positionSettles() {
        swipeLeft(on: Track.clipBand)
        assertPositionSettles()
    }

    /// ズームを上げても止まる。**不感帯は px 基準なので秒に直すとズームで縮み**、
    /// 往復が起きるかどうかがズーム段に依存する（= 報告の「シークの仕方によって」）。
    func test_afterSwipeWhenZoomedIn_positionSettles() {
        app.otherElements[Track.clipBand].pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 0.6)
        swipeLeft(on: Track.clipBand)
        assertPositionSettles()
    }

    /// 少しずつ何度も払っても止まる（1 回の払いでは着地誤差が不感帯に収まる位置に
    /// 落ちることもあるため、位置を変えながら繰り返す）。
    func test_afterRepeatedShortSwipes_positionSettles() {
        for _ in 0..<4 {
            drag(on: Track.clipBand, dx: -40)
        }
        assertPositionSettles()
    }

    /// 一定時間おいて 2 回読み、動いていないことを確かめる。
    ///
    /// **再生位置と帯の x の両方**を見る。往復が同じフレームの中で起きると
    /// （追従が動かす → 着地誤差ぶんシーク → 実フレーム時刻が同じフレームへ丸められる）
    /// 表示時刻は変わらないまま**クリップだけが左右に動き続ける**ので、
    /// 時刻だけでは取り逃がす（ユーザーが見ているのはこちら）。
    private func assertPositionSettles(file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 0.8)
        let firstTime = currentTime()
        let firstX = app.otherElements[Track.clipBand].frame.minX
        Thread.sleep(forTimeInterval: 0.8)
        let secondTime = currentTime()
        let secondX = app.otherElements[Track.clipBand].frame.minX
        XCTAssertEqual(firstTime, secondTime, accuracy: 0.01,
                       "指を離してから 1.6 秒後も再生位置が動き続けている"
                       + "（追従とシークが押し合っている）: \(firstTime) → \(secondTime)",
                       file: file, line: line)
        XCTAssertEqual(firstX, secondX, accuracy: 0.5,
                       "指を離してから 1.6 秒後もクリップ帯が動き続けている"
                       + "（追従とシークが押し合っている）: \(firstX) → \(secondX)",
                       file: file, line: line)
    }

    // MARK: - 払ってもシークしない段

    /// モザイク適用区間トラックは操作面から外してある（当て板が効いていること）。
    func test_swipeOnApplyTrack_doesNotSeek() {
        let before = currentTime()
        swipeLeft(on: Track.applyTrack)
        XCTAssertLessThan(abs(currentTime() - before), Self.stillThreshold,
                          "適用区間トラックを払って再生位置が動いた（当て板が効いていない）")
    }

    /// 継ぎ目が無いあいだ、継ぎ目レーンは**高さ 0 に畳まれている**
    /// （目盛り帯とクリップ帯が隣り合う。押せるボタンが 1 つも無いのに 28pt の空白が
    /// 空いていた＝ユーザー報告「時間とクリップの間のスペースを埋めたい」）。
    ///
    /// 種の素材は 1 本なので継ぎ目は存在しない。レーンが生えている場合の
    /// 「払ってもシークしない」は適用区間トラック側（`blocksTimelinePan` の当て板は
    /// 両者で共通）で担保する。
    func test_jointLaneIsCollapsedWithoutJoints() {
        let lane = app.otherElements[Track.jointLane]
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        XCTAssertEqual(lane.frame.height, 0, accuracy: 0.5,
                       "継ぎ目が無いのに継ぎ目レーンが高さを取っている")
        let ruler = app.otherElements[Track.ruler]
        let band = app.otherElements[Track.clipBand]
        XCTAssertLessThan(band.frame.minY - ruler.frame.maxY, 8,
                          "目盛り帯とクリップ帯のあいだに空白が残っている")
    }

    // MARK: - 再生中

    /// 再生中に払うと**再生が止まってシークに切り替わる**。
    ///
    /// 追従スクロールが指を押し返す実装だとここで落ちる（払っても再生位置が
    /// 引き戻され、再生も続いたままになる）。
    func test_swipeDuringPlayback_pausesAndSeeks() {
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 10), "再生が始まらない")

        swipeRight(on: Track.clipBand)
        XCTAssertTrue(app.buttons["再生"].waitForExistence(timeout: 5),
                      "再生中に払っても一時停止しない（追従スクロールと押し合う）")
    }

    // MARK: - 並べ替え中はシークしない

    /// クリップを長押しして引っぱる操作では再生位置を動かさない
    /// （並べ替えの自動スクロールをシークと読むと、掴んでいる間に絵が流れ続ける）。
    func test_longPressDragOnClip_doesNotSeek() {
        let before = currentTime()
        // 0.9 秒の長押しを挟むと並べ替え（`LongPressGesture(minimumDuration: 0.3)`）になる。
        drag(on: Track.clipBand, dx: -Self.swipeDistance, press: 0.9)
        XCTAssertLessThan(abs(currentTime() - before), Self.stillThreshold,
                          "長押しドラッグ（並べ替え）で再生位置が動いた")
    }

    // MARK: - 端

    /// 先頭で更に右へ払っても 0 より前へは行かない（余白まで払える構造の確認）。
    func test_swipeRightAtStart_staysAtZero() {
        swipeRight(on: Track.clipBand)
        swipeRight(on: Track.clipBand)
        XCTAssertEqual(currentTime(), 0, accuracy: Self.stillThreshold)
    }

    /// 終端まで払うと**末尾が画面中央（プレイヘッド）で止まる**。
    ///
    /// 中央固定の可動域はコンテンツの左右に付けた可視幅/2 の余白ぶんで、
    /// 上限はちょうど「終端が中央」になる（`TimelineScrollMath.scrollOffsetBounds`）。
    /// ここで止まらず往復すると、端はラバーバンドと追従が押し合う最悪の場所になる。
    func test_swipeLeftToEnd_settlesWithEndAtCenter() {
        // 10 秒 × 既定 40px/秒 = 400px。上限へ確実に届くよう多めに払う。
        for _ in 0..<6 { swipeLeft(on: Track.clipBand) }
        let center = app.windows.firstMatch.frame.midX
        let bandEnd = app.otherElements[Track.clipBand].frame.maxX
        XCTAssertEqual(bandEnd, center, accuracy: 4,
                       "終端まで払ってもクリップ帯の末尾が中央に来ない")
        assertPositionSettles()
    }

    // MARK: - 手動矩形ツール
    //
    // タイムラインのジェスチャではないが、**同じ「指の操作の取り合い」の話**であり、
    // 検証には同じ起動（`-uiTestSeedVideo` で編集画面へ直行）が要る。
    // 新しいテストファイルの追加には `xcodegen generate`（= CocoaPods 統合の再構築）が
    // 必要なため、この節としてここへ置いている。

    /// **ツールが OFF のあいだ、プレビューを払っても矩形はできない。**
    /// 常時有効だった頃は、プレビューを少しなぞるだけで矩形ができて
    /// 「間違えて指定して使いづらい」状態だった（ユーザー報告）。
    func test_dragOnPreview_withoutRectangleTool_createsNothing() {
        openFaceTab()
        XCTAssertEqual(app.buttons.matching(identifier: "editor.manualRegion").count, 0,
                       "前提: 矩形がまだ無いこと")
        dragOnPreview()
        XCTAssertEqual(app.buttons.matching(identifier: "editor.manualRegion").count, 0,
                       "ツール OFF なのにプレビューのドラッグで矩形ができた")
    }

    /// 「矩形」の段へ降りればこれまでどおり矩形を指定できる（入口を塞いでいないこと）。
    /// 段に入った時点でツールは ON になる（そのために降りた段なので、もう一度押させない）。
    func test_dragOnPreview_withRectangleTool_createsRegion() {
        openRectangleRoute()
        XCTAssertTrue(app.buttons["editor.rectangleTool"].waitForExistence(timeout: 10),
                      "矩形の段にツールのボタンが無い")
        dragOnPreview()
        let region = app.buttons.matching(identifier: "editor.manualRegion").firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 15),
                      "矩形の段でドラッグしたのに矩形ができない")
    }

    // MARK: - ドックの段（勝手に閉じないこと）

    /// **タイムラインを払っても段は閉じない。** 旧 UI は下段そのものが文脈で
    /// 差し替わっていたため、粗さを調整しながら再生位置を確かめる操作で段が消えた。
    func test_swipe_doesNotCloseDockRoute() {
        openFaceTab()
        XCTAssertTrue(dockBack.exists, "前提: 顔の段に降りていること（戻るが出ている）")
        swipeLeft(on: Track.clipBand)
        XCTAssertTrue(dockBack.exists, "タイムラインを払ったら段が閉じた")
        XCTAssertTrue(app.buttons["editor.dock.done"].exists, "完了まで消えている")
    }

    /// **再生しても段は閉じない。**
    func test_playback_doesNotCloseDockRoute() {
        openFaceTab()
        app.buttons["再生"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(dockBack.exists, "再生したら段が閉じた")
        app.buttons["一時停止"].tap()
    }

    /// **クリップを選んでも段は閉じない。**（旧 UI で最も頻繁に段が飛んだ操作）
    func test_selectingClip_doesNotCloseDockRoute() {
        openFaceTab()
        app.otherElements[Track.clipBand].tap()
        XCTAssertTrue(dockBack.exists, "クリップを選んだら段が閉じた")
    }

    /// 「完了」はどの深さからでも 1 回で最上段へ戻す（`‹` の連打を要求しない）。
    func test_done_returnsToRootInOneTap() {
        openFaceTab()
        app.buttons["editor.dock.done"].tap()
        XCTAssertTrue(dockBack.waitForNonExistence(timeout: 5),
                      "完了を押しても最上段へ戻らない（戻るボタンが残っている）")
        XCTAssertTrue(app.buttons["モザイク"].exists, "最上段の道具が出ていない")
    }

    /// 戻る `‹` は 1 段ずつ上がる（顔 → モザイク → 最上段）。
    func test_back_climbsOneLevelAtATime() {
        openFaceTab()
        dockBack.tap()
        XCTAssertTrue(app.buttons["背景"].waitForExistence(timeout: 5),
                      "顔から戻った先がモザイクの段になっていない")
        dockBack.tap()
        XCTAssertTrue(app.buttons["モザイク"].waitForExistence(timeout: 5),
                      "モザイクから戻った先が最上段になっていない")
    }

    private var dockBack: XCUIElement { app.buttons["editor.dock.back"] }

    /// ドックで「モザイク」→「顔」へ降りる。
    private func openFaceTab() {
        openMosaicMenu()
        let face = app.buttons["顔"]
        XCTAssertTrue(face.waitForExistence(timeout: 10), "ドックに「顔」が無い")
        face.tap()
    }

    /// ドックで「モザイク」→「矩形」へ降りる。
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

    /// プレビュー中央を斜めに払う（矩形を描く操作）。
    private func dragOnPreview() {
        let screen = app.windows.firstMatch.frame
        let start = point(x: screen.midX - 60, y: screen.height * 0.3)
        let end = point(x: screen.midX + 60, y: screen.height * 0.3 + 120)
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - 補助

    private var currentTimeElement: XCUIElement { app.staticTexts["editor.currentTime"] }

    /// 現在の再生位置（秒）。表示は秒単位なので `accessibilityValue` の方を読む。
    private func currentTime() -> Double {
        guard let raw = currentTimeElement.value as? String, let seconds = Double(raw) else {
            XCTFail("再生位置が読めない（editor.currentTime の value が数値でない）")
            return .nan
        }
        return seconds
    }

    private func swipeLeft(on identifier: String) {
        drag(on: identifier, dx: -Self.swipeDistance)
    }

    private func swipeRight(on identifier: String) {
        drag(on: identifier, dx: Self.swipeDistance)
    }

    /// 段の**画面に出ている部分**から水平にドラッグする。
    ///
    /// 段の frame は横スクロールするコンテンツの幅（尺 × ズーム）なので、
    /// **`coordinate(withNormalizedOffset:)` の中央は画面外を指し得る**
    /// （実測: 先頭では中央が画面右端の外に落ち、ドラッグが 1px も効かなかった）。
    /// 画面と交わる範囲を出し、その中で始点と終点を収める。
    ///
    /// `press` の既定 0.05 秒は**長押し（0.3 秒）に届かない**値。これより長くすると
    /// 並べ替えのジェスチャが成立してシークの検証にならない。
    /// 終点で 0.2 秒保持して慣性を殺し、払った量と再生位置を素直に突き合わせる。
    private func drag(on identifier: String, dx: CGFloat, press: TimeInterval = 0.05) {
        let visible = visibleRect(of: identifier)
        let margin: CGFloat = 8
        let startX = dx < 0 ? visible.maxX - margin : visible.minX + margin
        let endX = min(max(startX + dx, visible.minX + margin), visible.maxX - margin)
        XCTAssertGreaterThan(abs(endX - startX), 24,
                             "段が狭すぎてドラッグできない: \(identifier) visible=\(visible)")
        let start = point(x: startX, y: visible.midY)
        start.press(forDuration: press, thenDragTo: point(x: endX, y: visible.midY),
                    withVelocity: .default, thenHoldForDuration: 0.2)
        // 落ち着き待ち（`TimelineScrollContainer.scrollSettleDelay` は 0.16 秒）。
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// 段の frame と画面の交わり（= 実際に指を置ける範囲）。
    private func visibleRect(of identifier: String) -> CGRect {
        let element = app.otherElements[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "段が見つからない: \(identifier)")
        let screen = app.windows.firstMatch.frame
        let visible = element.frame.intersection(screen)
        XCTAssertFalse(visible.isNull || visible.isEmpty,
                       "段が画面に出ていない: \(identifier) frame=\(element.frame) screen=\(screen)")
        return visible
    }

    /// 画面座標の絶対点。
    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
}
