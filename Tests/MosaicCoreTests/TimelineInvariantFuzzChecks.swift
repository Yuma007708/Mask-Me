import XCTest
@testable import MosaicCore

/// `TimelineInvariantFuzzTests.assertInvariants` が使う不変条件チェック本体。
///
/// **`TimelineInvariantFuzzTests.swift` の file_length を超えないための分冊**
/// （同ファイルの `Random` 抽出と同じ理由）。`private` にしていないのは、
/// `private` はファイル単位のスコープで、別ファイルの extension からは
/// （たとえ同じ型の extension でも）参照できないため。
extension TimelineInvariantFuzzTests {
    /// トランジション・合成尺・クリップ配置。
    func assertTransitionAndMappingInvariants(_ state: TimelineState, context: String) {
        // トランジションのキーは実在する非末尾クリップで、長さは両隣の半分以下。
        for (key, spec) in state.transitions {
            guard let index = state.clips.firstIndex(where: { $0.id == key }) else {
                XCTFail("トランジションが実在しないクリップを指している: \(context)")
                continue
            }
            XCTAssertLessThan(index + 1, state.clips.count,
                              "末尾クリップにトランジションが残っている: \(context)")
            guard index + 1 < state.clips.count else { continue }
            let cap = min(state.clips[index].duration, state.clips[index + 1].duration) / 2
            XCTAssertLessThanOrEqual(spec.duration, cap + 1e-9,
                                     "トランジションが両隣の半分を超えている: \(context)")
            XCTAssertGreaterThanOrEqual(spec.duration, TransitionSpec.minimumDuration - 1e-9,
                                        "最小長を下回るトランジションが残っている: \(context)")
        }

        // 合成尺 = 各クリップ尺の総和 − 重なりの総和。負にも NaN にもならないこと。
        let mapping = state.mapping
        let sum = state.clips.reduce(0.0) { $0 + $1.duration }
        let overlapSum = mapping.overlaps.reduce(0.0) { $0 + $1.duration }
        XCTAssertTrue(mapping.totalDuration.isFinite, "合成尺が非有限: \(context)")
        XCTAssertGreaterThanOrEqual(mapping.totalDuration, 0, "合成尺が負: \(context)")
        XCTAssertEqual(mapping.totalDuration, sum - overlapSum, accuracy: 1e-6,
                       "合成尺が「総和 − 重なり」と一致しない: \(context)")

        // 重なりは互いに交差せず、必ずタイムラインの内側に収まること。
        let sortedOverlaps = mapping.overlaps.sorted { $0.start < $1.start }
        for (index, overlap) in sortedOverlaps.enumerated() {
            XCTAssertGreaterThanOrEqual(overlap.start, -1e-9, "重なりが負の時刻: \(context)")
            XCTAssertLessThanOrEqual(overlap.end, mapping.totalDuration + 1e-9,
                                     "重なりが合成尺をはみ出している: \(context)")
            XCTAssertGreaterThan(overlap.duration, 0, "長さ 0 の重なり: \(context)")
            if index > 0 {
                XCTAssertGreaterThanOrEqual(overlap.start, sortedOverlaps[index - 1].end - 1e-9,
                                            "重なりどうしが交差している: \(context)")
            }
        }

        // クリップの並びに隙間・逆転が無いこと。
        var cursor = 0.0
        for span in mapping.clipSpans {
            XCTAssertGreaterThan(span.clip.duration, 0, "長さ 0 のクリップ: \(context)")
            XCTAssertLessThanOrEqual(span.start, cursor + 1e-9, "クリップ配置に隙間: \(context)")
            cursor = max(cursor, span.end)
        }
    }

    /// 適用区間（素材時刻アンカー）。
    func assertApplyRangeInvariants(_ state: TimelineState, context: String) {
        // 適用区間は生きているクリップだけを指し、写真は必ず [0, ...) から始まること。
        let clipIDs = Set(state.clips.map(\.id))
        let photoSourceIDs = state.photoSourceIDs
        for range in state.applyRanges {
            XCTAssertTrue(clipIDs.contains(range.clipID),
                          "適用区間が消えたクリップを指している: \(context)")
            XCTAssertTrue(range.sourceStart.isFinite && range.sourceEnd.isFinite,
                          "適用区間の端が非有限: \(context)")
            XCTAssertLessThan(range.sourceStart, range.sourceEnd,
                              "長さ 0 以下の適用区間が残っている: \(context)")
            if photoSourceIDs.contains(range.sourceID) {
                // 写真の素材時刻は常に 0 へ丸められるので、`sourceStart > 0` の区間は
                // ゲートに**絶対にヒットしない**（帯だけ出てモザイクが消える I1 違反）。
                XCTAssertEqual(range.sourceStart, 0, accuracy: 1e-9,
                               "写真クリップの区間が 0 から始まっていない: \(context)")
            }
        }

        // **同じクリップの適用区間どうしは重ならない**（マージ正規化の契約）。
        // 重なりを許すと、端ドラッグ・移動で片方だけを掴んだときに、見えている帯 1 本の
        // 裏にもう 1 本が隠れて「消したはずの区間が残る」状態になる。
        for (_, ranges) in Dictionary(grouping: state.applyRanges, by: \.clipID) {
            let sorted = ranges.sorted { $0.sourceStart < $1.sourceStart }
            for (index, range) in sorted.enumerated() where index > 0 {
                XCTAssertGreaterThanOrEqual(range.sourceStart, sorted[index - 1].sourceEnd - 1e-9,
                                            "同じクリップの適用区間が重なっている: \(context)")
            }
        }
    }

    /// テキスト・ステッカー（合成時刻アンカー。`TextItem.role` で相乗り）。
    ///
    /// **生データは合成尺の外にあってよい**（BGM と同じ温存の規則）が、実効は
    /// 尺の内側に収まり、描画パラメータは全時刻で有効域に収まること。後者が破れると
    /// NaN の不透明度・拡大率が描画層まで届く。
    ///
    /// S12: 役割ごとの `fontSize` 上限（`TextItemRole.maximumFontSize`）と、
    /// ステッカーの書記素クラスタ 1 個という制約も、`normalizedTextItems` /
    /// `validateTextItems` が見ている写像と同じものをここで検査する。
    func assertTextInvariants(_ state: TimelineState, context: String) {
        let totalDuration = state.mapping.totalDuration
        let effective = state.effectiveTextItems(totalDuration: totalDuration)
        for item in effective {
            XCTAssertGreaterThanOrEqual(item.compositionStart, -1e-9,
                                        "実効テキストが負の時刻から始まっている: \(context)")
            XCTAssertLessThanOrEqual(item.compositionEnd, totalDuration + 1e-9,
                                     "実効テキストが合成尺をはみ出している: \(context)")
            XCTAssertGreaterThanOrEqual(item.duration, TextItem.minimumDuration - 1e-9,
                                        "実効テキストが最小長を下回っている: \(context)")
            XCTAssertFalse(item.text.isEmpty, "空文字のテキストが残っている: \(context)")
            XCTAssertLessThanOrEqual(item.style.fontSize, item.role.maximumFontSize + 1e-9,
                                     "役割の fontSize 上限を超えている: role=\(item.role) \(context)")
            if item.role == .sticker {
                XCTAssertEqual(item.text.count, 1,
                               "ステッカーが書記素クラスタ 1 個に切られていない: \(context)")
            }

            // 表示区間の端と中央で描画パラメータが有効域に収まること。
            for fraction in [0.0, 0.25, 0.5, 0.99] {
                let time = item.compositionStart + item.duration * fraction
                guard let params = item.renderParameters(atComposition: time) else {
                    XCTFail("表示区間内なのに描画パラメータが nil: \(context)")
                    continue
                }
                XCTAssertTrue(params.opacity.isFinite && params.opacity >= 0 && params.opacity <= 1,
                              "不透明度が範囲外: \(context)")
                XCTAssertTrue(params.scale.isFinite && params.scale > 0,
                              "拡大率が不正: \(context)")
                XCTAssertTrue(params.offsetX.isFinite && params.offsetY.isFinite,
                              "オフセットが非有限: \(context)")
            }
        }
    }

    /// BGM（合成時刻アンカー）。
    ///
    /// 生データは合成尺の外にあってよい（温存の規則）が、
    /// **実効（`effectiveAudioItems`）は必ず尺の内側に収まる**。ここが破れると
    /// composition の `insertTimeRange` がタイムラインの外へ挿入しにいく。
    func assertAudioInvariants(_ state: TimelineState, context: String) {
        let totalDuration = state.mapping.totalDuration
        for item in state.effectiveAudioItems(totalDuration: totalDuration) {
            XCTAssertGreaterThanOrEqual(item.compositionStart, -1e-9,
                                        "実効 BGM が負の時刻から始まっている: \(context)")
            XCTAssertLessThanOrEqual(item.compositionEnd, totalDuration + 1e-9,
                                     "実効 BGM が合成尺をはみ出している: \(context)")
            XCTAssertGreaterThanOrEqual(item.sourceStart, -1e-9,
                                        "実効 BGM の素材時刻が負: \(context)")
            XCTAssertGreaterThanOrEqual(item.duration, AudioItem.minimumDuration - 1e-9,
                                        "実効 BGM が最小長を下回っている: \(context)")
        }
    }
}
