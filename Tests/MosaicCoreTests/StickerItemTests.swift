import XCTest
@testable import MosaicCore

/// S12: 絵文字ステッカー（`TextItem.role == .sticker`）。
///
/// **新しい型は無い。** `TextItem` に `role` を 1 つ足して相乗りさせただけなので、
/// ここで検査するのは「役割ごとに正規化・validate・スタイル上限がどう分岐するか」
/// と「role の無い旧下書き（v5 以前）が壊れずに読めるか」の 2 点が主眼になる。
final class StickerItemTests: XCTestCase {
    private func makeState(textItems: [TextItem] = []) -> TimelineState {
        let source = UUID()
        return TimelineState(
            clips: [TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)],
            textItems: textItems,
            sources: [source: TimelineSource(id: source, kind: .video)])
    }

    // MARK: - 1. role キーの無い v5 実データ相当の JSON

    /// **番人: v5 の下書き（`role` 以前）が今も読めること。**
    ///
    /// `TextItem` の現行エンコードから機械的に組むのではなく、v5 時点で
    /// 実際に書き出されていたであろう形をそのままリテラルで埋め込む
    /// （`TimelineAspectRatioTests` の `legacyJSON` と違い、`TextItem` 自身は
    /// 独立してデコードできる型なので JSON を直書きできる）。
    func test_decode_missingRoleKey_fallsBackToText() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "text": "こんにちは",
          "compositionStart": 1.5,
          "duration": 3.0,
          "center": {"x": 0.5, "y": 0.5},
          "style": {
            "fontSize": 0.05,
            "fontFamily": "systemBold",
            "color": {"red": 1, "green": 1, "blue": 1, "alpha": 1},
            "strokeWidth": 0.08,
            "strokeColor": {"red": 0, "green": 0, "blue": 0, "alpha": 1},
            "backgroundOpacity": 0,
            "backgroundColor": {"red": 0, "green": 0, "blue": 0, "alpha": 1}
          },
          "animation": "none"
        }
        """
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(TextItem.self, from: data)

        XCTAssertEqual(decoded.role, .text,
                       "role キーが無い v5 の下書きが .text 以外に復元された")
        XCTAssertEqual(decoded.text, "こんにちは", "role 以外のフィールドが壊れた")
    }

    // MARK: - 2. 未知の role 文字列

    /// 将来のバージョンで保存された・手で書き換えられた `role` の値も throw せず `.text` へ倒す。
    func test_decode_unknownRoleString_fallsBackToTextWithoutThrowing() throws {
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "text": "banner",
          "compositionStart": 0,
          "duration": 2,
          "center": {"x": 0.5, "y": 0.5},
          "style": {
            "fontSize": 0.05,
            "fontFamily": "system",
            "color": {"red": 1, "green": 1, "blue": 1, "alpha": 1},
            "strokeWidth": 0,
            "strokeColor": {"red": 0, "green": 0, "blue": 0, "alpha": 1},
            "backgroundOpacity": 0,
            "backgroundColor": {"red": 0, "green": 0, "blue": 0, "alpha": 1}
          },
          "animation": "none",
          "role": "banner"
        }
        """
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(TextItem.self, from: data)

        XCTAssertEqual(decoded.role, .text, "未知の role 文字列で throw するか、別の値へ倒れた")
    }

    // MARK: - 3. 往復一致と schemaVersion

    func test_codable_roundTrip_keepsStickerAndWritesSchemaVersion7() throws {
        let state = makeState().addingStickerItem("😀", atCompositionTime: 1, duration: 2)
        XCTAssertEqual(state.textItems.first?.role, .sticker)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(decoded, state, "ステッカーを含む往復で状態が変わった")
        XCTAssertEqual(decoded.textItems.first?.role, .sticker, "往復で role が保持されない")

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 7,
                       "schemaVersion が現行版として書かれていない（v7 = colorGrade と ダッキングが合流）")
        let items = try XCTUnwrap(object["textItems"] as? [[String: Any]])
        XCTAssertEqual(items.first?["role"] as? String, "sticker",
                       "role が実際に JSON へ書かれていない（既定値ゆえの素通りに注意）")
    }

    // MARK: - 4. 書記素クラスタへの切り詰め

    /// 2 文字以上を渡すと先頭の書記素クラスタ 1 個だけへ切られる。
    func test_addingStickerItem_truncatesToSingleGraphemeCluster() {
        let state = makeState().addingStickerItem("😀😍", atCompositionTime: 0, duration: 1)

        XCTAssertEqual(state.textItems.first?.text, "😀",
                       "2 文字目まで残っている（書記素クラスタ 1 個へ切られていない）")
        XCTAssertEqual(state.textItems.first?.text.count, 1)
    }

    /// **結合絵文字（家族・肌色修飾つき）は壊さないこと。**
    /// ZWJ で連結された家族絵文字はそれ自体が 1 個の拡張書記素クラスタなので、
    /// 後ろに別の絵文字を続けても、家族絵文字全体が保たれたまま切られる
    /// （バイト単位・UTF-16 単位で切ると内部の ZWJ シーケンスが壊れて別の絵が化ける）。
    func test_addingStickerItem_preservesComposedEmojiGraphemeCluster() {
        let family = "👨‍👩‍👧‍👦" // 4 人家族（ZWJ 連結・1 書記素クラスタ）
        let state = makeState().addingStickerItem(family + "😀", atCompositionTime: 0, duration: 1)

        XCTAssertEqual(state.textItems.first?.text, family,
                       "結合絵文字（家族）が壊れた、または後続の絵文字が混入した")
        XCTAssertEqual(state.textItems.first?.text.count, 1,
                       "結合絵文字が複数の書記素クラスタへ分解された")
    }

    /// 肌色修飾つきの絵文字（`👍🏽` 等）も同様に 1 書記素クラスタとして保たれる。
    func test_addingStickerItem_preservesSkinToneModifiedEmoji() {
        let thumbsUp = "👍🏽"
        let state = makeState().addingStickerItem(thumbsUp + "🎉", atCompositionTime: 0, duration: 1)

        XCTAssertEqual(state.textItems.first?.text, thumbsUp,
                       "肌色修飾つき絵文字が壊れた、または後続の絵文字が混入した")
    }

    // MARK: - 5. 役割ごとの fontSize 上限

    /// `.sticker` は 1.0 まで、`.text` は 0.5 で頭打ち。両者とも `validate() == true`
    /// （正規化と validate が同じ写像を見ていることの確認）。
    func test_fontSizeCap_differsByRole_andBothPassValidate() {
        var stickerStyle = TextStyle.stickerDefault
        stickerStyle.fontSize = 999
        let stickerState = makeState()
            .addingStickerItem("🔥", atCompositionTime: 0, duration: 1)
        let stickerID = stickerState.textItems[0].id
        let styledSticker = stickerState.settingTextStyle(id: stickerID, style: stickerStyle)

        XCTAssertEqual(styledSticker.textItems[0].style.fontSize, TextStyle.maximumStickerSize,
                       accuracy: 1e-12, ".sticker が 1.0 まで通っていない")
        XCTAssertTrue(styledSticker.validate(), ".sticker の上限値が validate() を落としている")

        var textStyle = TextStyle()
        textStyle.fontSize = 999
        let textState = makeState()
            .addingTextItem("hello", atCompositionTime: 0, duration: 1)
        let textID = textState.textItems[0].id
        let styledText = textState.settingTextStyle(id: textID, style: textStyle)

        XCTAssertEqual(styledText.textItems[0].style.fontSize, TextStyle.maximumFontSize,
                       accuracy: 1e-12, ".text が 0.5 で頭打ちになっていない")
        XCTAssertTrue(styledText.validate(), ".text の上限値が validate() を落としている")
    }

    // MARK: - 6. 同一時刻の共存と重ね順

    func test_stickerAndText_coexistAtSameTime_visibleInCompositionStartOrder() {
        let state = makeState()
            .addingTextItem("あとから", atCompositionTime: 1, duration: 5)
            .addingStickerItem("😀", atCompositionTime: 0, duration: 5)

        let visible = state.visibleTextItems(atComposition: 2, totalDuration: 10)

        XCTAssertEqual(visible.count, 2, "ステッカーとテキストが同時に出せていない")
        XCTAssertEqual(visible.map(\.role), [.sticker, .text],
                       "重ね順が compositionStart 昇順になっていない")
    }

    // MARK: - 7. 移動・伸縮・尺クランプがテキストと同一結果になる

    func test_movingStickerItem_behavesLikeText() {
        let state = makeState()
            .addingStickerItem("🎉", atCompositionTime: 3, duration: 2)
        let id = state.textItems[0].id

        let moved = state.movingTextItem(id: id, byCompositionDelta: -10)
        XCTAssertEqual(moved.textItems[0].compositionStart, 0, accuracy: 1e-12,
                       "ステッカーの移動が 0 秒未満へ行けてしまう、またはテキストと違う結果になった")
    }

    func test_trimmingStickerItem_behavesLikeText() {
        let state = makeState()
            .addingStickerItem("🎉", atCompositionTime: 0, duration: 2)
        let id = state.textItems[0].id

        let trimmed = state.trimmingTextItem(id: id, edge: .end, byCompositionDelta: 100)
        XCTAssertEqual(trimmed.textItems[0].duration, 102, accuracy: 1e-9,
                       "ステッカーの伸縮がテキストと同じ規則（上限なし）になっていない")
    }

    func test_clippingStickerItem_toShortenedTotalDuration_behavesLikeText() {
        let state = makeState(textItems: [
            TextItem(text: "😀", compositionStart: 8, duration: 5, role: .sticker)
        ])

        let effective = state.effectiveTextItems(totalDuration: 10)
        XCTAssertEqual(effective.count, 1)
        XCTAssertEqual(effective[0].duration, 2, accuracy: 1e-12,
                       "ステッカーが合成尺クランプでテキストと違う結果になった")
    }

    // MARK: - role 違いへの no-op 契約

    /// `settingStickerContent` はテキスト（`.text`）には効かない。
    func test_settingStickerContent_onTextItem_isNoOp() {
        let state = makeState().addingTextItem("文字", atCompositionTime: 0, duration: 2)
        let id = state.textItems[0].id

        XCTAssertEqual(state.settingStickerContent(id: id, emoji: "😀"), state,
                       "普通のテキストにステッカー用の更新が効いてしまった")
    }

    /// `settingText` はステッカー（`.sticker`）には効かない
    /// （書記素クラスタ 1 個への切り詰めをしないため、素通しすると不変条件が破れる）。
    func test_settingText_onStickerItem_isNoOp() {
        let state = makeState().addingStickerItem("😀", atCompositionTime: 0, duration: 2)
        let id = state.textItems[0].id

        XCTAssertEqual(state.settingText(id: id, text: "乗っ取り"), state,
                       "ステッカーに普通のテキスト編集が効いてしまった")
    }

    /// `settingStickerContent` は中身を書記素クラスタ 1 個へ切り詰めて反映する。
    func test_settingStickerContent_truncatesToSingleGraphemeCluster() {
        let state = makeState().addingStickerItem("😀", atCompositionTime: 0, duration: 2)
        let id = state.textItems[0].id

        let updated = state.settingStickerContent(id: id, emoji: "🎉🔥")
        XCTAssertEqual(updated.textItems[0].text, "🎉",
                       "ステッカーの差し替えで書記素クラスタ 1 個への切り詰めが効いていない")
    }
}
