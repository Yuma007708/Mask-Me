import XCTest
@testable import MosaicCore

/// E2-2: BGM（`AudioItem`）のフェードイン／アウト。
///
/// `AudioItemEditingTests` が `type_body_length` の閾値に張り付いているため分けてある
/// （同ファイルの分割方針と同じ理由）。**BGM は合成時刻アンカー**（クリップ編集に
/// 追従しない）で、**曲どうしは重ならない**という前提は `AudioItemEditingTests` と共通。
final class AudioItemFadeTests: XCTestCase {
    private let audioSource = UUID()
    private let videoSource = UUID()

    /// 動画 1 本（合成尺 10 秒）＋ BGM 素材を登録した状態。
    private func makeState(audioItems: [AudioItem] = []) -> TimelineState {
        TimelineState(
            clips: [TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 10)],
            audioItems: audioItems,
            sources: [videoSource: TimelineSource(id: videoSource, kind: .video),
                      audioSource: TimelineSource(id: audioSource, kind: .audio)])
    }

    private func item(start: Double, duration: Double, sourceStart: Double = 0,
                      volume: Float = 1) -> AudioItem {
        AudioItem(sourceID: audioSource, sourceStart: sourceStart,
                  sourceEnd: sourceStart + duration, compositionStart: start, volume: volume)
    }

    // MARK: - フェード（E2-2）

    /// フェード時間の丸めは純関数（`AudioItem.clampedFade`）。上限は再生尺の半分。
    func test_clampedFade_capsAtHalfOfDuration() {
        XCTAssertEqual(AudioItem.clampedFade(3, duration: 10), 3, accuracy: 1e-12,
                       "半分未満なのに丸められた")
        XCTAssertEqual(AudioItem.clampedFade(8, duration: 10), 5, accuracy: 1e-12,
                       "半分を超えたのに丸められていない")
        XCTAssertEqual(AudioItem.clampedFade(0, duration: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(AudioItem.clampedFade(-1, duration: 10), 0, accuracy: 1e-12,
                       "負の値がそのまま残った")
        XCTAssertEqual(AudioItem.clampedFade(.nan, duration: 10), 0, accuracy: 1e-12,
                       "非有限値がそのまま残った")
        XCTAssertEqual(AudioItem.clampedFade(5, duration: 0), 0, accuracy: 1e-12,
                       "duration 0 で正の丸め上限が出た")
        XCTAssertEqual(AudioItem.clampedFade(5, duration: -4), 0, accuracy: 1e-12,
                       "負の duration で正の丸め上限が出た")
    }

    /// init から既にクランプされている（イン・アウト独立に半分ずつ）。
    func test_init_clampsFadesToHalfOfDuration() {
        let created = AudioItem(sourceID: audioSource, sourceStart: 0, sourceEnd: 10,
                                compositionStart: 0, fadeInDuration: 8, fadeOutDuration: 9)
        XCTAssertEqual(created.fadeInDuration, 5, accuracy: 1e-12)
        XCTAssertEqual(created.fadeOutDuration, 5, accuracy: 1e-12)
        // 両方が上限いっぱいでも合計が duration を超えない（重ならない）。
        XCTAssertLessThanOrEqual(created.fadeInDuration + created.fadeOutDuration,
                                 created.duration + 1e-9)
    }

    func test_settingAudioFade_clampsIndependently() {
        let target = item(start: 0, duration: 10)
        let state = makeState(audioItems: [target])

        let applied = state.settingAudioFade(id: target.id, fadeIn: 100, fadeOut: 2)
        XCTAssertEqual(applied.audioItems[0].fadeInDuration, 5, accuracy: 1e-12,
                       "フェードインが上限で丸められていない")
        XCTAssertEqual(applied.audioItems[0].fadeOutDuration, 2, accuracy: 1e-12,
                       "上限内のフェードアウトまで丸められた")

        XCTAssertEqual(state.settingAudioFade(id: target.id, fadeIn: 0, fadeOut: 0), state,
                       "同じ値の設定で状態が変わった（undo 履歴が汚れる）")
        XCTAssertEqual(state.settingAudioFade(id: UUID(), fadeIn: 1, fadeOut: 1), state,
                       "存在しない id で状態が変わった")
    }

    /// **丸め処理そのものの番人。**
    ///
    /// トリムや正規化の経路から見るテストは、`trimmingAudioItem` の中の
    /// `clampFades()` を消しても**落ちない**（直後の `normalizedAudioItems` が
    /// 同じ丸めをもう一度掛けるため）。守っているつもりの行が守られていない状態に
    /// なるので、`clampFades()` 単体を直接呼ぶこのテストが要る。
    func test_clampFades_丸めそのものが効く() {
        var target = item(start: 0, duration: 10)
        target.fadeInDuration = 4
        target.fadeOutDuration = 4
        // 尺だけを縮める（経路を通さず、丸め処理だけを見る）。
        target.sourceEnd = target.sourceStart + 2
        target.clampFades()
        XCTAssertEqual(target.fadeInDuration, 1, accuracy: 1e-9)
        XCTAssertEqual(target.fadeOutDuration, 1, accuracy: 1e-9)
    }

    /// 尺が壊れた値（NaN・無限大）でも丸めが素通しにならないこと。
    ///
    /// Swift の `min`/`max` は NaN との比較が常に false なので、`duration` 側の
    /// 非有限を弾かないと `min(value, .nan)` が `value` をそのまま返す＝丸めが効かない。
    /// いまの編集 API からは到達しないが、ここは最後の砦なので素通しにしない。
    func test_clampedFade_壊れた尺でも素通しにならない() {
        XCTAssertEqual(AudioItem.clampedFade(1_000_000, duration: .nan), 0)
        XCTAssertEqual(AudioItem.clampedFade(1_000_000, duration: .infinity), 0)
        XCTAssertEqual(AudioItem.clampedFade(1_000_000, duration: -.infinity), 0)
    }

    /// **トリムで尺が縮んだら、古いフェード値のままにせず丸め直す。**
    ///
    /// なお、これは経路の統合確認であって `trimmingAudioItem` 内の `clampFades()` の
    /// 番人ではない（同じ丸めを `normalizedAudioItems` も掛けるため、片方を消しても
    /// 落ちない）。丸めそのものは `test_clampFades_丸めそのものが効く` が守る。
    func test_trimmingAudioItem_reclampsFadeAfterShrinking() {
        var target = item(start: 0, duration: 10)
        target.fadeInDuration = 4
        target.fadeOutDuration = 4
        let state = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: -8,
                               sourceDuration: 100)

        let trimmed = state.audioItems[0]
        XCTAssertEqual(trimmed.duration, 2, accuracy: 1e-9, "テスト前提の尺が想定と違う")
        XCTAssertLessThanOrEqual(trimmed.fadeInDuration, trimmed.duration / 2 + 1e-9,
                                 "縮んだ尺に対してフェードインが丸め直されていない")
        XCTAssertLessThanOrEqual(trimmed.fadeOutDuration, trimmed.duration / 2 + 1e-9,
                                 "縮んだ尺に対してフェードアウトが丸め直されていない")
        XCTAssertTrue(state.validate(), "丸め直し後も不変条件を満たさない")
    }

    /// `clipped(toTotalDuration:)` で末尾が切れて尺が縮んだときも丸め直す。
    func test_clipped_reclampsFadeAfterTailIsCut() throws {
        var target = item(start: 8, duration: 10)
        target.fadeInDuration = 4
        target.fadeOutDuration = 4

        let clipped = try XCTUnwrap(target.clipped(toTotalDuration: 10))
        XCTAssertEqual(clipped.duration, 2, accuracy: 1e-9, "テスト前提の尺が想定と違う")
        XCTAssertLessThanOrEqual(clipped.fadeInDuration, clipped.duration / 2 + 1e-9)
        XCTAssertLessThanOrEqual(clipped.fadeOutDuration, clipped.duration / 2 + 1e-9)
    }

    func test_normalizedAudioItems_reclampsOversizedFade() {
        var oversized = item(start: 0, duration: 4)
        oversized.fadeInDuration = 3.9
        oversized.fadeOutDuration = 3.9

        let normalized = TimelineState.normalizedAudioItems([oversized])
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].fadeInDuration, 2, accuracy: 1e-12,
                       "正規化でフェードが丸め直されていない")
        XCTAssertEqual(normalized[0].fadeOutDuration, 2, accuracy: 1e-12,
                       "正規化でフェードが丸め直されていない")
    }

    /// 番人: フェード（E2-2）の無い旧下書きは「フェードなし（0 秒）」として復元される。
    func test_codable_legacyDraftWithoutFade_decodesAsZeroFade() throws {
        let state = makeState(audioItems: [item(start: 1, duration: 4)])
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(object["audioItems"] as? [[String: Any]])
        for index in items.indices {
            items[index]["fadeInDuration"] = nil
            items[index]["fadeOutDuration"] = nil
        }
        object["audioItems"] = items

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: legacyData)

        XCTAssertEqual(decoded.audioItems.count, 1)
        XCTAssertEqual(decoded.audioItems[0].fadeInDuration, 0, accuracy: 1e-12,
                       "フェードキーの無い旧下書きが 0 秒で復元されていない")
        XCTAssertEqual(decoded.audioItems[0].fadeOutDuration, 0, accuracy: 1e-12,
                       "フェードキーの無い旧下書きが 0 秒で復元されていない")
        XCTAssertTrue(decoded.validate())
    }

    /// フェードを含む往復（エンコード → デコード）で値が保たれる。
    func test_codable_roundTripKeepsFade() throws {
        var withFade = item(start: 0, duration: 10)
        withFade.fadeInDuration = 2
        withFade.fadeOutDuration = 3
        let state = makeState(audioItems: [withFade])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(decoded, state, "フェードを含む往復で状態が変わった")
        XCTAssertEqual(decoded.audioItems[0].fadeInDuration, 2, accuracy: 1e-12)
        XCTAssertEqual(decoded.audioItems[0].fadeOutDuration, 3, accuracy: 1e-12)
    }
}
