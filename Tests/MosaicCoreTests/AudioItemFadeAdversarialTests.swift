import XCTest
@testable import MosaicCore

/// C（検証）担当・敵対的テスト。E2-2 の BGM フェードを壊しにかかる。
///
/// このファイルは検証専用（隔離ツリー内）。壊れた入力・操作列を実際に走らせて
/// 不変条件 I-A4（フェードイン＋アウトが重ならない）や validate() が破られるかを見る。
final class AudioItemFadeAdversarialTests: XCTestCase {
    private let audioSource = UUID()
    private let videoSource = UUID()

    private func makeState(audioItems: [AudioItem] = [], clipDuration: Double = 1000) -> TimelineState {
        TimelineState(
            clips: [TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: clipDuration)],
            audioItems: audioItems,
            sources: [videoSource: TimelineSource(id: videoSource, kind: .video),
                      audioSource: TimelineSource(id: audioSource, kind: .audio)])
    }

    private func item(start: Double, duration: Double, sourceStart: Double = 0,
                      volume: Float = 1) -> AudioItem {
        AudioItem(sourceID: audioSource, sourceStart: sourceStart,
                  sourceEnd: sourceStart + duration, compositionStart: start, volume: volume)
    }

    // MARK: 1. overlap-shift 経由での duration 縮小と reclamp

    /// normalizedAudioItems の重なり解消（shift）は sourceEnd を動かさず sourceStart だけ
    /// 動かすので duration が縮む。このとき既存の fadeIn/fadeOut が新しい duration/2 を
    /// 超えていないか、shift 由来の縮小パスでも clampFades が効いているかを直接確認する。
    func test_overlapShift_reclampsFadeOfPushedItem() {
        // A: composition [0, 10)。B: composition [8, 18) で A と重なる（本来は編集操作が
        // 防ぐが、下書き改変や将来の不整合を想定して直接 normalizedAudioItems へ渡す）。
        let a = item(start: 0, duration: 10)
        var b = item(start: 8, duration: 10)
        b.fadeInDuration = 4.9 // shift 前は duration/2=5 以内で正当
        b.fadeOutDuration = 4.9

        let normalized = TimelineState.normalizedAudioItems([a, b])
        XCTAssertEqual(normalized.count, 2, "重なり解消で片方が消えた")
        let shiftedB = normalized[1]
        // shift = a.compositionEnd(10) - b.compositionStart(8) = 2 → duration 10-2=8
        XCTAssertEqual(shiftedB.duration, 8, accuracy: 1e-9, "shift 後の duration が想定と違う")
        XCTAssertLessThanOrEqual(shiftedB.fadeInDuration, shiftedB.duration / 2 + 1e-9,
                                 "overlap-shift 後にフェードインが丸め直されていない")
        XCTAssertLessThanOrEqual(shiftedB.fadeOutDuration, shiftedB.duration / 2 + 1e-9,
                                 "overlap-shift 後にフェードアウトが丸め直されていない")
        let state = makeState(audioItems: normalized)
        XCTAssertTrue(state.validate(), "overlap-shift 後の状態が不変条件を満たさない")
    }

    /// 3 本の連鎖する重なり（A-B-C）で shift が連鎖しても、全項目で丸め直しが保たれるか。
    func test_chainedOverlapShift_allItemsReclamped() {
        let a = item(start: 0, duration: 6)
        var b = item(start: 1, duration: 6) // A と重なる
        b.fadeInDuration = 2.9
        b.fadeOutDuration = 2.9
        var c = item(start: 2, duration: 6) // A・B とも重なる可能性
        c.fadeInDuration = 2.9
        c.fadeOutDuration = 2.9

        let normalized = TimelineState.normalizedAudioItems([a, b, c])
        for normalizedItem in normalized {
            XCTAssertLessThanOrEqual(normalizedItem.fadeInDuration,
                                     normalizedItem.duration / 2 + 1e-9,
                                     "連鎖 shift でフェードインが超過: \(normalizedItem)")
            XCTAssertLessThanOrEqual(normalizedItem.fadeOutDuration,
                                     normalizedItem.duration / 2 + 1e-9,
                                     "連鎖 shift でフェードアウトが超過: \(normalizedItem)")
        }
        let state = makeState(audioItems: normalized)
        XCTAssertTrue(state.validate(), "連鎖 shift 後の状態が不変条件を満たさない")
    }

    // MARK: 2. 極端な尺（0.01 秒 / 最小長ぎりぎり）

    func test_settingAudioFade_atMinimumDuration() {
        // minimumDuration ちょうど（0.1 秒）の BGM。
        let target = item(start: 0, duration: AudioItem.minimumDuration)
        let state = makeState(audioItems: [target])
        let applied = state.settingAudioFade(id: target.id, fadeIn: 10, fadeOut: 10)
        let cap = AudioItem.minimumDuration / 2
        XCTAssertEqual(applied.audioItems[0].fadeInDuration, cap, accuracy: 1e-12)
        XCTAssertEqual(applied.audioItems[0].fadeOutDuration, cap, accuracy: 1e-12)
        XCTAssertTrue(applied.validate())
    }

    /// 尺 0.01 秒（minimumDuration 未満）の BGM は、そもそも addingAudioItem 側で
    /// 弾かれるはず（帯としても掴めない、という doc の規則）。
    func test_addingAudioItem_rejectsTinyDuration() {
        let state = makeState()
        let added = state.addingAudioItem(sourceID: audioSource, sourceDuration: 0.01,
                                          atCompositionTime: 0)
        XCTAssertEqual(added.audioItems.count, 0,
                       "0.01 秒の BGM が minimumDuration 未満のまま追加された")
    }

    // MARK: 3. NaN / 無限大の混入

    func test_settingAudioFade_infiniteAndNaNAreRejectedToZero() {
        let target = item(start: 0, duration: 10)
        let state = makeState(audioItems: [target])
        let applied = state.settingAudioFade(id: target.id, fadeIn: .infinity, fadeOut: .nan)
        XCTAssertEqual(applied.audioItems[0].fadeInDuration, 0, accuracy: 1e-12,
                       "無限大のフェードインがそのまま入った")
        XCTAssertEqual(applied.audioItems[0].fadeOutDuration, 0, accuracy: 1e-12,
                       "NaN のフェードアウトがそのまま入った")
        XCTAssertTrue(applied.validate())
    }

    /// 直接フィールドを書き換えて（下書き改変・将来の不整合の想定）NaN/負の duration を
    /// 作ったとき、normalizedAudioItems と validate() が確実に弾くか。
    func test_normalizedAudioItems_dropsItemWithNegativeDuration() {
        // sourceEnd < sourceStart で duration が負になる異常値を直接作る。
        var broken = AudioItem(sourceID: audioSource, sourceStart: 5, sourceEnd: 5,
                               compositionStart: 0)
        broken.sourceEnd = 2 // duration = -3
        let normalized = TimelineState.normalizedAudioItems([broken])
        XCTAssertEqual(normalized.count, 0, "負の duration の項目が正規化を素通りした")
    }

    // MARK: 4. フェードイン＋アウトが尺を超える組み合わせの直接構築

    /// settingAudioFade を 2 回に分けて呼ぶと、1 回目の結果を踏まえて 2 回目が
    /// クランプされるため、原理的に合計が尺を超えられないはず。これを実際に確かめる。
    func test_settingAudioFade_sequentialCallsNeverExceedDuration() {
        let target = item(start: 0, duration: 10)
        let state = makeState(audioItems: [target])
        // まずフェードインを尺いっぱい（10 秒）要求 → 5 秒にクランプされる。
        let step1 = state.settingAudioFade(id: target.id, fadeIn: 10, fadeOut: 0)
        // 続けてフェードアウトも尺いっぱい要求 → こちらも 5 秒にクランプされる。
        let step2 = step1.settingAudioFade(id: target.id, fadeIn: step1.audioItems[0].fadeInDuration,
                                           fadeOut: 10)
        let sum = step2.audioItems[0].fadeInDuration + step2.audioItems[0].fadeOutDuration
        XCTAssertLessThanOrEqual(sum, step2.audioItems[0].duration + 1e-9,
                                 "フェードイン+アウトの合計が尺を超えた")
        XCTAssertTrue(step2.validate())
    }

    // MARK: 5. トリムで縮めた後・伸ばした後

    /// 縮めてフェードが小さく丸められた後、伸ばし直しても（doc 通り）自動では戻らない
    /// ことを確認する。仕様上の「戻らない」を bug として誤検出しないための固定テスト。
    func test_trimShrinkThenGrow_fadeStaysClampedNotRestored() {
        var target = item(start: 0, duration: 10)
        target.fadeInDuration = 4
        target.fadeOutDuration = 4
        let shrunk = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: -8,
                               sourceDuration: 100)
        XCTAssertEqual(shrunk.audioItems[0].duration, 2, accuracy: 1e-9)
        XCTAssertEqual(shrunk.audioItems[0].fadeInDuration, 1, accuracy: 1e-9)

        let grown = shrunk.trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: 8,
                                             sourceDuration: 100)
        XCTAssertEqual(grown.audioItems[0].duration, 10, accuracy: 1e-9)
        // フェードは伸ばしても復元されない（意図された挙動）。
        XCTAssertEqual(grown.audioItems[0].fadeInDuration, 1, accuracy: 1e-9,
                       "伸長でフェードが勝手に復元された（意図しない挙動変化）")
        XCTAssertTrue(grown.validate())
    }

    // MARK: 6. 下書きの保存→復元で壊れた値が残らないか

    /// 手で書き換えた JSON（フェードが尺を超過・重なり順序が壊れている）を復元しても
    /// validate() が真になる（＝デコード経路の normalizedAudioItems が効いている）か。
    func test_decode_malformedFadeAndOverlap_isRepairedNotPropagated() throws {
        let a = item(start: 0, duration: 10)
        let b = item(start: 10, duration: 10)
        let state = makeState(audioItems: [a, b])
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(object["audioItems"] as? [[String: Any]])
        // 手で壊す: 1本目のフェードを尺超過に、2本目の compositionStart を 1本目の内側へ。
        items[0]["fadeInDuration"] = 999.0
        items[0]["fadeOutDuration"] = 999.0
        items[1]["compositionStart"] = 5.0
        object["audioItems"] = items
        let malformed = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TimelineState.self, from: malformed)
        XCTAssertTrue(decoded.validate(), "壊れた下書きの復元が不変条件を満たさない")
        for decodedItem in decoded.audioItems {
            XCTAssertLessThanOrEqual(decodedItem.fadeInDuration, decodedItem.duration / 2 + 1e-9)
            XCTAssertLessThanOrEqual(decodedItem.fadeOutDuration, decodedItem.duration / 2 + 1e-9)
        }
    }

    // MARK: 7. 速度変更・削除で BGM の載る区間が変わったとき（合成尺クリップ）

    /// クリップを消して合成尺が縮んだとき、effectiveAudioItems 経由でフェードが
    /// 壊れずクランプされるか（AudioMixFactory が読むのはここ）。
    func test_effectiveAudioItems_afterCompositionShrink_fadeStaysWithinBounds() {
        var target = item(start: 5, duration: 10)
        target.fadeInDuration = 4
        target.fadeOutDuration = 4
        let state = makeState(audioItems: [target])
        // 合成尺が 8 秒まで縮んだ想定（クリップ削除相当）。
        let effective = state.effectiveAudioItems(totalDuration: 8)
        XCTAssertEqual(effective.count, 1)
        let clippedItem = effective[0]
        XCTAssertEqual(clippedItem.duration, 3, accuracy: 1e-9, "テスト前提の尺が想定と違う")
        XCTAssertLessThanOrEqual(clippedItem.fadeInDuration, clippedItem.duration / 2 + 1e-9,
                                 "合成尺クリップ後にフェードインが超過")
        XCTAssertLessThanOrEqual(clippedItem.fadeOutDuration, clippedItem.duration / 2 + 1e-9,
                                 "合成尺クリップ後にフェードアウトが超過")
    }

    // MARK: 8. undo/redo 相当（状態のスナップショット比較）で壊れた値が復元されないか

    /// settingAudioFade が no-op のとき self を返す契約（undo 履歴を汚さない）が、
    /// 極端値でも壊れないか。
    func test_settingAudioFade_noOpContract_withExtremeValues() {
        let target = item(start: 0, duration: 10)
        let state = makeState(audioItems: [target])
        // 既に 0,0 のところへ NaN/Infinity → 0,0 になるので no-op のはず。
        let result = state.settingAudioFade(id: target.id, fadeIn: .nan, fadeOut: .infinity)
        XCTAssertEqual(result, state, "NaN/Infinity 指定が no-op にならず余計な状態変化を作った")
    }

    // MARK: 9. clampedFade 自身の契約違反（duration が非有限のとき）

    /// doc は「非有限・0 以下は 0（フェードなし）に落とす」と謳うが、実装は
    /// `value` の非有限しかガードしていない。`duration` が NaN のとき
    /// `max(duration, 0)` が Swift の比較意味論で NaN のまま通り、
    /// 続く `min(value, NaN)` も NaN 比較が常に false になるため
    /// 第一引数（元の value）をそのまま返してしまう。
    func test_clampedFade_contractViolation_whenDurationIsNaN() {
        let result = AudioItem.clampedFade(1_000_000, duration: .nan)
        XCTAssertEqual(result, 0, accuracy: 1e-9,
                       "duration が NaN のときフェード値がクランプされずそのまま返った: \(result)")
    }

    /// duration が +infinity のときも同様に「非有限」として 0 に落ちるべきだが、
    /// cap が infinity になり value がそのまま通る。
    func test_clampedFade_contractViolation_whenDurationIsInfinite() {
        let result = AudioItem.clampedFade(1_000_000, duration: .infinity)
        XCTAssertEqual(result, 0, accuracy: 1e-9,
                       "duration が +infinity のときフェード値がクランプされずそのまま返った: \(result)")
    }

    /// この契約違反が AudioItem 自体の生成（init → clampFades）でも再現するか。
    /// sourceStart/sourceEnd が両方 +infinity だと duration = infinity - infinity = NaN になる。
    func test_init_withInfiniteSourceBounds_producesNaNDurationButUnclampedFade() {
        let broken = AudioItem(sourceID: audioSource, sourceStart: .infinity, sourceEnd: .infinity,
                               compositionStart: 0, fadeInDuration: 500, fadeOutDuration: 500)
        XCTAssertTrue(broken.duration.isNaN, "テスト前提: duration が NaN になっていない")
        XCTAssertEqual(broken.fadeInDuration, 0, accuracy: 1e-9,
                       "duration が NaN の AudioItem で fadeInDuration がクランプされず \(broken.fadeInDuration) のまま残った")
    }
}
