import XCTest
@testable import MosaicCore

/// `AudioDuckingDetector`（波形からの声区間検出）。
///
/// **固定の絶対しきい値を使わないこと**が前提（`AudioWaveform` 型 doc「別素材どうしの高さを
/// 比べても意味はない」）。各テストは 1 クリップの窓の中の相対分布だけで検証する。
final class AudioDuckingDetectorTests: XCTestCase {
    /// `waveform(totalDuration:spans:)` に渡す 1 スパン（`[start, end)` を `value` で埋める）。
    /// タプルではなく struct にしているのは `large_tuple`（swiftlint）を避けるため。
    private struct WaveformSpan {
        let start: Double
        let end: Double
        let value: Float

        init(_ start: Double, _ end: Double, _ value: Float) {
            self.start = start
            self.end = end
            self.value = value
        }
    }

    /// `[start, end)` を `value` で、それ以外を 0 で埋めたピーク列を作る（`totalDuration` 秒ぶん）。
    private func waveform(totalDuration: Double, spans: [WaveformSpan]) -> AudioWaveform {
        let count = Int((totalDuration * AudioWaveform.peaksPerSecond).rounded())
        var peaks = [Float](repeating: 0, count: count)
        for span in spans {
            let startIndex = max(0, Int((span.start * AudioWaveform.peaksPerSecond).rounded()))
            let endIndex = min(count, Int((span.end * AudioWaveform.peaksPerSecond).rounded()))
            guard startIndex < endIndex else { continue }
            for index in startIndex..<endIndex { peaks[index] = span.value }
        }
        return AudioWaveform(peaks: peaks, sourceDuration: totalDuration)
    }

    /// 無音 → 有音 → 無音 で 1 本の区間が作られ、境界が ±20ms 以内であること。
    func test_voiceRanges_silenceVoiceSilence_producesOneRangeWithAccurateBoundaries() {
        let form = waveform(totalDuration: 3, spans: [WaveformSpan(1.0, 2.0, 0.8)])
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)

        let ranges = AudioDuckingDetector.voiceRanges(waveform: form, clip: clip)

        XCTAssertEqual(ranges.count, 1, "無音→有音→無音は 1 本の声区間になるべき")
        guard let range = ranges.first else { return }
        XCTAssertEqual(range.sourceStart, 1.0, accuracy: 0.02, "開始境界が ±20ms を超えている")
        XCTAssertEqual(range.sourceEnd, 2.0, accuracy: 0.02, "終了境界が ±20ms を超えている")
    }

    /// 閾値付近を細かく振動する波形でも 1 本の区間に収まる（チャタらない）。
    func test_voiceRanges_oscillatingNearThreshold_doesNotChatter() {
        // 0.05s 周期で 1.0 / 0.1 を往復（1.0 が open を大きく超え、0.1 が close を下回るよう
        // 半々の duty 比にして p90 を高く保つ）。低い側の連続長は hold(0.25s) より十分短い。
        var spans: [WaveformSpan] = []
        var t = 0.0
        var high = true
        while t < 2.0 {
            spans.append(WaveformSpan(t, t + 0.05, high ? 1.0 : 0.1))
            t += 0.05
            high.toggle()
        }
        let form = waveform(totalDuration: 3, spans: spans)
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)

        let ranges = AudioDuckingDetector.voiceRanges(waveform: form, clip: clip)

        XCTAssertEqual(ranges.count, 1, "閾値付近の振動が複数区間にチャタってはいけない")
    }

    /// `minimumVoiceDuration` 未満の短いスパイクは区間を作らない。
    func test_voiceRanges_shortSpikeBelowMinimumDuration_createsNoRange() {
        let form = waveform(totalDuration: 2, spans: [WaveformSpan(1.0, 1.1, 0.9)])
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 2)

        let ranges = AudioDuckingDetector.voiceRanges(waveform: form, clip: clip)

        XCTAssertTrue(ranges.isEmpty, "0.1s のスパイクは minimumVoiceDuration(0.20s) 未満なので区間を作らない")
    }

    /// `mergeGap` 以下の谷を挟む 2 つの有音区間は 1 本へ統合される。
    func test_voiceRanges_gapWithinMergeGap_mergesIntoOneRange() {
        // A: [1.00,1.30) 高い、谷: [1.30,1.60)（0.30s。hold より長く mergeGap 以下）、
        // B: [1.60,1.90) 高い。
        let form = waveform(totalDuration: 3,
                           spans: [WaveformSpan(1.00, 1.30, 0.9), WaveformSpan(1.60, 1.90, 0.9)])
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)

        let ranges = AudioDuckingDetector.voiceRanges(waveform: form, clip: clip)

        XCTAssertEqual(ranges.count, 1, "mergeGap(0.35s) 以下の谷は 1 本へ統合されるべき")
        guard let range = ranges.first else { return }
        XCTAssertEqual(range.sourceStart, 1.00, accuracy: 0.05)
        XCTAssertEqual(range.sourceEnd, 1.90, accuracy: 0.05)
    }

    /// 声区間は `clipID` / `sourceID` を持ち、クリップの使用範囲の外へは出ない。
    func test_voiceRanges_scopedToClipSourceRange() {
        let form = waveform(totalDuration: 5, spans: [WaveformSpan(0.5, 4.5, 0.8)])
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 1, sourceEnd: 3)

        let ranges = AudioDuckingDetector.voiceRanges(waveform: form, clip: clip)

        for range in ranges {
            XCTAssertEqual(range.clipID, clip.id)
            XCTAssertEqual(range.sourceID, clip.sourceID)
            XCTAssertGreaterThanOrEqual(range.sourceStart, clip.sourceStart - 1e-9)
            XCTAssertLessThanOrEqual(range.sourceEnd, clip.sourceEnd + 1e-9)
        }
    }

    /// 波形が空なら常に区間なし。
    func test_voiceRanges_emptyWaveform_returnsNoRanges() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)
        XCTAssertTrue(AudioDuckingDetector.voiceRanges(waveform: .silent, clip: clip).isEmpty)
    }
}
