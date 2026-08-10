import XCTest

/// 適用区間（エフェクトの帯）を**指で掴んで動かす**操作の検証。
///
/// ここでしか捕まえられないのは**ジェスチャの取り合い**である。段の上では
/// 3 つの操作が同じ場所で重なっており、誰が指を取るかは実際に触らないと決まらない:
///
/// | 指の動き | 起きてほしいこと |
/// |---|---|
/// | 横へ引く | 区間が動く |
/// | 縦へ払う | 段が送られる（下の段が見える） |
/// | 端のつまみを引く | 区間が伸縮する（移動ではない） |
///
/// 区間本体のドラッグは段の上のタッチを丸ごと先取りするため、縦方向は
/// **自前で段送りへ中継**している（`TimelineLayerTrackView.moveGesture`）。
/// 中継が外れると「モザイクの段の上でだけ下の段へ行けない」という、
/// 段が 3 つ以上ある構成でしか出ない詰み方をする。
///
/// 前提: `-uiTestSeedVideo` 付きで起動すると合成した 10 秒の動画で編集画面へ直行する。
final class TimelineSpanDragUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 払う距離（px）。区間を縮める・動かすのに十分で、帯からはみ出さない量。
    private static let dragDistance: CGFloat = 90
    /// 「動いた」と見なす下限（px）。吸着で多少丸められても成り立つよう緩く取る。
    private static let movedThreshold: CGFloat = 20
    /// 「動いていない」と見なす上限（px）。指の揺れは許す。
    private static let stillThreshold: CGFloat = 6

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedVideo"]
        app.launch()
        XCTAssertTrue(app.otherElements["timeline.clipBand"].waitForExistence(timeout: 120),
                      "編集画面のクリップ帯が出てこない（種の動画の生成か読み込みで失敗）")
        // 要素が出ただけでは足りない（編集画面は読み込み完了を待たずに開く）。
        // 再生ボタンが押せるようになった時点＝読み込みが終わった時点を待つ。
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "再生ボタンが出てこない")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed,
                       "読み込みが終わらない（再生ボタンが有効にならない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 移動

    /// 区間の本体を横へ引くと動く。
    ///
    /// 新規編集は全域を覆う 1 本で始まるので**そのままでは動かす余地が無い**
    /// （可動域はクリップの合成区間に閉じている）。まず端を引いて縮めてから動かす。
    ///
    /// ## 過去にここで長く迷ったこと（同じ道を通らないために残す）
    ///
    /// 「引いても 1px も動かない」を長らく**ジェスチャが届いていない**と読み違えた。
    /// 祖先の優先度・囲みの `UIScrollView` の当て板を順に疑ったがどれも外れで、
    /// 実際には**最初から届いており、誰が取るかだけが誤っていた**
    /// （`moveHitArea` がつまみの当たり判定に 22pt 重なっていた）。
    ///
    /// 外から帯の位置だけを見ていると「発火していない」と「発火はするが確定が効かない」が
    /// 区別できない。**アプリ側に `translation` を出させる**（`timeline.diag`）と 1 回で決まった。
    /// 同種の詰まり方をしたら、まず切り分けの道具を作ること。
    func test_dragSpanBody_movesSpanHorizontally() throws {
        selectFirstSpan()
        shrinkFromLeftEdge()

        let before = spanFrame()
        let beforeWidth = spanElement().frame.width
        dragHorizontally(on: before, dx: -Self.dragDistance)
        let after = spanFrame()

        XCTAssertGreaterThan(before.minX - after.minX, Self.movedThreshold,
                             "区間の本体を引いても動いていない（移動ジェスチャが取れていない）"
                             + " before=\(before) after=\(after) diag=\(diag())")
        // **長さの判定に `visible()` を通した幅を使ってはいけない。** この区間は画面の
        // 右端をはみ出しているので、左へ動かすと右に隠れていた分が見えてくる。
        // 切り詰めた幅は「動いたぶんだけ増える」ので、正しく平行移動しているときほど
        // 大きく食い違う（実測: 111 → 201 で「長さが変わった」と誤検知した）。
        // 素の frame（画面外を含む）で見る。
        XCTAssertEqual(spanElement().frame.width, beforeWidth, accuracy: Self.stillThreshold,
                       "移動なのに長さが変わった（両端が同じ量だけ動いていない）")
    }

    /// 移動しても再生位置は動かない（横シークへ漏れていない）。
    func test_dragSpanBody_doesNotSeek() {
        selectFirstSpan()

        let before = currentTime()
        dragHorizontally(on: spanFrame(), dx: -Self.dragDistance)

        XCTAssertLessThan(abs(currentTime() - before), 0.1,
                          "区間を動かしたら再生位置まで動いた（当て板が効いていない）")
    }

    // MARK: - 縦へ払ったときに段送りが効く

    /// **区間の上を縦に払っても段送りが効く。**
    ///
    /// 区間本体のドラッグが縦のタッチまで食うと、モザイクの段の上でだけ
    /// 下の段（音声・テキスト）へ行けなくなる。段の可視高は 2 段ぶんしかないので、
    /// これが壊れると 3 段目に永久に到達できない。
    func test_verticalSwipeOnSpan_scrollsLayerStack() {
        selectFirstSpan()
        let target = app.descendants(matching: .any)
            .matching(identifier: "timeline.layer.text.empty").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "テキストの段が見つからない")

        let before = target.frame.minY
        dragVertically(on: spanFrame(), dy: -60)
        let after = target.frame.minY

        XCTAssertGreaterThan(before - after, Self.movedThreshold,
                             "区間の上を縦に払っても段が送られない"
                             + "（移動ジェスチャが縦のタッチを食っている） before=\(before) after=\(after)")
    }

    /// 縦に払ったときは区間が横へ動かない（軸の確定が効いている）。
    func test_verticalSwipeOnSpan_doesNotMoveSpan() {
        selectFirstSpan()

        let before = spanFrame()
        dragVertically(on: before, dy: -60)

        XCTAssertEqual(spanFrame().minX, before.minX, accuracy: Self.stillThreshold,
                       "縦に払ったのに区間が横へ動いた（軸の確定が効いていない）")
    }

    // MARK: - 端のつまみが移動より優先される

    /// 選択中に端のつまみを掴んだら、移動ではなく伸縮になる。
    ///
    /// つまみは区間チップへの `.overlay` なので**より深い**位置にあり、
    /// 同じ `highPriorityGesture` 同士では深い方が勝つ、という前提に立っている。
    /// その前提が崩れると、つまみを掴んでも区間ごと動いてしまう。
    func test_dragOnEdgeHandle_resizesInsteadOfMoving() throws {
        selectFirstSpan()

        let before = spanFrame()
        shrinkFromLeftEdge()
        let after = spanFrame()

        XCTAssertLessThan(after.width, before.width - Self.movedThreshold,
                          "端のつまみを引いても縮んでいない（移動が勝っている）"
                          + " before=\(before) after=\(after) diag=\(diag())")
        // 伸縮なら左端だけが右へ動く。移動が勝っていれば長さが保たれるので、
        // 上の幅の assert と合わせて「伸縮であって移動ではない」ことが決まる。
        XCTAssertGreaterThan(after.minX - before.minX, Self.movedThreshold,
                             "左のつまみを引いたのに左端が動いていない")
    }

    // MARK: - 補助

    /// エフェクトを掛けて区間を出し、最初の 1 本を選ぶ（選ばないとつまみが出ない）。
    private func selectFirstSpan() {
        let mosaic = app.buttons["モザイク"]
        XCTAssertTrue(mosaic.waitForExistence(timeout: 15), "ドックに「モザイク」が無い")
        mosaic.tap()
        let face = app.buttons["顔"]
        XCTAssertTrue(face.waitForExistence(timeout: 10), "ドックに「顔」が無い")
        face.tap()

        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "timeline.applySpan").firstMatch
            .waitForExistence(timeout: 15), "効果を掛けても区間の帯が出てこない")
        let frame = visible(spanElement().frame)
        // 帯の幅が指で掴める大きさであることを先に確かめる（掴む要素を取り違えると
        // 「動かない」という実装の欠陥に見える失敗になる）。
        XCTAssertGreaterThan(frame.width, 60,
                             "区間の帯が細すぎる（掴む要素を取り違えている） frame=\(frame)")
        point(x: frame.midX, y: frame.midY).tap()
        Thread.sleep(forTimeInterval: 0.4)
        // **選択できたことを確かめてから先へ進む。** 選択されていないと端のつまみが
        // 出ず、その先の「引いても縮まない」が実装の欠陥に見える失敗になる。
        XCTAssertTrue(spanElement().isSelected,
                      "区間をタップしても選択されない（移動ジェスチャがタップを食っている可能性）")
    }

    /// **左**のつまみを右へ引いて区間を縮める（動かす余地を作る）。
    ///
    /// 右ではなく左を使う理由: 新規編集の区間はクリップ全域（10 秒 = 既定ズームで
    /// 400px）を覆い、タイムラインは中央固定なので**右端は画面の外にある**。
    /// 実測では区間の見えている範囲が 201〜402px（= 画面右端）で、右端から
    /// 数 px 内側を掴んでも帯の途中を触るだけだった（＝つまみに当たらず、
    /// 「引いても縮まない」という実装の欠陥に見える失敗になる）。
    /// 区間の開始（0 秒）は画面中央にあるので、**左のつまみは画面内にある**。
    private func shrinkFromLeftEdge() {
        // **要素として掴む**（座標から当てにいくと、帯の途中を触っていても気づけない）。
        let handle = app.descendants(matching: .any)
            .matching(identifier: "timeline.applySpan.handle.start").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10),
                      "左のつまみが見つからない（選択できていないか、識別子が付いていない）")
        let frame = visible(handle.frame)
        let start = point(x: frame.midX, y: frame.midY)
        start.press(forDuration: 0.05,
                    thenDragTo: point(x: frame.midX + Self.dragDistance, y: frame.midY),
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func dragHorizontally(on frame: CGRect, dx: CGFloat) {
        let start = point(x: frame.midX, y: frame.midY)
        start.press(forDuration: 0.05, thenDragTo: point(x: frame.midX + dx, y: frame.midY),
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func dragVertically(on frame: CGRect, dy: CGFloat) {
        let start = point(x: frame.midX, y: frame.midY)
        start.press(forDuration: 0.05, thenDragTo: point(x: frame.midX, y: frame.midY + dy),
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// **要素の型を決め打ちしないで探す**（枠は `otherElements`、つまみは `images` と割れる）。
    ///
    /// **`firstMatch` で取ってはいけない。** 同じ識別子の要素が複数返り、先頭は
    /// 8×8 の小さな代表要素だった（実測）。その矩形を掴むと帯の外を触ることになり、
    /// 「動かしても 1px も動かない」＝実装の欠陥に見える失敗になる。
    /// 帯そのものは**最も幅の広い**要素なので、それを選ぶ。
    private func spanElement() -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(identifier: "timeline.applySpan")
            .allElementsBoundByAccessibilityElement
        guard let widest = matches.max(by: { $0.frame.width < $1.frame.width }) else {
            return app.descendants(matching: .any)
                .matching(identifier: "timeline.applySpan").firstMatch
        }
        return widest
    }

    private func spanFrame() -> CGRect {
        let element = spanElement()
        XCTAssertTrue(element.exists, "区間の帯が消えている")
        return visible(element.frame)
    }

    /// 画面と交わる範囲（段の frame は横スクロールする内容の幅なので画面外を含む）。
    private func visible(_ frame: CGRect) -> CGRect {
        let screen = app.windows.firstMatch.frame
        let rect = frame.intersection(screen)
        XCTAssertFalse(rect.isNull || rect.isEmpty,
                       "対象が画面に出ていない frame=\(frame) screen=\(screen)")
        return rect
    }

    private func currentTime() -> Double {
        guard let raw = app.staticTexts["editor.currentTime"].value as? String,
              let seconds = Double(raw) else {
            XCTFail("再生位置が読めない（editor.currentTime の value が数値でない）")
            return .nan
        }
        return seconds
    }

    /// DIAG（切り分け用・原因が分かったら消す）: アプリ側が最後に受け取った
    /// ドラッグの `translation`。`none` なら**ジェスチャが一度も成立していない**。
    private func diag() -> String {
        let element = app.descendants(matching: .any)
            .matching(identifier: "timeline.diag").firstMatch
        return element.exists ? element.label : "<diag要素なし>"
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
}
