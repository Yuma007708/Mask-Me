import XCTest
@testable import MosaicCore

/// E2-1: BGM（`AudioItem`）のデータモデル・編集操作・永続化。
///
/// **BGM は合成時刻アンカー**（クリップ編集に追従しない）で、**曲どうしは重ならない**
/// （ユーザー決定 2026-08-02）。この 2 点が全テストの前提である。
final class AudioItemEditingTests: XCTestCase {
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

    // MARK: - 追加

    func test_addingAudioItem_placesFullSourceLengthAtRequestedTime() {
        let state = makeState().addingAudioItem(sourceID: audioSource, sourceDuration: 4,
                                                atCompositionTime: 2)

        XCTAssertEqual(state.audioItems.count, 1)
        let added = state.audioItems[0]
        XCTAssertEqual(added.compositionStart, 2, accuracy: 1e-12)
        XCTAssertEqual(added.duration, 4, accuracy: 1e-12)
        XCTAssertEqual(added.sourceStart, 0, accuracy: 1e-12, "曲の頭から使っていない")
        XCTAssertEqual(added.volume, 1, "既定音量が 1 でない")
        XCTAssertTrue(state.validate())
    }

    /// **次の曲とぶつかる場合はそこで切る**（後ろへ押しのけない）。
    /// 押しのけると、置いただけで既存の BGM の位置が動いてしまう。
    func test_addingAudioItem_truncatesAtNextItemInsteadOfPushingIt() {
        let existing = item(start: 5, duration: 3)
        let state = makeState(audioItems: [existing])
            .addingAudioItem(sourceID: audioSource, sourceDuration: 10, atCompositionTime: 2)

        XCTAssertEqual(state.audioItems.count, 2)
        XCTAssertEqual(state.audioItems[0].compositionEnd, 5, accuracy: 1e-12,
                       "次の曲の頭で切れていない")
        XCTAssertEqual(state.audioItems[1].compositionStart, 5, accuracy: 1e-12,
                       "既存の曲が後ろへ押しのけられた")
        XCTAssertTrue(state.validate())
    }

    /// 既存の曲の内側には置けない（重ならない規則）。
    func test_addingAudioItem_insideExistingItem_isNoOp() {
        let state = makeState(audioItems: [item(start: 2, duration: 5)])
        XCTAssertEqual(state.addingAudioItem(sourceID: audioSource, sourceDuration: 1,
                                             atCompositionTime: 3), state,
                       "既存の曲の上に重ねて置けてしまう")
    }

    /// 置ける幅が最小長に満たないなら何もしない（掴めない帯を作らない）。
    func test_addingAudioItem_withInsufficientGap_isNoOp() {
        let state = makeState(audioItems: [item(start: 2.05, duration: 5)])
        XCTAssertEqual(state.addingAudioItem(sourceID: audioSource, sourceDuration: 5,
                                             atCompositionTime: 2), state,
                       "0.05 秒の隙間に BGM が入ってしまう")
    }

    func test_addingAudioItem_withInvalidInput_isNoOp() {
        let state = makeState()
        XCTAssertEqual(state.addingAudioItem(sourceID: audioSource, sourceDuration: 0,
                                             atCompositionTime: 1), state)
        XCTAssertEqual(state.addingAudioItem(sourceID: audioSource, sourceDuration: .nan,
                                             atCompositionTime: 1), state)
        XCTAssertEqual(state.addingAudioItem(sourceID: audioSource, sourceDuration: 3,
                                             atCompositionTime: -1), state)
    }

    // MARK: - 削除

    func test_removingAudioItem_removesOnlyThatItem() {
        let first = item(start: 0, duration: 2)
        let second = item(start: 3, duration: 2)
        let state = makeState(audioItems: [first, second]).removingAudioItem(id: first.id)

        XCTAssertEqual(state.audioItems.map(\.id), [second.id])
        XCTAssertEqual(state.removingAudioItem(id: UUID()), state, "存在しない id で状態が変わった")
    }

    // MARK: - 移動

    func test_movingAudioItem_shiftsByDelta() {
        let target = item(start: 2, duration: 3)
        let state = makeState(audioItems: [target])
            .movingAudioItem(id: target.id, byCompositionDelta: 1.5)

        XCTAssertEqual(state.audioItems[0].compositionStart, 3.5, accuracy: 1e-12)
        XCTAssertEqual(state.audioItems[0].duration, 3, accuracy: 1e-12, "移動で長さが変わった")
    }

    /// **隣の曲をすり抜けない。** ぶつかる手前でクランプする。
    func test_movingAudioItem_clampsAtNeighbours_doesNotPassThrough() {
        let left = item(start: 0, duration: 2)
        let target = item(start: 3, duration: 2)
        let right = item(start: 8, duration: 2)
        let state = makeState(audioItems: [left, target, right])

        let forward = state.movingAudioItem(id: target.id, byCompositionDelta: 100)
        let movedForward = forward.audioItems.first { $0.id == target.id }
        XCTAssertEqual(movedForward?.compositionEnd ?? -1, 8, accuracy: 1e-9,
                       "右隣をすり抜けた（または手前で止まっていない）")
        XCTAssertTrue(forward.validate())

        let backward = state.movingAudioItem(id: target.id, byCompositionDelta: -100)
        let movedBackward = backward.audioItems.first { $0.id == target.id }
        XCTAssertEqual(movedBackward?.compositionStart ?? -1, 2, accuracy: 1e-9,
                       "左隣をすり抜けた（または手前で止まっていない）")
        XCTAssertTrue(backward.validate())
    }

    func test_movingAudioItem_doesNotGoBeforeZero() {
        let target = item(start: 1, duration: 2)
        let state = makeState(audioItems: [target])
            .movingAudioItem(id: target.id, byCompositionDelta: -5)

        XCTAssertEqual(state.audioItems[0].compositionStart, 0, accuracy: 1e-12,
                       "0 秒より前へ出た")
    }

    /// **合成尺の右端では止めない**（温存の規則）。縮んだタイムラインを伸ばせば戻る。
    func test_movingAudioItem_mayGoBeyondTotalDuration_dataIsKept() {
        let target = item(start: 1, duration: 2)
        let state = makeState(audioItems: [target])
            .movingAudioItem(id: target.id, byCompositionDelta: 50)

        XCTAssertEqual(state.audioItems[0].compositionStart, 51, accuracy: 1e-12,
                       "合成尺の外へ出せない（温存の規則を壊している）")
        XCTAssertTrue(state.effectiveAudioItems(totalDuration: 10).isEmpty,
                      "尺の外の BGM が実効に残っている")
        XCTAssertTrue(state.validate(), "尺の外にあることを不正と判定している")
    }

    func test_movingAudioItem_withZeroOrInvalidDelta_isNoOp() {
        let target = item(start: 1, duration: 2)
        let state = makeState(audioItems: [target])
        XCTAssertEqual(state.movingAudioItem(id: target.id, byCompositionDelta: 0), state)
        XCTAssertEqual(state.movingAudioItem(id: target.id, byCompositionDelta: .nan), state)
        XCTAssertEqual(state.movingAudioItem(id: UUID(), byCompositionDelta: 1), state)
    }

    // MARK: - 端の伸縮

    /// 左端を縮めると、合成位置と素材位置が**同じ量**動く（BGM に倍速は無い）。
    func test_trimmingAudioItem_start_movesCompositionAndSourceTogether() {
        let target = item(start: 2, duration: 4, sourceStart: 1)
        let state = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .start, byCompositionDelta: 1,
                               sourceDuration: 30)

        XCTAssertEqual(state.audioItems[0].compositionStart, 3, accuracy: 1e-12)
        XCTAssertEqual(state.audioItems[0].sourceStart, 2, accuracy: 1e-12,
                       "素材時刻が合成時刻と同じ量だけ動いていない")
        XCTAssertEqual(state.audioItems[0].duration, 3, accuracy: 1e-12)
    }

    /// 左端は素材の頭（`sourceStart == 0`）より先へは伸ばせない。
    func test_trimmingAudioItem_start_clampsAtSourceHead() {
        let target = item(start: 5, duration: 4, sourceStart: 1)
        let state = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .start, byCompositionDelta: -10,
                               sourceDuration: 30)

        XCTAssertEqual(state.audioItems[0].sourceStart, 0, accuracy: 1e-12,
                       "素材の頭より前から鳴らそうとしている")
        XCTAssertEqual(state.audioItems[0].compositionStart, 4, accuracy: 1e-12,
                       "合成位置が素材の伸びと同じ量だけ動いていない")
    }

    /// 右端は素材の尻より先へは伸ばせない。
    func test_trimmingAudioItem_end_clampsAtSourceTail() {
        let target = item(start: 0, duration: 4)
        let state = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: 10,
                               sourceDuration: 6)

        XCTAssertEqual(state.audioItems[0].sourceEnd, 6, accuracy: 1e-12,
                       "音源の実尺を超えて伸ばせてしまう")
    }

    /// 右端は次の曲にもぶつからない。
    func test_trimmingAudioItem_end_clampsAtNextItem() {
        let target = item(start: 0, duration: 2)
        let next = item(start: 3, duration: 2)
        let state = makeState(audioItems: [target, next])
            .trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: 10,
                               sourceDuration: 100)

        XCTAssertEqual(state.audioItems[0].compositionEnd, 3, accuracy: 1e-9,
                       "次の曲へ食い込んだ")
        XCTAssertTrue(state.validate())
    }

    /// 最小長より短くはできない。
    func test_trimmingAudioItem_cannotShrinkBelowMinimum() {
        let target = item(start: 0, duration: 1)
        let state = makeState(audioItems: [target])
            .trimmingAudioItem(id: target.id, edge: .end, byCompositionDelta: -10,
                               sourceDuration: 100)

        XCTAssertGreaterThanOrEqual(state.audioItems[0].duration,
                                    AudioItem.minimumDuration - 1e-12,
                                    "掴めない長さまで縮められる")
    }

    // MARK: - 音量

    func test_settingAudioVolume_clampsToUnitRange() {
        let target = item(start: 0, duration: 2)
        let state = makeState(audioItems: [target])

        XCTAssertEqual(state.settingAudioVolume(id: target.id, volume: 0.4)
            .audioItems[0].volume, 0.4, accuracy: 1e-6)
        XCTAssertEqual(state.settingAudioVolume(id: target.id, volume: 5)
            .audioItems[0].volume, 1, accuracy: 1e-6)
        XCTAssertEqual(state.settingAudioVolume(id: target.id, volume: -2)
            .audioItems[0].volume, 0, accuracy: 1e-6)
        XCTAssertEqual(state.settingAudioVolume(id: target.id, volume: 1), state,
                       "同じ値の設定で状態が変わった（undo 履歴が汚れる）")
    }

    // MARK: - 合成尺での切り出し（表示・書き出しの唯一の入口）

    func test_effectiveAudioItems_clipsTailToTotalDuration() {
        let target = item(start: 8, duration: 5)
        let state = makeState(audioItems: [target])

        let effective = state.effectiveAudioItems(totalDuration: 10)
        XCTAssertEqual(effective.count, 1)
        XCTAssertEqual(effective[0].duration, 2, accuracy: 1e-12, "合成尺で切れていない")
        XCTAssertEqual(effective[0].sourceStart, 0, accuracy: 1e-12,
                       "末尾を切っただけなのに頭が動いた")
        XCTAssertEqual(state.audioItems[0].duration, 5, accuracy: 1e-12,
                       "元データが切られている（温存の規則を壊している）")
    }

    /// 完全にはみ出したら実効からは消えるが、**データは残る**（トリムを戻せば復活する）。
    func test_effectiveAudioItems_dropsFullyOutOfRangeButKeepsData() {
        let target = item(start: 20, duration: 5)
        let state = makeState(audioItems: [target])

        XCTAssertTrue(state.effectiveAudioItems(totalDuration: 10).isEmpty)
        XCTAssertEqual(state.audioItems.count, 1, "尺の外の BGM が消された")
        XCTAssertEqual(state.effectiveAudioItems(totalDuration: 30).count, 1,
                       "尺を伸ばしても復活しない")
    }

    // MARK: - 正規化（最後の砦）

    func test_normalizedAudioItems_sortsAndResolvesOverlapByTrimmingLater() {
        let first = item(start: 0, duration: 5)
        let overlapping = item(start: 3, duration: 4)
        let normalized = TimelineState.normalizedAudioItems([overlapping, first])

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].compositionStart, 0, accuracy: 1e-12, "昇順に並んでいない")
        XCTAssertEqual(normalized[1].compositionStart, 5, accuracy: 1e-12,
                       "重なりが解消されていない")
        XCTAssertEqual(normalized[1].sourceStart, 2, accuracy: 1e-12,
                       "頭を詰めたのに素材時刻が追随していない（曲がずれて鳴る）")
        XCTAssertEqual(normalized[1].compositionEnd, 7, accuracy: 1e-12,
                       "後ろへ押し出されている（尻は動かさない）")
    }

    func test_normalizedAudioItems_dropsInvalidItems() {
        let items = [
            item(start: 0, duration: 0.01),                              // 最小長未満
            item(start: -1, duration: 2),                                // 負の開始位置
            AudioItem(sourceID: audioSource, sourceStart: .nan, sourceEnd: 2,
                      compositionStart: 5),                              // 非有限
            item(start: 20, duration: 2, volume: 9)                      // 音量が範囲外
        ]
        let normalized = TimelineState.normalizedAudioItems(items)

        XCTAssertEqual(normalized.count, 1, "不正な BGM が残っている")
        XCTAssertEqual(normalized[0].volume, 1, accuracy: 1e-6, "音量がクランプされていない")
    }

    // MARK: - 不変条件

    func test_validate_rejectsBrokenAudioItems() {
        XCTAssertFalse(makeState(audioItems: [item(start: 0, duration: 5),
                                              item(start: 3, duration: 2)]).validate(),
                       "重なった BGM を通している（I-A1）")
        XCTAssertFalse(makeState(audioItems: [item(start: -1, duration: 2)]).validate(),
                       "負の開始位置を通している")
        XCTAssertFalse(makeState(audioItems: [item(start: 0, duration: 0.01)]).validate(),
                       "最小長未満を通している")
        XCTAssertFalse(makeState(audioItems: [item(start: 0, duration: 2, volume: 3)]).validate(),
                       "範囲外の音量を通している")
        XCTAssertTrue(makeState(audioItems: [item(start: 0, duration: 2),
                                             item(start: 2, duration: 2)]).validate(),
                      "隙間なく隣接しているだけの BGM を弾いている")
    }

    // MARK: - 永続化（schemaVersion 3）

    func test_codable_roundTripKeepsAudioItems() throws {
        let state = makeState(audioItems: [item(start: 1, duration: 2, sourceStart: 4, volume: 0.3),
                                           item(start: 6, duration: 3)])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(decoded, state, "BGM を含む往復で状態が変わった")
        XCTAssertEqual(decoded.audioItems.count, 2)
    }

    /// **番人: v2 の下書き（BGM 以前）が今も読めること。**
    ///
    /// `schemaVersion` を 3 へ上げたので、v2 の JSON を誤って弾く／別の意味に読む退行が
    /// あり得る。v3 のエンコード結果から `audioItems` を落として版を 2 に戻したものを
    /// 復元し、**BGM 無しで、他は元どおり**になることを固定する。
    func test_codable_v2Draft_decodesWithoutAudioItems() throws {
        let state = makeState(audioItems: [item(start: 1, duration: 2)])
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["audioItems"], "v3 のエンコードに audioItems が無い")
        object["audioItems"] = nil
        object["schemaVersion"] = 2

        let v2Data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: v2Data)

        XCTAssertTrue(decoded.audioItems.isEmpty, "v2 の下書きに BGM が生えた")
        XCTAssertEqual(decoded.clips, state.clips, "v2 の下書きでクリップが壊れた")
        XCTAssertEqual(decoded.applyRanges, state.applyRanges, "v2 の下書きで適用区間が壊れた")
        XCTAssertEqual(decoded.sources, state.sources, "v2 の下書きで素材メタが壊れた")
    }

    /// デコードは正規化を通す（手で書き換えられた下書きが実行系へ流れない）。
    func test_codable_decodeNormalizesOverlappingItems() throws {
        let state = makeState()
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["audioItems"] = [
            ["id": UUID().uuidString, "sourceID": audioSource.uuidString,
             "sourceStart": 0, "sourceEnd": 5, "compositionStart": 0, "volume": 1],
            ["id": UUID().uuidString, "sourceID": audioSource.uuidString,
             "sourceStart": 0, "sourceEnd": 4, "compositionStart": 3, "volume": 1]
        ]

        let decoded = try JSONDecoder().decode(
            TimelineState.self, from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertTrue(decoded.validate(), "重なった BGM がそのまま復元された")
        XCTAssertEqual(decoded.audioItems[1].compositionStart, 5, accuracy: 1e-12)
    }
}
