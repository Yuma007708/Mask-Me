import XCTest
@testable import MosaicCore

final class AudioWaveformTests: XCTestCase {

    /// 1 秒ぶん（100 個）のピーク。0.5 秒地点だけ大きい。
    private func spikeWaveform() -> AudioWaveform {
        var peaks = [Float](repeating: 0.1, count: 100)
        peaks[50] = 1.0
        return AudioWaveform(peaks: peaks, sourceDuration: 1.0)
    }

    // MARK: - 読み出し

    func test_peakAtSourceTime_readsTheRightBucket() {
        let waveform = spikeWaveform()
        XCTAssertEqual(waveform.peak(atSourceTime: 0.50), 1.0)
        XCTAssertEqual(waveform.peak(atSourceTime: 0.505), 1.0)
        XCTAssertEqual(waveform.peak(atSourceTime: 0.49), 0.1)
    }

    /// 範囲外・異常値は 0（描画に NaN を流さない）。
    func test_peakAtSourceTime_outOfRangeIsSilent() {
        let waveform = spikeWaveform()
        XCTAssertEqual(waveform.peak(atSourceTime: -1), 0)
        XCTAssertEqual(waveform.peak(atSourceTime: 99), 0)
        XCTAssertEqual(waveform.peak(atSourceTime: .nan), 0)
        XCTAssertEqual(AudioWaveform.silent.peak(atSourceTime: 0), 0)
    }

    // MARK: - 棒への落とし込み

    /// 棒には区間の**最大値**を入れる。平均だと、縮小したときに
    /// 「音が入っているか」すら読めなくなる。
    func test_bars_takeMaximumNotAverage() {
        let waveform = spikeWaveform()
        // 1 秒を 2 本に落とす → 後半の棒がスパイクを拾う。
        let bars = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0, rate: 1,
                                            barCount: 2, secondsPerBar: 0.5)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(bars[1], 1.0, accuracy: 1e-6, "区間の最大値ではなく平均を取っている")
    }

    /// **速度変更に追従する。** 2 倍速なら同じ帯幅に 2 倍の素材時間が入るので、
    /// スパイクは帯の前半へ寄る。
    func test_bars_followClipRate() {
        let waveform = spikeWaveform()
        let normal = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0, rate: 1,
                                              barCount: 4, secondsPerBar: 0.25)
        let doubled = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0, rate: 2,
                                               barCount: 4, secondsPerBar: 0.25)
        XCTAssertEqual(normal.firstIndex(of: normal.max() ?? 0), 2, "等速: 0.5s は 3 本目")
        XCTAssertEqual(doubled.firstIndex(of: doubled.max() ?? 0), 1, "2 倍速: 0.5s は 2 本目へ寄る")
    }

    /// **トリムに追従する。** 帯の左端が指す素材時刻から読む。
    func test_bars_followSourceStart() {
        let waveform = spikeWaveform()
        let bars = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0.5, rate: 1,
                                            barCount: 2, secondsPerBar: 0.25)
        XCTAssertEqual(bars[0], 1.0, accuracy: 1e-6, "sourceStart=0.5 の直後にスパイクが来ない")
    }

    /// 拡大しすぎ（棒 1 本がピーク 1 個より短い）でも波形は消えない。
    /// 0 個読んで 0 を返す実装だと、拡大するほど無音に見える。
    func test_bars_survivesExtremeZoomIn() {
        let waveform = spikeWaveform()
        let bars = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0.5, rate: 1,
                                            barCount: 3, secondsPerBar: 0.001)
        XCTAssertEqual(bars.count, 3)
        XCTAssertTrue(bars.allSatisfy { $0 > 0 }, "拡大したら波形が消えた")
    }

    /// 素材の終端を越えて読もうとしても落ちない（トリムで伸ばした帯・写真クリップ）。
    func test_bars_toleratesReadingPastTheEnd() {
        let waveform = spikeWaveform()
        let bars = AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0.9, rate: 1,
                                            barCount: 4, secondsPerBar: 0.25)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars.last, 0, "素材の外なのに音が出ている")
    }

    /// 壊れた入力では棒を作らない（frame に NaN を渡さないための下流保護）。
    func test_bars_rejectsBrokenInput() {
        let waveform = spikeWaveform()
        XCTAssertTrue(AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0, rate: 0,
                                               barCount: 4, secondsPerBar: 0.25).isEmpty)
        XCTAssertTrue(AudioWaveformLayout.bars(waveform: waveform, sourceStart: .nan, rate: 1,
                                               barCount: 4, secondsPerBar: 0.25).isEmpty)
        XCTAssertTrue(AudioWaveformLayout.bars(waveform: waveform, sourceStart: 0, rate: 1,
                                               barCount: 0, secondsPerBar: 0.25).isEmpty)
        XCTAssertTrue(AudioWaveformLayout.bars(waveform: .silent, sourceStart: 0, rate: 1,
                                               barCount: 4, secondsPerBar: 0.25).isEmpty)
    }
}
