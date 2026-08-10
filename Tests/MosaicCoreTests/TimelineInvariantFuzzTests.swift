import XCTest
@testable import MosaicCore

/// S11: 編集操作をランダムな順序で大量に積んでも `TimelineState` の不変条件が
/// 一度も崩れないことを固定する（決定的な擬似乱数なので失敗は必ず再現する）。
///
/// 個別の編集操作は既存テストが 1 手ずつ検証しているが、**手が混ざったとき**
/// （例: トランジションを設定してから rate を 10 倍にしてクリップを縮める、
/// 分割してから並べ替えて写真をトリムする）に条件が破れる経路は、
/// 組み合わせを実際に踏まないと出てこない。
final class TimelineInvariantFuzzTests: XCTestCase {
    /// 決定的な線形合同法（seed を変えれば別系列。失敗時は seed を報告する）。
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

    /// `validate()` が見ていない写像側の不変条件も含めて総点検する。
    private func assertInvariants(_ state: TimelineState, step: Int, seed: UInt64, op: String) {
        let context = "seed=\(seed) step=\(step) op=\(op)"
        XCTAssertTrue(state.validate(), "validate() が false: \(context)")

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

    /// 1 手ぶんの編集操作（名前つき）。switch を巨大化させず、操作の追加も
    /// この配列に 1 行足すだけで済むようにテーブルで持つ。
    private typealias EditOp = (name: String,
                                apply: (TimelineState, UUID?, inout Random) -> TimelineState)

    private func editOperations(videoSources: [UUID], photoSource: UUID) -> [EditOp] {
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
        let operations = editOperations(videoSources: videoSources, photoSource: photoSource)
        var operationCounts: [String: Int] = [:]

        for seed in UInt64(1)...12 {
            var random = Random(seed: seed)
            var sources: [UUID: TimelineSource] = [photoSource: TimelineSource(id: photoSource,
                                                                               kind: .photo)]
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

        for step in 0..<120 {
            switch random.next(6) {
            case 5:
                // 区間の移動（本体ドラッグの確定）も往復に含める。素材時刻アンカーが
                // 移動後も正しく書き戻っていなければ、ここで往復が壊れる。
                if let target = state.applyRanges.first {
                    state = state.movingApplyRange(id: target.id, clipID: target.clipID,
                                                   byCompositionDelta: random.double(-3...3))
                }
            case 0: state = state.splitting(at: random.double(0...max(0.1, state.mapping.totalDuration)))
            case 1:
                state = state.appending(
                    clip: TimelineClip(sourceID: photoSource, sourceStart: 0,
                                       sourceEnd: random.double(0.5...15)),
                    source: TimelineSource(id: photoSource, kind: .photo))
            case 2:
                if let id = state.clips.last?.id {
                    state = state.settingRate(clipID: id, rate: random.double(0.1...10))
                }
            case 3:
                if state.clips.count > 1, let id = state.clips.first?.id {
                    state = state.settingTransition(afterClipID: id, kind: .crossfade,
                                                    duration: random.double(0.1...2))
                }
            default:
                let total = max(0.1, state.mapping.totalDuration)
                let from = random.double(0...total)
                state = state.addingApplyRange(fromCompositionTime: from,
                                               to: random.double(from...total))
            }
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(TimelineState.self, from: data)
            XCTAssertEqual(decoded, state, "Codable 往復で状態が変わった step=\(step)")
            XCTAssertTrue(decoded.validate(), "往復後の状態が不変条件を破っている step=\(step)")
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
