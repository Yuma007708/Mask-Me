import XCTest
@testable import MosaicCore

/// E3-1: テキスト（`TextItem`）のデータモデル・編集操作・アニメーション・永続化。
///
/// **BGM との違いが要点**: テキストは合成時刻アンカーなのは同じだが、
/// **重なってよい**（複数の文字を同時に出せる）。
final class TextItemEditingTests: XCTestCase {
    private func makeState(textItems: [TextItem] = []) -> TimelineState {
        let source = UUID()
        return TimelineState(
            clips: [TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)],
            textItems: textItems,
            sources: [source: TimelineSource(id: source, kind: .video)])
    }

    private func item(_ text: String = "こんにちは",
                      start: Double, duration: Double) -> TextItem {
        TextItem(text: text, compositionStart: start, duration: duration)
    }

    // MARK: - 追加・削除

    func test_addingTextItem_placesAtRequestedTime() {
        let state = makeState().addingTextItem("テスト", atCompositionTime: 2, duration: 3)

        XCTAssertEqual(state.textItems.count, 1)
        XCTAssertEqual(state.textItems[0].text, "テスト")
        XCTAssertEqual(state.textItems[0].compositionStart, 2, accuracy: 1e-12)
        XCTAssertEqual(state.textItems[0].duration, 3, accuracy: 1e-12)
        XCTAssertEqual(state.textItems[0].center, .center, "既定位置が中央でない")
        XCTAssertTrue(state.validate())
    }

    /// **テキストは重なってよい**（BGM と違い、後から置いても切られない）。
    func test_addingTextItem_mayOverlapExistingItems() {
        let state = makeState(textItems: [item(start: 0, duration: 5)])
            .addingTextItem("2 本目", atCompositionTime: 2, duration: 5)

        XCTAssertEqual(state.textItems.count, 2)
        XCTAssertEqual(state.textItems[1].duration, 5, accuracy: 1e-12,
                       "重なりを避けて切られている（テキストは重なってよい）")
        XCTAssertTrue(state.validate(), "重なったテキストを不正と判定している")
    }

    /// 空文字・空白だけは追加しない（掴めない帯を作らない）。
    func test_addingTextItem_withBlankText_isNoOp() {
        let state = makeState()
        XCTAssertEqual(state.addingTextItem("", atCompositionTime: 1, duration: 2), state)
        XCTAssertEqual(state.addingTextItem("   \n ", atCompositionTime: 1, duration: 2), state)
    }

    func test_addingTextItem_withInvalidTiming_isNoOp() {
        let state = makeState()
        XCTAssertEqual(state.addingTextItem("a", atCompositionTime: -1, duration: 2), state)
        XCTAssertEqual(state.addingTextItem("a", atCompositionTime: 1, duration: 0.01), state)
        XCTAssertEqual(state.addingTextItem("a", atCompositionTime: .nan, duration: 2), state)
    }

    /// 前後の空白は落とし、長すぎる文面は切る。
    func test_addingTextItem_trimsAndTruncates() {
        let long = String(repeating: "あ", count: TextItem.maximumTextLength + 50)
        let state = makeState()
            .addingTextItem("  余白あり  ", atCompositionTime: 0, duration: 1)
            .addingTextItem(long, atCompositionTime: 2, duration: 1)

        XCTAssertEqual(state.textItems[0].text, "余白あり", "前後の空白が残っている")
        XCTAssertEqual(state.textItems[1].text.count, TextItem.maximumTextLength,
                       "文字数の上限で切られていない")
        XCTAssertTrue(state.validate())
    }

    func test_removingTextItem_removesOnlyThatItem() {
        let first = item(start: 0, duration: 2)
        let second = item(start: 3, duration: 2)
        let state = makeState(textItems: [first, second]).removingTextItem(id: first.id)

        XCTAssertEqual(state.textItems.map(\.id), [second.id])
        XCTAssertEqual(state.removingTextItem(id: UUID()), state)
    }

    // MARK: - 書き換え

    func test_settingText_rejectsBlank() {
        let target = item(start: 0, duration: 2)
        let state = makeState(textItems: [target])

        XCTAssertEqual(state.settingText(id: target.id, text: "新しい文面")
            .textItems[0].text, "新しい文面")
        XCTAssertEqual(state.settingText(id: target.id, text: "  "), state,
                       "空白だけの文面で上書きできてしまう")
        XCTAssertEqual(state.settingText(id: target.id, text: "こんにちは"), state,
                       "同じ文面の設定で状態が変わった（undo 履歴が汚れる）")
    }

    func test_settingTextStyle_clampsValues() {
        let target = item(start: 0, duration: 2)
        var style = TextStyle()
        style.fontSize = 99
        style.strokeWidth = -1
        style.color = RGBAColor(red: 5, green: .nan, blue: 0, alpha: 2)
        let state = makeState(textItems: [target]).settingTextStyle(id: target.id, style: style)

        let applied = state.textItems[0].style
        XCTAssertEqual(applied.fontSize, TextStyle.maximumFontSize, accuracy: 1e-12,
                       "文字サイズがクランプされていない")
        XCTAssertEqual(applied.strokeWidth, 0, accuracy: 1e-12)
        XCTAssertEqual(applied.color, .white, "非有限を含む色が白へ落ちていない")
        XCTAssertTrue(state.validate())
    }

    func test_settingTextCenter_clampsToScreen() {
        let target = item(start: 0, duration: 2)
        let state = makeState(textItems: [target])
            .settingTextCenter(id: target.id, center: NormalizedPoint(x: 3, y: -2))

        XCTAssertEqual(state.textItems[0].center, NormalizedPoint(x: 1, y: 0),
                       "画面外へ置けてしまう（二度と掴めなくなる）")
    }

    // MARK: - 移動・伸縮

    /// **隣とぶつからない**（BGM と違い、テキストはすり抜けてよい）。
    func test_movingTextItem_passesThroughNeighbours() {
        let left = item(start: 0, duration: 2)
        let target = item(start: 3, duration: 2)
        let state = makeState(textItems: [left, target])
            .movingTextItem(id: target.id, byCompositionDelta: -2.5)

        let moved = state.textItems.first { $0.id == target.id }
        XCTAssertEqual(moved?.compositionStart ?? -1, 0.5, accuracy: 1e-9,
                       "隣で止められている（テキストは重なってよい）")
        XCTAssertTrue(state.validate())
    }

    func test_movingTextItem_doesNotGoBeforeZero() {
        let target = item(start: 1, duration: 2)
        let state = makeState(textItems: [target])
            .movingTextItem(id: target.id, byCompositionDelta: -5)

        XCTAssertEqual(state.textItems[0].compositionStart, 0, accuracy: 1e-12)
    }

    /// **伸ばす上限が無い**（テキストは素材を持たない。BGM との違い）。
    func test_trimmingTextItem_end_hasNoSourceLimit() {
        let target = item(start: 0, duration: 2)
        let state = makeState(textItems: [target])
            .trimmingTextItem(id: target.id, edge: .end, byCompositionDelta: 100)

        XCTAssertEqual(state.textItems[0].duration, 102, accuracy: 1e-9,
                       "テキストの右端に素材尺の制限が掛かっている")
    }

    func test_trimmingTextItem_start_stopsAtZeroAndMinimum() {
        let target = item(start: 1, duration: 2)
        let state = makeState(textItems: [target])

        let toZero = state.trimmingTextItem(id: target.id, edge: .start, byCompositionDelta: -10)
        XCTAssertEqual(toZero.textItems[0].compositionStart, 0, accuracy: 1e-12)
        XCTAssertEqual(toZero.textItems[0].duration, 3, accuracy: 1e-12,
                       "左へ伸ばしたぶん長さが増えていない")

        let shrunk = state.trimmingTextItem(id: target.id, edge: .start, byCompositionDelta: 10)
        XCTAssertGreaterThanOrEqual(shrunk.textItems[0].duration,
                                    TextItem.minimumDuration - 1e-12)
    }

    // MARK: - 合成尺での切り出し

    func test_effectiveTextItems_clipsTailAndKeepsData() {
        let state = makeState(textItems: [item(start: 8, duration: 5), item(start: 30, duration: 2)])

        let effective = state.effectiveTextItems(totalDuration: 10)
        XCTAssertEqual(effective.count, 1, "尺の外のテキストが残っている")
        XCTAssertEqual(effective[0].duration, 2, accuracy: 1e-12, "合成尺で切れていない")
        XCTAssertEqual(state.textItems.count, 2, "元データが消されている（温存の規則）")
    }

    /// `visibleTextItems` は半開区間 `[start, end)`。
    func test_visibleTextItems_usesHalfOpenInterval() {
        let state = makeState(textItems: [item(start: 2, duration: 3)])

        XCTAssertTrue(state.visibleTextItems(atComposition: 2, totalDuration: 10).isEmpty == false,
                      "開始ちょうどで出ていない")
        XCTAssertTrue(state.visibleTextItems(atComposition: 4.99, totalDuration: 10).isEmpty == false)
        XCTAssertTrue(state.visibleTextItems(atComposition: 5, totalDuration: 10).isEmpty,
                      "終端ちょうどで消えていない（半開区間になっていない）")
        XCTAssertTrue(state.visibleTextItems(atComposition: 1.99, totalDuration: 10).isEmpty)
    }

    /// 描く順は `compositionStart` 昇順（重ね順の contract）。
    func test_visibleTextItems_areSortedByStart() {
        let state = makeState(textItems: [item("後", start: 3, duration: 5),
                                          item("先", start: 1, duration: 5)])

        let visible = state.visibleTextItems(atComposition: 4, totalDuration: 10)
        XCTAssertEqual(visible.map(\.text), ["先", "後"], "描く順が開始時刻の昇順でない")
    }

    // MARK: - 不変条件・永続化

    func test_validate_rejectsBrokenTextItems() {
        XCTAssertFalse(makeState(textItems: [item(start: -1, duration: 2)]).validate())
        XCTAssertFalse(makeState(textItems: [item(start: 0, duration: 0.01)]).validate())
        XCTAssertFalse(makeState(textItems: [item("", start: 0, duration: 2)]).validate(),
                       "空文字のテキストを通している")
        var offscreen = item(start: 0, duration: 2)
        offscreen.center = NormalizedPoint(x: 2, y: 0.5)
        XCTAssertFalse(makeState(textItems: [offscreen]).validate(),
                       "画面外の位置を通している")
    }

    func test_codable_roundTripKeepsTextItems() throws {
        var styled = item(start: 1, duration: 2)
        styled.style.fontSize = 0.08
        styled.style.fontFamily = .serif
        styled.style.backgroundOpacity = 0.4
        styled.animation = .slideIn
        styled.center = NormalizedPoint(x: 0.3, y: 0.8)
        let state = makeState(textItems: [styled])

        let decoded = try JSONDecoder().decode(
            TimelineState.self, from: try JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state, "テキストを含む往復で状態が変わった")
        XCTAssertEqual(decoded.textItems[0].animation, .slideIn)
        XCTAssertEqual(decoded.textItems[0].style.fontFamily, .serif)
    }

    /// **番人: v3 の下書き（テキスト以前）が今も読めること。**
    ///
    /// 版番号を直書きしない（E2 で移行テストが 5 本落ちた原因。`legacyJSON` の doc）。
    func test_codable_v3Draft_decodesWithoutTextItems() throws {
        let state = makeState(textItems: [item(start: 1, duration: 2)])
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["textItems"], "v4 のエンコードに textItems が無い")
        object["textItems"] = nil
        object["schemaVersion"] = TimelineState.currentSchemaVersion - 1

        let decoded = try JSONDecoder().decode(
            TimelineState.self, from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertTrue(decoded.textItems.isEmpty, "v3 の下書きにテキストが生えた")
        XCTAssertEqual(decoded.clips, state.clips, "v3 の下書きでクリップが壊れた")
        XCTAssertEqual(decoded.audioItems, state.audioItems, "v3 の下書きで BGM が壊れた")
    }
}

/// アニメーションの純関数（`TextAnimation.parameters`）。
///
/// **プレビューと書き出しはこの 1 本だけを呼ぶ**（数式の二重実装は禁止。
/// トランジションで確立した規約と同じ）。ここが契約の実体である。
final class TextAnimationTests: XCTestCase {
    private func item(duration: Double, animation: TextAnimation) -> TextItem {
        TextItem(text: "a", compositionStart: 0, duration: duration, animation: animation)
    }

    /// `.none` はどの時刻でも変換なし。
    func test_none_isIdentityEverywhere() {
        let target = item(duration: 4, animation: .none)
        for t in stride(from: 0.0, to: 4.0, by: 0.1) {
            XCTAssertEqual(target.renderParameters(atComposition: t), .identity,
                           "t=\(t) で変換が入っている")
        }
    }

    /// 出入りの端では消えていて、中央では完全に出ている。
    func test_fade_isTransparentAtEdgesAndOpaqueInMiddle() {
        let target = item(duration: 4, animation: .fade)
        XCTAssertEqual(target.renderParameters(atComposition: 0)?.opacity ?? -1, 0,
                       accuracy: 1e-9, "先頭で見えている")
        XCTAssertEqual(target.renderParameters(atComposition: 2)?.opacity ?? -1, 1,
                       accuracy: 1e-9, "中央で完全に出ていない")
        XCTAssertLessThan(target.renderParameters(atComposition: 3.99)?.opacity ?? 1, 0.1,
                          "末尾で消えかけていない")
    }

    /// **出入り時間は表示時間の半分を超えない。**
    ///
    /// この関数の戻り値を直接見るのは、`parameters(progress:transitionRatio:)` 側にも
    /// ratio を 0...0.5 へ収める保険があり、**そちらがこのクランプを隠してしまう**ため。
    /// `parameters` 経由でしか検査しないと、ここを固定値に書き換えても全部緑のまま
    /// 通る（実測した）。冗長な安全弁は互いを隠すので、門ごとに固定する。
    func test_transitionDuration_isCappedAtHalfOfItemDuration() {
        XCTAssertEqual(TextAnimation.fade.transitionDuration(forItemDuration: 0.4), 0.2,
                       accuracy: 1e-9, "出入り時間が表示時間の半分に収まっていない")
        XCTAssertEqual(TextAnimation.fade.transitionDuration(forItemDuration: 10),
                       TextAnimation.defaultTransitionDuration, accuracy: 1e-9,
                       "長いテキストで出入り時間が既定値になっていない")
        XCTAssertEqual(TextAnimation.none.transitionDuration(forItemDuration: 10), 0,
                       accuracy: 1e-9, "アニメーション無しで出入り時間が付いている")
    }

    /// 短いテキストでも最大不透明度に達する（上のクランプの帰結）。
    func test_shortItem_stillReachesFullOpacity() {
        let target = item(duration: 0.4, animation: .fade)
        let middle = target.renderParameters(atComposition: 0.2)
        XCTAssertEqual(middle?.opacity ?? -1, 1, accuracy: 1e-9,
                       "短いテキストが完全に表示される瞬間を持たない")
    }

    /// `.scaleUp` は小さい状態から等倍へ。中央で必ず等倍になる。
    func test_scaleUp_growsToIdentityAtMiddle() {
        let target = item(duration: 4, animation: .scaleUp)
        XCTAssertLessThan(target.renderParameters(atComposition: 0)?.scale ?? 9, 0.75,
                          "先頭で縮んでいない")
        XCTAssertEqual(target.renderParameters(atComposition: 2)?.scale ?? -1, 1, accuracy: 1e-9,
                       "中央で等倍になっていない")
    }

    /// `.slideIn` は**入りも出も下側**から（通り過ぎる動きにしない）。
    func test_slideIn_entersAndLeavesFromBelow() {
        let target = item(duration: 4, animation: .slideIn)
        let start = target.renderParameters(atComposition: 0)
        let middle = target.renderParameters(atComposition: 2)
        let nearEnd = target.renderParameters(atComposition: 3.99)

        XCTAssertGreaterThan(start?.offsetY ?? -1, 0, "入りが下側から来ていない")
        XCTAssertEqual(middle?.offsetY ?? -1, 0, accuracy: 1e-9, "中央でずれが残っている")
        XCTAssertGreaterThan(nearEnd?.offsetY ?? -1, 0, "出が下側へ抜けていない")
    }

    /// 区間外は nil（描画側が「出すかどうか」を自分で判断しないための contract）。
    func test_renderParameters_outsideInterval_isNil() {
        let target = TextItem(text: "a", compositionStart: 2, duration: 2, animation: .fade)
        XCTAssertNil(target.renderParameters(atComposition: 1.99))
        XCTAssertNil(target.renderParameters(atComposition: 4), "終端ちょうどで出ている")
        XCTAssertNotNil(target.renderParameters(atComposition: 2))
    }

    /// 不透明度・拡大率は全時刻で有効域に収まる（NaN が描画層へ漏れない）。
    func test_parameters_stayInValidRangeForEveryAnimation() {
        for animation in TextAnimation.allCases {
            let target = item(duration: 3, animation: animation)
            for t in stride(from: 0.0, to: 3.0, by: 0.01) {
                guard let params = target.renderParameters(atComposition: t) else {
                    XCTFail("区間内なのに nil: \(animation) t=\(t)")
                    continue
                }
                XCTAssertTrue(params.opacity.isFinite && params.opacity >= 0 && params.opacity <= 1,
                              "不透明度が範囲外: \(animation) t=\(t) → \(params.opacity)")
                XCTAssertTrue(params.scale.isFinite && params.scale > 0,
                              "拡大率が不正: \(animation) t=\(t) → \(params.scale)")
                XCTAssertTrue(params.offsetX.isFinite && params.offsetY.isFinite,
                              "オフセットが非有限: \(animation) t=\(t)")
            }
        }
    }
}
