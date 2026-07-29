import XCTest
@testable import MosaicCore

/// S9: 速度スライダーの対数スケールと、クリップ尺から決まる倍率上限。
///
/// `TimelineViewGeometryTests` から分けているのは `file_length` に収めるためで、
/// 対象は同じ `TimelineViewGeometry.swift`（`TimelineRateScale`）。
final class TimelineRateScaleTests: XCTestCase {
    private func clip(source: UUID = UUID(), start: Double, end: Double, rate: Double = 1) -> TimelineClip {
        TimelineClip(sourceID: source, sourceStart: start, sourceEnd: end, rate: rate)
    }
    // MARK: - 速度の上限（速度シートのクランプ根拠）

    /// 上限は「合成尺が最小尺を割らない」ところで切られること。
    func test_maximumRate_capsBySpanLength() {
        // 素材使用尺 0.5s → 0.5 / 0.1 = 5x が上限。
        XCTAssertEqual(TimelineRateScale.maximumRate(forClip: clip(start: 9.5, end: 10)),
                       5.0, accuracy: 1e-12)
        // 長いクリップでは rateRange の上限で止まる。
        XCTAssertEqual(TimelineRateScale.maximumRate(forClip: clip(start: 0, end: 60)),
                       TimelineClip.rateRange.upperBound, accuracy: 1e-12)
        // 上限倍率を掛けたクリップは、ちょうど最小尺を満たす（端トリムを拒否されない）。
        let short = clip(start: 9.5, end: 10)
        let capped = TimelineClip(sourceID: short.sourceID, sourceStart: short.sourceStart,
                                  sourceEnd: short.sourceEnd,
                                  rate: TimelineRateScale.maximumRate(forClip: short))
        XCTAssertGreaterThanOrEqual(capped.duration, TimelineEditOperations.minimumClipDuration)
        // 上限ちょうどのクリップは「これ以上短くできない」ので内向きは動かないが、
        // **逆方向へ飛ばない**（M-A1 の実害）。外向き（左へ）は動く。
        let inward = TimelineBandLayout.trimmedBounds(clip: capped, edge: .start,
                                                     deltaCompositionSeconds: 0.02,
                                                     sourceDuration: 10)
        XCTAssertEqual(inward.sourceStart, capped.sourceStart, accuracy: 1e-12,
                       "内向きトリムで使用範囲が逆方向へ動いた")
        let outward = TimelineBandLayout.trimmedBounds(clip: capped, edge: .start,
                                                      deltaCompositionSeconds: -0.02,
                                                      sourceDuration: 10)
        XCTAssertLessThan(outward.sourceStart, capped.sourceStart,
                          "上限倍率のクリップで外向きの端トリムが効いていない")
        // rateRange の下限を下回らない（極端に短いクリップでも Slider の range が潰れない）。
        XCTAssertGreaterThanOrEqual(TimelineRateScale.maximumRate(forClip: clip(start: 0, end: 0.001)),
                                    TimelineClip.rateRange.lowerBound)
    }
    // MARK: - 速度スライダーの対数スケール

    /// 0.5 がちょうど等速。両端が rateRange と一致する。
    func test_rateScale_endpointsAndMidpoint() {
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: 0),
                       TimelineClip.rateRange.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: 1),
                       TimelineClip.rateRange.upperBound, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: 0.5), 1.0, accuracy: 1e-12)
    }

    /// 対数スケール: スライダー上の等距離が倍率の等比に対応する。
    func test_rateScale_isLogarithmic() {
        let quarter = TimelineRateScale.rate(forSliderValue: 0.25)
        let threeQuarter = TimelineRateScale.rate(forSliderValue: 0.75)
        XCTAssertEqual(quarter, pow(10, -0.5), accuracy: 1e-12)
        XCTAssertEqual(threeQuarter, pow(10, 0.5), accuracy: 1e-12)
        XCTAssertEqual(quarter * threeQuarter, 1.0, accuracy: 1e-12, "0.5 を中心に対称")
    }

    func test_rateScale_roundTrips() {
        for rate in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 10.0] {
            let value = TimelineRateScale.sliderValue(forRate: rate)
            XCTAssertEqual(TimelineRateScale.rate(forSliderValue: value), rate, accuracy: 1e-9)
        }
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            let rate = TimelineRateScale.rate(forSliderValue: value)
            XCTAssertEqual(TimelineRateScale.sliderValue(forRate: rate), value, accuracy: 1e-9)
        }
    }

    func test_rateScale_clampsOutOfRangeAndNaN() {
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: -5),
                       TimelineClip.rateRange.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: 5),
                       TimelineClip.rateRange.upperBound, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.rate(forSliderValue: .nan), 1.0, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.sliderValue(forRate: 0.001), 0, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.sliderValue(forRate: 1_000), 1, accuracy: 1e-12)
        XCTAssertEqual(TimelineRateScale.sliderValue(forRate: .nan), 0.5, accuracy: 1e-12)
    }
}
