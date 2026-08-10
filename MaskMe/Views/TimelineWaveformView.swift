import MosaicCore
import SwiftUI

/// クリップ帯の**下側**に重ねる波形。
///
/// 専用の段を作らず帯に重ねているのは、段を増やすとそのぶんプレビューが縮むため
/// （`TimelineMetrics.stackHeight` の doc と同じ理由）。波形はサムネイルの
/// 「どこで何が起きているか」を補う情報なので、同じ帯の中にある方が読みやすくもある。
///
/// **`allowsHitTesting(false)` を外さないこと。** 帯のタップ・トリム・長押し並べ替えは
/// すべて下のレイヤーが受ける。波形が指を吸うと帯が選べなくなる。
struct TimelineWaveformView: View {
    let waveform: AudioWaveform
    /// 帯の左端が指す素材時刻。
    let sourceStart: Double
    /// クリップの速度（2 倍なら同じ幅に 2 倍の素材時間が入る）。
    let rate: Double
    /// 帯の幅（px）。
    let width: CGFloat
    /// 1px あたりの合成秒数（`1 / pixelsPerSecond`）。
    let secondsPerPixel: Double

    /// 波形を描く高さ。帯（60pt）の下 1/3 弱。
    static let height: CGFloat = 16
    /// 棒 1 本ぶんの幅（間隔込み）。細くすると重くなるだけで見え方は変わらない。
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1

    private var bars: [Float] {
        let pitch = Double(Self.barWidth + Self.barSpacing)
        let count = Int((Double(width) / pitch).rounded(.down))
        return AudioWaveformLayout.bars(
            waveform: waveform, sourceStart: sourceStart, rate: rate,
            barCount: count, secondsPerBar: secondsPerPixel * pitch)
    }

    var body: some View {
        // **Canvas で描く。** 棒は数百本になるので、SwiftUI の View を 1 本ずつ
        // 積むと帯を掴んで動かすたびにレイアウトが破綻するほど重くなる。
        Canvas { context, size in
            let values = bars
            guard !values.isEmpty else { return }
            let pitch = Self.barWidth + Self.barSpacing
            for (index, value) in values.enumerated() {
                let magnitude = CGFloat(max(0, min(1, value)))
                // 無音でも 1px は描く（「解析済みで無音」と「まだ解析していない」を
                // 見分けられるようにする。後者は何も描かれない）。
                let barHeight = max(1, magnitude * size.height)
                let rect = CGRect(x: CGFloat(index) * pitch,
                                  y: size.height - barHeight,
                                  width: Self.barWidth, height: barHeight)
                context.fill(Path(rect), with: .color(TimelinePalette.waveform))
            }
        }
        .frame(width: max(width, 1), height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
