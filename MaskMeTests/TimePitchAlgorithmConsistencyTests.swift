import AVFoundation
import MosaicCore
import XCTest
@testable import MaskMe

/// **プレビューと書き出しで音程の扱いが食い違わないことの番人。**
///
/// `audioTimePitchAlgorithm` は composition にも asset にも保存されない
/// 「再生／読み出し側のプロパティ」なので、経路ごとに個別の設定が要る。
/// 片方だけ変えると **プレビューでは自然なのに書き出すと声が高い**（あるいはその逆）
/// という、書き出すまで気づけない食い違いになる。
///
/// 既存の `MultiClipExportTests.test_S11_rateChangePreservesPitch_440HzStaysAt440Hz` は
/// **書き出し側しか見ていない**ので、プレビュー側だけを別の値に変える変更を捕まえられない。
/// ここはその隙間を埋める。
final class TimePitchAlgorithmConsistencyTests: XCTestCase {
    /// **速度の全域を覆い、音程を保つアルゴリズムを選んでいること。**
    ///
    /// 無指定だと既定がぶれる（**再生の既定は iOS 15 以降 `.timeDomain`、
    /// オフライン処理の既定は `.spectral`**）ため、明示を外すだけで両経路の
    /// アルゴリズムが食い違う。
    func test_音程アルゴリズムの選択() {
        XCTAssertNotEqual(AudioMixFactory.timePitchAlgorithm, .varispeed,
                          "音程が保たれないアルゴリズムを選んでいる（速度を上げると声が高くなる）")
        XCTAssertNotEqual(AudioMixFactory.timePitchAlgorithm, .lowQualityZeroLatency,
                          "倍率が離散値へスナップされるアルゴリズムを選んでいる"
                          + "（`TimelineClip.rateRange` は連続値なので、指定した速度にならない）")
    }

    /// **プレビューへ適用した値が、定数（＝書き出しと同じ値）と一致すること。**
    ///
    /// 適用は `AudioMixFactory.applyTimePitch(to:)` の 1 組だけを通す約束にしてある。
    /// プレビュー側で直値を書くように戻すと、両経路が別々に動き出す。
    func test_プレビューへの適用が書き出しと同じ値になる() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        AudioMixFactory.applyTimePitch(to: item)
        XCTAssertEqual(item.audioTimePitchAlgorithm, AudioMixFactory.timePitchAlgorithm,
                       "プレビューへ適用した音程アルゴリズムが定数と違う")
    }

    /// 速度の上限・下限（`TimelineClip.rateRange`）が、選んだアルゴリズムの
    /// 対応範囲（1/32〜32 倍）に収まっていること。
    ///
    /// **速度の範囲を広げるときに、ここが一緒に見直されるようにするための番人。**
    /// 範囲を 32 倍より広げると、音程の保持が保証されなくなる。
    func test_速度の範囲が音程アルゴリズムの対応範囲に収まる() {
        XCTAssertGreaterThanOrEqual(TimelineClip.rateRange.lowerBound, 1.0 / 32,
                                    "速度の下限が音程アルゴリズムの対応範囲を下回っている")
        XCTAssertLessThanOrEqual(TimelineClip.rateRange.upperBound, 32,
                                 "速度の上限が音程アルゴリズムの対応範囲を超えている")
    }
}
