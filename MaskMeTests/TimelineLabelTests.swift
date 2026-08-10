import XCTest
import MosaicCore
@testable import MaskMe

/// タイムラインが**数字で見せる**部分（目盛りのラベルとクリップの尺）の表示規則。
///
/// 見た目の中でもここだけはテストが要る。色や余白は間違っても「気に入らない」で
/// 済むが、数字が間違っていると**読んだ人が違う判断をする**（「このクリップは 3 秒」
/// と読んで切る位置を決める）。実際、ズーム最大では隣り合う目盛りが同じ文字を
/// 出しており、目盛りの半分が意味を持っていなかった。
final class TimelineLabelTests: XCTestCase {

    // MARK: - 目盛りのラベル

    /// 1 秒以上の間隔では従来どおり分:秒。
    func test_timeLabel_secondsAndAbove() {
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(0, interval: 1), "0:00")
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(61, interval: 1), "1:01")
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(600, interval: 10), "10:00")
    }

    /// **秒未満の間隔では小数第 1 位まで出す。**
    ///
    /// ズーム最大（`tickIntervalCandidates` の先頭 = 0.5s）で分:秒だけを出すと、
    /// 隣り合う目盛りが `0:00 0:00 0:01 0:01` と同じ文字になり、
    /// 目盛りが 2 本に 1 本しか位置を表さない。
    func test_timeLabel_subSecondIntervalDistinguishesNeighbours() {
        let interval = 0.5
        let labels = (0..<6).map {
            TimelineRulerTrackView.timeLabel(Double($0) * interval, interval: interval)
        }
        XCTAssertEqual(labels, ["0:00.0", "0:00.5", "0:01.0", "0:01.5", "0:02.0", "0:02.5"])
        XCTAssertEqual(Set(labels).count, labels.count, "隣り合う目盛りが同じ文字になっている")
    }

    /// 小数の繰り上がりで `0:09.10` のような表示にならないこと。
    func test_timeLabel_carriesFractionIntoSeconds() {
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(9.96, interval: 0.5), "0:10.0")
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(59.98, interval: 0.5), "1:00.0")
    }

    /// 異常値でも表示が壊れないこと（目盛りは総尺から機械的に作られる）。
    func test_timeLabel_rejectsNonFiniteAndNegative() {
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(-1, interval: 1), "0:00")
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(.nan, interval: 1), "0:00")
        XCTAssertEqual(TimelineRulerTrackView.timeLabel(.infinity, interval: 0.5), "0:00")
    }

    // MARK: - クリップの尺

    /// 10 秒未満は 0.1 秒まで。短いクリップほど 1 秒の差が効く。
    func test_durationLabel_shortClipsKeepTenths() {
        XCTAssertEqual(TimelineClipBandView.durationLabel(3.24), "3.2s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(0.4), "0.4s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(9.94), "9.9s")
    }

    /// 10 秒以上は秒、1 分以上は分:秒。
    func test_durationLabel_longClipsDropTenths() {
        XCTAssertEqual(TimelineClipBandView.durationLabel(12.6), "13s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(59.4), "59s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(90), "1:30")
        XCTAssertEqual(TimelineClipBandView.durationLabel(3661), "61:01")
    }

    /// 尺 0・異常値は「0.0s」。帯は 2pt まで潰れうるので 0 は実際に来る。
    func test_durationLabel_rejectsNonPositive() {
        XCTAssertEqual(TimelineClipBandView.durationLabel(0), "0.0s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(-3), "0.0s")
        XCTAssertEqual(TimelineClipBandView.durationLabel(.nan), "0.0s")
    }
}
