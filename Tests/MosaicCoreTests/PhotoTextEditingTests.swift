import XCTest
@testable import MosaicCore

/// `PhotoTextEditing.swift`（写真モードのテキスト・ステッカー編集）のユニットテスト。
///
/// **正規化の期待値は本番関数の出力と比較する**（手で書いた配列と比較しない）。
/// `renderableTextItems` が `[]` を返すだけの実装で通らないよう、入力件数と出力件数の
/// 一致を先に assert する（`PhotoTextEditing.swift` の doc・素通り対策の項参照）。
final class PhotoTextEditingTests: XCTestCase {
    // MARK: - addingText

    func test_addingText_producesItemRenderableAtTimeZero() throws {
        let state = PhotoEditState.identity.addingText("こんにちは", center: NormalizedPoint(x: 0.3, y: 0.4))
        XCTAssertEqual(state.texts.count, 1)
        let item = try XCTUnwrap(state.texts.first)
        XCTAssertEqual(item.text, "こんにちは")
        XCTAssertEqual(item.role, .text)
        XCTAssertEqual(item.center, NormalizedPoint(x: 0.3, y: 0.4))

        // renderableTextItems（本番の描画入口）を通した結果で「時刻0で描ける」ことを検証する。
        let renderable = try XCTUnwrap(state.renderableTextItems.first)
        XCTAssertTrue(renderable.isVisible(atComposition: 0))
        let params = try XCTUnwrap(renderable.renderParameters(atComposition: 0))
        XCTAssertEqual(params.opacity, 1)
    }

    /// 空文字（空白だけ）は追加されない。
    func test_addingText_rejectsBlankText() {
        let state = PhotoEditState.identity.addingText("   ")
        XCTAssertTrue(state.texts.isEmpty)
    }

    // MARK: - addingSticker

    /// 複数の書記素クラスタ（絵文字2個）を渡しても、本番の正規化を経て 1 個へ切り詰まる。
    /// **手で書いた期待文字列ではなく、`normalizedTextItems` を経由した本番の
    /// 出力そのもの（`state.texts` を経た結果）を確認する。**
    func test_addingSticker_clampsToSingleGraphemeCluster() throws {
        let twoEmoji = "😀😁"
        XCTAssertGreaterThan(twoEmoji.count, 1, "テスト前提: 2書記素クラスタである")

        let state = PhotoEditState.identity.addingSticker(twoEmoji)
        XCTAssertEqual(state.texts.count, 1)
        let item = try XCTUnwrap(state.texts.first)
        XCTAssertEqual(item.text.count, 1, "ステッカーは書記素クラスタ1個へ切り詰まっていること")
        XCTAssertEqual(item.text, String(twoEmoji.first!))
    }

    func test_addingSticker_usesStickerRoleAndStickerDefaultStyle() throws {
        let state = PhotoEditState.identity.addingSticker("🎉")
        let item = try XCTUnwrap(state.texts.first)
        XCTAssertEqual(item.role, .sticker)
        XCTAssertEqual(item.style, TextStyle.stickerDefault)
    }

    // MARK: - removing / setting

    func test_removingText_removesOnlyMatchingID() throws {
        let state = PhotoEditState.identity.addingText("A").addingText("B")
        XCTAssertEqual(state.texts.count, 2)
        let target = try XCTUnwrap(state.texts.first)
        let next = state.removingText(id: target.id)
        XCTAssertEqual(next.texts.count, 1)
        XCTAssertFalse(next.texts.contains { $0.id == target.id })
    }

    func test_settingText_rejectsStickerRole() throws {
        let state = PhotoEditState.identity.addingSticker("🎉")
        let sticker = try XCTUnwrap(state.texts.first)
        let next = state.settingText(id: sticker.id, text: "not allowed")
        XCTAssertEqual(next.texts.first?.text, sticker.text, "ステッカーの role は settingText を無視すること")
    }

    func test_settingStickerContent_rejectsTextRole() throws {
        let state = PhotoEditState.identity.addingText("hello")
        let text = try XCTUnwrap(state.texts.first)
        let next = state.settingStickerContent(id: text.id, emoji: "🎉")
        XCTAssertEqual(next.texts.first?.text, text.text, "文字の role は settingStickerContent を無視すること")
    }

    func test_settingTextCenter_updatesClampedCenter() throws {
        let state = PhotoEditState.identity.addingText("A")
        let item = try XCTUnwrap(state.texts.first)
        let next = state.settingTextCenter(id: item.id, center: NormalizedPoint(x: 1.5, y: -0.5))
        XCTAssertEqual(next.texts.first?.center, NormalizedPoint(x: 1, y: 0))
    }

    func test_settingTextStyle_clampsFontSizeToRoleMaximum() throws {
        let state = PhotoEditState.identity.addingText("A")
        let item = try XCTUnwrap(state.texts.first)
        var oversized = TextStyle()
        oversized.fontSize = 999
        let next = state.settingTextStyle(id: item.id, style: oversized)
        XCTAssertEqual(next.texts.first?.style.fontSize, TextStyle.maximumFontSize)
    }

    // MARK: - renderableTextItems

    func test_renderableTextItems_preservesCountAndAlwaysYieldsIdentityParameters() throws {
        let state = PhotoEditState.identity.addingText("A").addingSticker("🎉").addingText("B")
        XCTAssertEqual(state.texts.count, 3, "テスト前提: 3件追加できている")

        let renderable = state.renderableTextItems
        // **件数の一致を先に assert する**（`[]` を返すだけの実装が空振りで通るのを防ぐ）。
        XCTAssertEqual(renderable.count, state.texts.count)

        for item in renderable {
            XCTAssertEqual(item.compositionStart, 0)
            XCTAssertEqual(item.duration, PhotoEditState.textDuration)
            XCTAssertEqual(item.animation, .none)
            let params = try XCTUnwrap(item.renderParameters(atComposition: 0))
            XCTAssertEqual(params, TextRenderParameters.identity)
        }
    }

    /// decode 由来のゴミ値（`compositionStart = 99` / `duration = 0` /
    /// `animation = .fade`）を仕込んでも、`renderableTextItems` が必ず
    /// 時刻0・不透明度1へ正規化して返すこと。
    func test_renderableTextItems_normalizesGarbageFromDecodedDraft() throws {
        let garbageItem = TextItem(text: "旧下書き", compositionStart: 99, duration: 0,
                                   center: .center, style: TextStyle(), animation: .fade)
        let garbageState = PhotoEditState(colorGrade: .identity, texts: [garbageItem])

        // 実際に Codable の往復（encode → decode）を経由させる
        // （`init(from:)` が持つ正規化の有無ではなく、`renderableTextItems` 側の
        // 防御を検証したいので、texts 自体はゴミ値のまま往復させる）。
        let data = try JSONEncoder().encode(garbageState)
        let decoded = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(decoded.texts.first?.compositionStart, 99, "テスト前提: decode はゴミ値をそのまま保持する")
        XCTAssertEqual(decoded.texts.first?.duration, 0, "テスト前提: decode はゴミ値をそのまま保持する")
        XCTAssertEqual(decoded.texts.first?.animation, .fade, "テスト前提: decode はゴミ値をそのまま保持する")

        let renderable = decoded.renderableTextItems
        XCTAssertEqual(renderable.count, decoded.texts.count)
        let item = try XCTUnwrap(renderable.first)
        XCTAssertEqual(item.compositionStart, 0)
        XCTAssertEqual(item.duration, PhotoEditState.textDuration)
        XCTAssertEqual(item.animation, .none)
        let params = try XCTUnwrap(item.renderParameters(atComposition: 0))
        XCTAssertEqual(params.opacity, 1, "旧下書きのゴミ値のせいで不透明度1未満（透明に近い状態）で描かれてはならない")
    }
}
