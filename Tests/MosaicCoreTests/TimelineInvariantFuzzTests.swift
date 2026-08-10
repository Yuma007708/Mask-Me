import XCTest
@testable import MosaicCore

/// S11: 編集操作をランダムな順序で大量に積んでも `TimelineState` の不変条件が
/// 一度も崩れないことを固定する（決定的な擬似乱数なので失敗は必ず再現する）。
///
/// 個別の編集操作は既存テストが 1 手ずつ検証しているが、**手が混ざったとき**
/// （例: トランジションを設定してから rate を 10 倍にしてクリップを縮める、
/// 分割してから並べ替えて写真をトリムする）に条件が破れる経路は、
/// 組み合わせを実際に踏まないと出てこない。
/// 決定的な線形合同法（seed を変えれば別系列。失敗時は seed を報告する）。
///
/// **テストクラスの外に置いてある**のは、クラス本体の行数が SwiftLint の
/// `type_body_length` を超えたため。中身は乱数だけで、テストの意味には関わらない。
private struct Random {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(1, upperBound)))
    }
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double((state >> 11) % 1_000_000) / 1_000_000
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

final class TimelineInvariantFuzzTests: XCTestCase {
    /// `validate()` が見ていない写像側の不変条件も含めて総点検する。
    private func assertInvariants(_ state: TimelineState, step: Int, seed: UInt64, op: String) {
        let context = "seed=\(seed) step=\(step) op=\(op)"
        XCTAssertTrue(state.validate(), "validate() が false: \(context)")
        assertTransitionAndMappingInvariants(state, context: context)
        assertApplyRangeInvariants(state, context: context)
        assertAudioInvariants(state, context: context)
        assertTextInvariants(state, context: context)
    }

    /// 1 手ぶんの編集操作（名前つき）。switch を巨大化させず、操作の追加も
    /// この配列に 1 行足すだけで済むようにテーブルで持つ。
    private typealias EditOp = (name: String,
                                apply: (TimelineState, UUID?, inout Random) -> TimelineState)

    private func editOperations(videoSources: [UUID], photoSource: UUID,
                                audioSource: UUID) -> [EditOp] {
        clipOperations(videoSources: videoSources, photoSource: photoSource)
            + applyRangeOperations()
            + audioOperations(audioSource: audioSource)
            + textOperations()
    }

    /// テキスト（合成時刻アンカー・**重なってよい**）の操作。
    private func textOperations() -> [EditOp] {
        [
            ("addText", { state, _, random in
                let total = max(0.1, state.mapping.totalDuration)
                return state.addingTextItem("字幕\(random.next(100))",
                                            atCompositionTime: random.double(0...total),
                                            duration: random.double(0.05...8),
                                            center: NormalizedPoint(x: random.double(-0.5...1.5),
                                                                    y: random.double(-0.5...1.5)),
                                            animation: TextAnimation.allCases[
                                                random.next(TextAnimation.allCases.count)])
            }),
            ("removeText", { state, _, random in
                guard !state.textItems.isEmpty else { return state }
                return state.removingTextItem(
                    id: state.textItems[random.next(state.textItems.count)].id)
            }),
            ("moveText", { state, _, random in
                guard !state.textItems.isEmpty else { return state }
                let target = state.textItems[random.next(state.textItems.count)]
                return state.movingTextItem(id: target.id,
                                            byCompositionDelta: random.double(-8...8))
            }),
            ("trimText", { state, _, random in
                guard !state.textItems.isEmpty else { return state }
                let target = state.textItems[random.next(state.textItems.count)]
                return state.trimmingTextItem(id: target.id,
                                              edge: random.next(2) == 0 ? .start : .end,
                                              byCompositionDelta: random.double(-6...6))
            }),
            ("textStyle", { state, _, random in
                guard !state.textItems.isEmpty else { return state }
                let target = state.textItems[random.next(state.textItems.count)]
                var style = TextStyle()
                style.fontSize = random.double(-0.5...2)
                style.strokeWidth = random.double(-1...3)
                style.backgroundOpacity = random.double(-1...2)
                return state.settingTextStyle(id: target.id, style: style)
            })
        ]
    }

    /// モザイク適用区間（素材時刻アンカー）の操作。
    private func applyRangeOperations() -> [EditOp] {
        [
            ("applyRange", { state, _, random in
                let total = max(0.1, state.mapping.totalDuration)
                let from = random.double(0...total)
                return state.addingApplyRange(fromCompositionTime: from,
                                              to: random.double(from...total))
            }),
            ("moveApplyRange", { state, _, random in
                guard !state.applyRanges.isEmpty else { return state }
                let target = state.applyRanges[random.next(state.applyRanges.count)]
                return state.movingApplyRange(id: target.id, clipID: target.clipID,
                                              byCompositionDelta: random.double(-6...6))
            }),
            ("replaceApplyRange", { state, _, random in
                guard !state.applyRanges.isEmpty else { return state }
                let target = state.applyRanges[random.next(state.applyRanges.count)]
                let total = max(0.1, state.mapping.totalDuration)
                let from = random.double(0...total)
                let interval = CompositionInterval(start: from, end: random.double(from...total))
                return state.replacingApplyRange(id: target.id, clipID: target.clipID,
                                                 compositionInterval: interval)
            }),
            ("removeApplyRange", { state, _, random in
                guard !state.applyRanges.isEmpty else { return state }
                let target = state.applyRanges[random.next(state.applyRanges.count)]
                return state.removingApplyRange(id: target.id)
            })
        ]
    }

    /// BGM（合成時刻アンカー）の操作。
    private func audioOperations(audioSource: UUID) -> [EditOp] {
        [
            ("addAudio", { state, _, random in
                let total = max(0.1, state.mapping.totalDuration)
                return state.addingAudioItem(sourceID: audioSource,
                                             sourceDuration: random.double(0.05...12),
                                             atCompositionTime: random.double(0...total))
            }),
            ("removeAudio", { state, _, random in
                guard !state.audioItems.isEmpty else { return state }
                return state.removingAudioItem(
                    id: state.audioItems[random.next(state.audioItems.count)].id)
            }),
            ("moveAudio", { state, _, random in
                guard !state.audioItems.isEmpty else { return state }
                let target = state.audioItems[random.next(state.audioItems.count)]
                return state.movingAudioItem(id: target.id,
                                             byCompositionDelta: random.double(-8...8))
            }),
            ("trimAudio", { state, _, random in
                guard !state.audioItems.isEmpty else { return state }
                let target = state.audioItems[random.next(state.audioItems.count)]
                return state.trimmingAudioItem(
                    id: target.id, edge: random.next(2) == 0 ? .start : .end,
                    byCompositionDelta: random.double(-6...6),
                    sourceDuration: random.double(0.05...20))
            }),
            ("audioVolume", { state, _, random in
                guard !state.audioItems.isEmpty else { return state }
                let target = state.audioItems[random.next(state.audioItems.count)]
                return state.settingAudioVolume(id: target.id,
                                                volume: Float(random.double(-0.5...1.5)))
            }),
            // **フェードを混ぜること。** これが無いと、フューザが作る状態のフェードは
            // 常に 0 のままで、不変条件 I-A4（フェードは尺の半分以下）が**恒真として
            // 素通り**する＝新しい不変条件が空回りする。
            // I-A4 が本当に守りたいのは「フェードを上限まで上げてから、トリムや
            // 正規化で尺が縮む」という列で、それはまさにここでしか作れない。
            // 上限を超える値・負・非有限もわざと投げ込む（丸めが効いているかを見る）。
            ("audioFade", { state, _, random in
                guard !state.audioItems.isEmpty else { return state }
                let target = state.audioItems[random.next(state.audioItems.count)]
                let extremes: [Double] = [-1, 0, .infinity, .nan]
                let inSeed = random.next(8)
                let inValue = inSeed < 4 ? extremes[inSeed] : random.double(0...20)
                let outSeed = random.next(8)
                let outValue = outSeed < 4 ? extremes[outSeed] : random.double(0...20)
                return state.settingAudioFade(id: target.id,
                                              fadeIn: inValue, fadeOut: outValue)
            })
        ]
    }

    /// クリップ列そのものを変える操作。
    private func clipOperations(videoSources: [UUID], photoSource: UUID) -> [EditOp] {
        [
            ("split", { state, _, random in
                state.splitting(at: random.double(0...max(0.1, state.mapping.totalDuration)))
            }),
            ("remove", { state, pick, _ in
                guard state.clips.count > 1, let pick else { return state }
                return state.removing(clipID: pick)
            }),
            ("move", { state, pick, random in
                guard state.clips.count > 1, let pick else { return state }
                return state.moving(clipID: pick, toIndex: random.next(state.clips.count))
            }),
            ("trim", { state, pick, random in
                guard let pick, let clip = state.clips.first(where: { $0.id == pick })
                else { return state }
                let lower = random.double(clip.sourceStart...clip.sourceEnd)
                let upper = random.double(lower...(clip.sourceEnd + 2))
                return state.trimming(clipID: pick, sourceStart: lower, sourceEnd: upper)
            }),
            ("rate", { state, pick, random in
                guard let pick else { return state }
                return state.settingRate(clipID: pick, rate: random.double(0.1...10))
            }),
            ("volume", { state, pick, random in
                guard let pick else { return state }
                return state.settingVolume(clipID: pick, volume: Float(random.double(0...1)))
            }),
            ("transition", { state, pick, random in
                guard state.clips.count > 1, let pick else { return state }
                let kinds = TransitionKind.allCases
                return state.settingTransition(afterClipID: pick,
                                               kind: kinds[random.next(kinds.count)],
                                               duration: random.double(0.05...4))
            }),
            ("removeTransition", { state, pick, _ in
                guard let pick else { return state }
                return state.removingTransition(afterClipID: pick)
            }),
            ("duplicate", { state, pick, _ in
                guard let pick else { return state }
                return state.duplicating(clipID: pick)
            }),
            ("appendPhoto", { state, _, random in
                state.appending(
                    clip: TimelineClip(sourceID: photoSource, sourceStart: 0,
                                       sourceEnd: random.double(0.5...15)),
                    source: TimelineSource(id: photoSource, kind: .photo))
            }),
            ("appendVideo", { state, _, random in
                let source = videoSources[random.next(videoSources.count)]
                let start = random.double(0...4)
                return state.appending(
                    clip: TimelineClip(sourceID: source, sourceStart: start,
                                       sourceEnd: start + random.double(0.5...6)),
                    source: TimelineSource(id: source, kind: .video))
            })
        ]
    }

    /// ランダムな編集列 12 系列 × 400 手。全ステップで不変条件を検査する。
    func test_randomEditSequences_neverBreakInvariants() {
        let videoSources = (0..<3).map { _ in UUID() }
        let photoSource = UUID()
        let audioSource = UUID()
        let operations = editOperations(videoSources: videoSources, photoSource: photoSource,
                                        audioSource: audioSource)
        var operationCounts: [String: Int] = [:]

        for seed in UInt64(1)...12 {
            var random = Random(seed: seed)
            var sources: [UUID: TimelineSource] = [
                photoSource: TimelineSource(id: photoSource, kind: .photo),
                audioSource: TimelineSource(id: audioSource, kind: .audio)]
            for id in videoSources { sources[id] = TimelineSource(id: id, kind: .video) }
            var state = TimelineState(
                clips: [TimelineClip(sourceID: videoSources[0], sourceStart: 0, sourceEnd: 8)],
                sources: sources)
            state = state.replacingApplyRangesForTest(
                MosaicApplyGate.fullCoverRanges(for: state.clips,
                                                photoSourceIDs: state.photoSourceIDs))
            assertInvariants(state, step: -1, seed: seed, op: "initial")

            for step in 0..<400 {
                let clipIDs = state.clips.map(\.id)
                let pick = clipIDs.isEmpty ? nil : clipIDs[random.next(clipIDs.count)]
                let operation = operations[random.next(operations.count)]
                state = operation.apply(state, pick, &random)
                operationCounts[operation.name, default: 0] += 1
                assertInvariants(state, step: step, seed: seed, op: operation.name)
                if state.clips.isEmpty { break }
            }
        }
        print("[S11-FUZZ] 実行した操作の内訳=\(operationCounts.sorted { $0.key < $1.key })")
    }

    /// 下書きの往復（`Codable`）が編集途中のどの状態でも同値を保つこと。
    /// `schemaVersion: 2` の書き出し → 読み戻しで clipID アンカーが壊れないことの実測。
    func test_randomStates_surviveCodableRoundTrip() throws {
        var random = Random(seed: 99)
        let videoSource = UUID()
        let photoSource = UUID()
        var state = TimelineState(
            clips: [TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 6)],
            sources: [videoSource: TimelineSource(id: videoSource, kind: .video),
                      photoSource: TimelineSource(id: photoSource, kind: .photo)])
        state = state.replacingApplyRangesForTest(
            MosaicApplyGate.fullCoverRanges(for: state.clips, photoSourceIDs: state.photoSourceIDs))

        let audioSource = UUID()
        state.sources[audioSource] = TimelineSource(id: audioSource, kind: .audio)

        for step in 0..<120 {
            state = roundTripEdit(state, random: &random,
                                  photoSource: photoSource, audioSource: audioSource)
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
            XCTAssertEqual(decoded, state, "Codable 往復で状態が変わった step=\(step)")
            XCTAssertTrue(decoded.validate(), "往復後の状態が不変条件を破っている step=\(step)")
        }
    }

    /// 往復テスト 1 手ぶんの編集（`test_randomStates_surviveCodableRoundTrip` 専用）。
    private func roundTripEdit(_ state: TimelineState, random: inout Random,
                               photoSource: UUID, audioSource: UUID) -> TimelineState {
        switch random.next(7) {
        case 6:
            // BGM（v3 で追加）。合成時刻アンカーが往復で保たれること。
            return state.addingAudioItem(sourceID: audioSource,
                                         sourceDuration: random.double(0.2...8),
                                         atCompositionTime: random.double(0...20))
        case 5:
            // 区間の移動（本体ドラッグの確定）も往復に含める。素材時刻アンカーが
            // 移動後も正しく書き戻っていなければ、ここで往復が壊れる。
            guard let target = state.applyRanges.first else { return state }
            return state.movingApplyRange(id: target.id, clipID: target.clipID,
                                          byCompositionDelta: random.double(-3...3))
        case 0:
            return state.splitting(at: random.double(0...max(0.1, state.mapping.totalDuration)))
        case 1:
            return state.appending(
                clip: TimelineClip(sourceID: photoSource, sourceStart: 0,
                                   sourceEnd: random.double(0.5...15)),
                source: TimelineSource(id: photoSource, kind: .photo))
        case 2:
            guard let id = state.clips.last?.id else { return state }
            return state.settingRate(clipID: id, rate: random.double(0.1...10))
        case 3:
            guard state.clips.count > 1, let id = state.clips.first?.id else { return state }
            return state.settingTransition(afterClipID: id, kind: .crossfade,
                                           duration: random.double(0.1...2))
        default:
            let total = max(0.1, state.mapping.totalDuration)
            let from = random.double(0...total)
            return state.addingApplyRange(fromCompositionTime: from,
                                          to: random.double(from...total))
        }
    }
}

// MARK: - 不変条件の検査（クラス本体の行数を抑えるため extension へ）

private extension TimelineInvariantFuzzTests {
    /// トランジション・合成尺・クリップ配置。
    private func assertTransitionAndMappingInvariants(_ state: TimelineState, context: String) {
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
    private func assertApplyRangeInvariants(_ state: TimelineState, context: String) {
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

    /// テキスト（合成時刻アンカー）。
    ///
    /// **生データは合成尺の外にあってよい**（BGM と同じ温存の規則）が、実効は
    /// 尺の内側に収まり、描画パラメータは全時刻で有効域に収まること。後者が破れると
    /// NaN の不透明度・拡大率が描画層まで届く。
    private func assertTextInvariants(_ state: TimelineState, context: String) {
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
    private func assertAudioInvariants(_ state: TimelineState, context: String) {
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

extension TimelineState {
    /// テスト専用: 適用区間だけを差し替える（編集 API を経由せず初期状態を作る）。
    fileprivate func replacingApplyRangesForTest(_ ranges: [MosaicApplyRange]) -> TimelineState {
        TimelineState(clips: clips, transitions: transitions,
                      applyRanges: ranges, sources: sources)
    }
}
