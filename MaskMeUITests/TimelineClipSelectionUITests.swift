import XCTest

/// 分割したあとの**クリップの選び分け**の検証（XCUITest）。
///
/// `TimelineGestureUITests` から分けてあるのは行数の都合だが、境界は意味とも合っている:
/// あちらは「誰が pan を取るか」（ジェスチャの取り合い）で、ここは
/// **「どこを押したらどれが選ばれるか」（当たり判定の territory）**である。
///
/// ## クリップを外から掴むときの約束（`timeline.clip`）
///
/// **accessibility の矩形でクリップの位置を判断してはいけない。** クリップの横位置は
/// `.offset(x:)` で決めているが、`.offset` は描画をずらすだけでレイアウト位置を変えない
/// ため、外から見た矩形には反映されない。実測では分割後の 2 本が**どちらも同じ
/// `minX`（-97）**を報告し、幅だけが 298 / 102 と割れた。位置決めの後に葉として
/// 識別子を重ねても同じだった。
///
/// なのでここでは**プレイヘッド（画面中央固定）を基準に触る**。分割は必ずプレイヘッドの
/// 位置で起きるので、分割直後の境界はクリップ帯の中央にある。
///
/// 識別子そのものの付け方にも罠がある。コンテナへ素で付けると**サムネイルの各コマへ
/// 配られ**（2 本のはずが 10 要素）、`.accessibilityElement(children: .ignore)` で畳むと
/// 今度は両端のトリムつまみが個別要素として見えなくなる。ここは葉
/// （`Color.clear`）を重ねる形にしてある（`TimelineClipBandView.clipView`）。
/// 適用区間（`TimelineLayerTrackView.spanView`）が識別子を直接付けて済んでいるのは、
/// あちらが単一の図形＝葉だからで、**コンテナに同じ書き方を持ち込まないこと。**
///
/// 前提: `-uiTestSeedVideo` 付きで起動すると合成した 10 秒の動画で編集画面へ直行する。
final class TimelineClipSelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedVideo"]
        app.launch()
        XCTAssertTrue(app.otherElements["timeline.clipBand"].waitForExistence(timeout: 120),
                      "編集画面のクリップ帯が出てこない（種の動画の生成か読み込みで失敗）")
        // 要素が出ただけでは足りない（編集画面は読み込み完了を待たずに開く）。
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "再生ボタンが出てこない")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed,
                       "読み込みが終わらない（再生ボタンが有効にならない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// **分割したあと、境界のすぐ隣をタップして隣のクリップを選べる。**
    ///
    /// 選択中のクリップには両端にトリムのつまみが出る。つまみの当たり判定（44pt）を
    /// **中央揃え**にすると、見た目 20pt のつまみの左右へ 12pt ずつはみ出して
    /// **隣のクリップの上に乗る**。クリップ帯に `.clipped()` は無いのでそのまま
    /// ヒットテストに載り、境界付近をタップしても隣のクリップの `.onTapGesture` へ
    /// 届かない ＝「分割したのに隣のクリップが選べない」になる（実機で踏んだ）。
    ///
    /// **モデル層のテストでは守れない。** 分割も選択もモデルとしては正しく動き、
    /// 壊れるのは指とヒットテストの間だけである。
    func test_afterSplit_tapNextToBoundary_selectsTheOtherClip() {
        // プレイヘッドを進めてから分割する（0 秒では分割できない）。
        swipeLeftOnClipBand()
        let split = app.buttons["分割"]
        XCTAssertTrue(split.waitForExistence(timeout: 10), "ツールバーに「分割」が無い")
        XCTAssertTrue(split.isEnabled, "プレイヘッドを進めても分割できない")
        split.tap()
        Thread.sleep(forTimeInterval: 0.5)

        let clips = clipElements()
        XCTAssertEqual(clips.count, 2,
                       "分割したのにクリップが 2 本になっていない frames=\(clips.map(\.frame))")

        // 境界はプレイヘッドの位置にある。**プレイヘッドは画面の中央に固定**なので
        // そこを基準に左右を触り分ける。
        //
        // **クリップ帯の `midX` を使ってはいけない。** あちらは横スクロールする
        // *中身* の矩形で、画面外まで含む（実測 108.67 = 中身の中点で、画面中央 201 とは別物）。
        let band = app.otherElements["timeline.clipBand"].frame
        let boundaryX = app.windows.firstMatch.frame.midX

        // まず**右のクリップがそもそも選べる**ことを確かめる（境界から十分離れた位置）。
        // ここで落ちるなら、原因は「つまみの越境」ではなく右クリップの当たり判定そのもの。
        tap(x: boundaryX + 50, y: band.midY)
        XCTAssertTrue(clipElements()[1].isSelected,
                      "境界から離れた位置でも右のクリップが選べない"
                      + "（つまみの越境ではなく当たり判定そのものの問題）"
                      + " boundaryX=\(boundaryX) selected=\(selectionFlags())")

        // 先に**左**を選ぶ。これで境界にまたがるつまみが出る（この状態でないと再現しない）。
        tap(x: boundaryX - 40, y: band.midY)
        XCTAssertTrue(clipElements()[0].isSelected,
                      "左のクリップを選べない selected=\(selectionFlags())")

        // 境界のすぐ右（＝はみ出したつまみの真下）をタップする。
        tap(x: boundaryX + 6, y: band.midY)
        XCTAssertTrue(clipElements()[1].isSelected,
                      "境界のすぐ隣をタップしても右のクリップが選べない"
                      + "（左のつまみの当たり判定が越境している）"
                      + " boundaryX=\(boundaryX) selected=\(selectionFlags())")
        XCTAssertFalse(clipElements()[0].isSelected, "右を選んだのに左が選ばれたまま")
    }

    // MARK: - 補助

    /// クリップの実体だけを**タイムライン順**に返す。
    ///
    /// 同じ識別子で入れ子の代表要素も返るため高さで実体に絞り、
    /// 位置と幅が同じものは 1 つに畳む（`minX` だけで畳むと、上記のとおり
    /// 全クリップが同じ `minX` を報告するので 1 本に潰れる）。
    private func clipElements() -> [XCUIElement] {
        var seen = Set<String>()
        return app.descendants(matching: .any)
            .matching(identifier: "timeline.clip")
            .allElementsBoundByAccessibilityElement
            .filter { $0.frame.height > 30 && $0.frame.width > 8 }
            .filter { seen.insert("\(Int($0.frame.minX.rounded()))/\(Int($0.frame.width.rounded()))").inserted }
    }

    private func selectionFlags() -> [Bool] { clipElements().map(\.isSelected) }

    private func tap(x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y)).tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func swipeLeftOnClipBand() {
        let band = app.otherElements["timeline.clipBand"]
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: band.frame.midX, dy: band.frame.midY))
        start.press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: band.frame.midX - 120, dy: band.frame.midY)),
                    withVelocity: .default, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 1.0)
    }
}
