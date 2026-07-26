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

    // MARK: - 払ってもシークしない段

    /// モザイク適用区間トラックは操作面から外してある（当て板が効いていること）。
    func test_swipeOnApplyTrack_doesNotSeek() {
        let before = currentTime()
        swipeLeft(on: Track.applyTrack)
        XCTAssertLessThan(abs(currentTime() - before), Self.stillThreshold,
                          "適用区間トラックを払って再生位置が動いた（当て板が効いていない）")
    }

    /// 継ぎ目レーンも同じ扱い。
    func test_swipeOnJointLane_doesNotSeek() {
        let before = currentTime()
        swipeLeft(on: Track.jointLane)
        XCTAssertLessThan(abs(currentTime() - before), Self.stillThreshold)
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
