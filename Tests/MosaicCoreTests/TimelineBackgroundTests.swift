import Foundation
import XCTest
@testable import MosaicCore

/// レターボックスの埋め方（`TimelineBackground`）の規則と永続化。
///
/// ここで守るのは 3 つ:
/// 1. **既存の下書きの見た目が変わらない**（キーが無ければ黒）
/// 2. **壊れた値で編集内容ごと失わない**（読めなければ黒へ倒す。throw しない）
/// 3. **選んだ色が種類を往復しても消えない**
final class TimelineBackgroundTests: XCTestCase {
    // MARK: - 既定と正規化

    func test_既定は黒で従来の見た目と一致する() {
        let background = TimelineBackground.default
        XCTAssertEqual(background.kind, .black)
        XCTAssertEqual(background.fillColor, .black)
        XCTAssertFalse(background.usesBlur)
    }

    func test_黒とぼかしの下地はどちらも黒() {
        // ぼかしの外周が明るい色で縁取られると、余白がかえって目立つ。
        var background = TimelineBackground(kind: .blur)
        background.color = RGBAColor(red: 1, green: 0, blue: 0)
        XCTAssertEqual(background.fillColor, .black, "ぼかしの下地に指定色が漏れている")
    }

    func test_色を選んだときだけ指定色で塗る() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let background = TimelineBackground(kind: .color, color: red)
        XCTAssertEqual(background.fillColor, red)
    }

    /// **種類を往復しても選んだ色は保持する。** 保持しないと、黒に戻して色へ戻すたびに
    /// 色を選び直すことになる。
    func test_種類を往復しても選んだ色は消えない() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        var background = TimelineBackground(kind: .color, color: red)
        background.kind = .black
        background.kind = .color
        XCTAssertEqual(background.fillColor, red, "往復で色が失われた")
    }

    func test_非有限の値は既定へ落ちる() {
        let broken = TimelineBackground(
            kind: .blur,
            color: RGBAColor(red: .nan, green: 0, blue: 0),
            blurStrength: .nan).clamped
        XCTAssertEqual(broken.color, .white, "壊れた色が RGBAColor の規則どおりに倒れていない")
        XCTAssertEqual(broken.blurStrength, 0.6, accuracy: 1e-9)
    }

    /// **ぼかしの強さに弱すぎる値を許さない。** 0 だと「選んだのに何も変わらない」、
    /// 0.2 程度だと余白にほぼ鮮明な拡大コピーが出て「同じ絵が二重に出ている」ようにしか
    /// 見えない（実際に画で確認した。`TimelineBackground.clamped` の doc 参照）。
    func test_ぼかしの強さは弱すぎる値にならない() {
        XCTAssertGreaterThanOrEqual(
            TimelineBackground(kind: .blur, blurStrength: 0).clamped.blurStrength, 0.25)
        XCTAssertGreaterThanOrEqual(
            TimelineBackground(kind: .blur, blurStrength: 0.1).clamped.blurStrength, 0.25)
        XCTAssertGreaterThanOrEqual(
            TimelineBackground(kind: .blur, blurStrength: -5).clamped.blurStrength, 0.25)
        XCTAssertEqual(TimelineBackground(kind: .blur, blurStrength: 99).clamped.blurStrength, 1,
                       accuracy: 1e-9)
    }

    // MARK: - 永続化

    func test_往復して同じ値に戻る() throws {
        let original = TimelineState(
            clips: [TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)],
            background: TimelineBackground(kind: .color,
                                           color: RGBAColor(red: 0.2, green: 0.4, blue: 0.6),
                                           blurStrength: 0.8))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(restored.background, original.background)
    }

    /// **キーが無い旧下書きは黒で復元する。** ここが変わると、既に保存されている
    /// 下書きの見た目が勝手に変わる。
    func test_キーが無い旧下書きは黒で復元する() throws {
        let state = TimelineState(clips: [TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)])
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "background")
        let data = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(restored.background.kind, .black)
    }

    /// **壊れた値でも下書き全体のデコードを失敗させない。** 余白の見た目は欠けても
    /// 編集内容は失われないので、ここで throw して下書きごと開けなくするのは割に合わない。
    func test_壊れた値でも下書き全体は開ける() throws {
        let state = TimelineState(clips: [TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)])
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["background"] = "こわれた値"
        let data = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(restored.background.kind, .black, "壊れた値が黒へ倒れていない")
        XCTAssertEqual(restored.clips.count, 1, "余白の値のせいでクリップまで失われた")
    }

    /// 追加はトップレベルのキーが 1 本増えただけで意味の反転が無いため、
    /// **スキーマ版は上げない**（`crop` と同じ前例）。
    func test_スキーマ版は上げない() throws {
        let state = TimelineState(clips: [], background: TimelineBackground(kind: .blur))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 7)
    }
}
