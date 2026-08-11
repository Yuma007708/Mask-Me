import XCTest

/// 写真モードの道具立てが実機（Simulator）で成立していることの検証（XCUITest）。
///
/// **写真モードには UI テストが 1 本も無かった。** 動画モードは
/// `-uiTestSeedVideo` で編集画面へ直行できたが、写真は写真ライブラリを開く経路しか
/// なく、PHPicker の自動操作が端末・OS 版で揺れるため誰も書けなかった。
/// `-uiTestSeedPhoto`（`UITestBootstrap.seedPhotoImage`）で同じ直行路を用意したので、
/// ここから先は写真モードも普通に触って確かめられる。
///
/// ここで守るのは**道具が全部そこにあり、押せること**。
/// 見た目（配色・アイコン）は目で見るしかないが、「押せる道具が消えた」
/// 「トグルが効かない」は機械で捕まえられる。
final class PhotoModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedPhoto"]
        app.launch()
        // 写真は合成が軽い（動画のような書き出しが無い）ので、動画側ほど長く待たない。
        XCTAssertTrue(app.buttons["editor.photoTool.crop"].waitForExistence(timeout: 60),
                      "写真の編集画面が出てこない（種の写真で直行できていない）")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// 道具列の 5 つが全部あって、押せる状態にあること。
    ///
    /// **1 つずつ名前で確かめる。** 個数だけを数えると、別の道具が増えたときに
    /// 消えた道具を見逃す。
    func test_写真の道具が5つとも押せる() {
        for tool in ["colorGrade", "crop", "text", "sticker", "rotate"] {
            let button = app.buttons["editor.photoTool.\(tool)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "道具が無い: \(tool)")
            XCTAssertTrue(button.isHittable, "道具が押せない: \(tool)")
        }
    }

    /// モザイクを掛ける対象（顔・背景）のトグルが両方あって押せること。
    func test_モザイクの対象が2つとも押せる() {
        for tab in ["face", "background"] {
            let button = app.buttons["editor.effectTab.\(tab)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "対象が無い: \(tab)")
            XCTAssertTrue(button.isHittable, "対象が押せない: \(tab)")
        }
    }

    /// 「顔」を押すと粗さの調整バーが降りてくること（＝タブが効果の ON/OFF を持つ
    /// トグルとして働いていること）。**押した結果が画面に出るところまで**見る
    /// ——ボタンの存在だけでは、押しても何も起きない状態を捕まえられない。
    func test_顔を押すと粗さの調整バーが出る() {
        let slider = app.sliders.firstMatch
        XCTAssertFalse(slider.exists, "前提: 押す前は調整バーが出ていないこと")

        app.buttons["editor.effectTab.face"].tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 10),
                      "「顔」を押しても粗さの調整バーが出てこない")
    }

    /// 「切り抜き」を押すと切り抜きの段へ降り、通常の道具列と入れ替わること。
    /// **入れ替わりまで見る**のは、段が二重に積まれる（両方出る）壊れ方があるため。
    func test_切り抜きを押すと段が入れ替わる() {
        app.buttons["editor.photoTool.crop"].tap()
        let filter = app.buttons["editor.photoTool.colorGrade"]
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: filter)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed,
                       "切り抜きの段に降りたのに通常の道具列が残っている")
    }
}
