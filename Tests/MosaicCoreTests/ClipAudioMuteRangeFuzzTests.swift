import XCTest
@testable import MosaicCore

/// クリップ内消音区間（`ClipAudioMuteRange`）の操作を、クリップ編集（分割・削除・並べ替え・
/// トリム）とランダムな順序で混ぜても `TimelineState.validate()` が一度も崩れないことを固定する。
///
/// `TimelineInvariantFuzzTests` に相乗りさせず**別ファイルにした**のは、あちらが
/// `file_length`（500 行）の上限ちょうどに張り付いており、これ以上operationを足すと
/// SwiftLint の warning になるため（既存テストは変更しない方針とも合う）。
/// 決定的な線形合同法を使う点・意図は同じ（失敗は必ず再現する）。
private struct MuteFuzzRandom {
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

final class ClipAudioMuteRangeFuzzTests: XCTestCase {
    private typealias EditOp = (name: String,
                                apply: (TimelineState, UUID?, inout MuteFuzzRandom) -> TimelineState)

    private func muteRangeOperations() -> [EditOp] {
        [
            ("addMute", { state, _, random in
                let total = max(0.1, state.mapping.totalDuration)
                let from = random.double(0...total)
                return state.addingClipAudioMuteRange(fromCompositionTime: from,
                                                       to: random.double(from...total))
            }),
            ("removeMute", { state, _, random in
                guard !state.clipAudioMuteRanges.isEmpty else { return state }
                let target = state.clipAudioMuteRanges[random.next(state.clipAudioMuteRanges.count)]
                return state.removingClipAudioMuteRange(id: target.id)
            }),
            ("moveMute", { state, _, random in
                guard !state.clipAudioMuteRanges.isEmpty else { return state }
                let target = state.clipAudioMuteRanges[random.next(state.clipAudioMuteRanges.count)]
                return state.movingClipAudioMuteRange(id: target.id, clipID: target.clipID,
                                                       byCompositionDelta: random.double(-6...6))
            }),
            ("replaceMute", { state, _, random in
                guard !state.clipAudioMuteRanges.isEmpty else { return state }
                let target = state.clipAudioMuteRanges[random.next(state.clipAudioMuteRanges.count)]
                let total = max(0.1, state.mapping.totalDuration)
                let from = random.double(0...total)
                let interval = CompositionInterval(start: from, end: random.double(from...total))
                return state.replacingClipAudioMuteRange(id: target.id, clipID: target.clipID,
                                                          compositionInterval: interval)
            }),
            ("clearMute", { state, _, _ in
                state.clearingClipAudioMuteRanges()
            })
        ]
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
            ("duplicate", { state, pick, _ in
                guard let pick else { return state }
                return state.duplicating(clipID: pick)
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
    func test_randomEditSequencesWithMuteRanges_neverBreakInvariants() {
        let videoSources = (0..<3).map { _ in UUID() }
        let photoSource = UUID()
        let operations = clipOperations(videoSources: videoSources, photoSource: photoSource)
            + muteRangeOperations()
        var operationCounts: [String: Int] = [:]

        for seed in UInt64(1)...8 {
            var random = MuteFuzzRandom(seed: seed)
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
                assertMuteRangesScopedToLiveClips(state, seed: seed, step: step, op: operation.name)
                if state.clips.isEmpty { break }
            }
        }
        print("[MuteFuzz] 実行した操作の内訳=\(operationCounts.sorted { $0.key < $1.key })")
    }

    /// `validate()` が見ていない側面: 消音区間は必ず生きているクリップだけを指すこと
    /// （孤児 `clipID` が残らないことの直接確認）。
    private func assertMuteRangesScopedToLiveClips(_ state: TimelineState, seed: UInt64, step: Int, op: String) {
        let clipIDs = Set(state.clips.map(\.id))
        for range in state.clipAudioMuteRanges {
            XCTAssertTrue(clipIDs.contains(range.clipID),
                          "消音区間が消えたクリップを指している: seed=\(seed) step=\(step) op=\(op)")
        }
    }
}
