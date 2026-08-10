import XCTest
@testable import MosaicCore

/// 声区間（`ClipDuckRange`）を種として仕込んだ状態に、クリップ編集（分割・削除・並べ替え・
/// トリム）をランダムな順序で混ぜても `TimelineState.validate()` が一度も崩れないことを固定する。
///
/// `ClipDuckRange` には（`ClipAudioMuteRange` と違い）対話編集 API が無い（`AudioDuckingDetector`
/// が生成するだけ）ため、この専用フューザは `state.clipDuckRanges` へ直接シードしてから
/// クリップ編集だけをランダムに掛ける。`ClipAudioMuteRangeFuzzTests` と同じ理由で別ファイルにした
/// （`TimelineInvariantFuzzTests` の file_length 上限）。
private struct DuckFuzzRandom {
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

final class ClipDuckRangeFuzzTests: XCTestCase {
    private typealias EditOp = (name: String,
                                apply: (TimelineState, UUID?, inout DuckFuzzRandom) -> TimelineState)

    /// 声区間の「シード」操作（テスト専用の直接代入。対話 API が無いための代替）。
    private func seedDuckRangeOperation() -> EditOp {
        ("seedDuckRange", { state, pick, random in
            guard let pick, let clip = state.clips.first(where: { $0.id == pick }) else { return state }
            let lower: Double
            let upper: Double
            if state.sourceKind(of: clip.sourceID) == .photo {
                // 写真クリップの声区間は `sourceStart == 0` でなければ不変条件違反
                // （`ClipDuckRange` 型 doc・`validateClipDuckRanges` 参照）。
                guard clip.sourceEnd > 0 else { return state }
                lower = 0
                upper = clip.sourceEnd
            } else {
                lower = random.double(clip.sourceStart...clip.sourceEnd)
                upper = random.double(lower...clip.sourceEnd)
            }
            guard upper - lower > 1e-6 else { return state }
            var result = state
            let candidate = ClipDuckRange(clipID: clip.id, sourceID: clip.sourceID,
                                          sourceStart: lower, sourceEnd: upper)
            result.clipDuckRanges = ClipDuckGate.merged(result.clipDuckRanges + [candidate])
            return result
        })
    }

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
            ("appendPhoto", { state, _, random in
                state.appending(
                    clip: TimelineClip(sourceID: photoSource, sourceStart: 0,
                                       sourceEnd: random.double(0.5...15)),
                    source: TimelineSource(id: photoSource, kind: .photo),
                    coveringWithApplyRange: false)
            }),
            ("appendVideo", { state, _, random in
                let source = videoSources[random.next(videoSources.count)]
                let start = random.double(0...4)
                return state.appending(
                    clip: TimelineClip(sourceID: source, sourceStart: start,
                                       sourceEnd: start + random.double(0.5...6)),
                    source: TimelineSource(id: source, kind: .video),
                    coveringWithApplyRange: false)
            })
        ]
    }

    /// ランダムな編集列 8 系列 × 250 手。全ステップで `validate()` を検査する。
    func test_randomEditSequencesWithDuckRanges_neverBreakInvariants() {
        let videoSources = (0..<3).map { _ in UUID() }
        let photoSource = UUID()
        let operations = clipOperations(videoSources: videoSources, photoSource: photoSource)
            + [seedDuckRangeOperation()]
        var operationCounts: [String: Int] = [:]

        for seed in UInt64(1)...8 {
            var random = DuckFuzzRandom(seed: seed)
            var sources: [UUID: TimelineSource] = [
                photoSource: TimelineSource(id: photoSource, kind: .photo)]
            for id in videoSources { sources[id] = TimelineSource(id: id, kind: .video) }
            var state = TimelineState(
                clips: [TimelineClip(sourceID: videoSources[0], sourceStart: 0, sourceEnd: 8)],
                sources: sources)
            XCTAssertTrue(state.validate(), "初期状態が不変条件を破っている seed=\(seed)")

            for step in 0..<250 {
                let clipIDs = state.clips.map(\.id)
                let pick = clipIDs.isEmpty ? nil : clipIDs[random.next(clipIDs.count)]
                let operation = operations[random.next(operations.count)]
                state = operation.apply(state, pick, &random)
                operationCounts[operation.name, default: 0] += 1
                XCTAssertTrue(state.validate(),
                              "validate() が false: seed=\(seed) step=\(step) op=\(operation.name)")
                assertDuckRangesScopedToLiveClips(state, seed: seed, step: step, op: operation.name)
                if state.clips.isEmpty { break }
            }
        }
        print("[DuckFuzz] 実行した操作の内訳=\(operationCounts.sorted { $0.key < $1.key })")
    }

    /// `validate()` が見ていない側面: 声区間は必ず生きているクリップだけを指すこと
    /// （孤児 `clipID` が残らないことの直接確認）。
    private func assertDuckRangesScopedToLiveClips(_ state: TimelineState, seed: UInt64, step: Int, op: String) {
        let clipIDs = Set(state.clips.map(\.id))
        for range in state.clipDuckRanges {
            XCTAssertTrue(clipIDs.contains(range.clipID),
                          "声区間が消えたクリップを指している: seed=\(seed) step=\(step) op=\(op)")
        }
    }
}
