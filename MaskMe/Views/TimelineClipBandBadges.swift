import MosaicCore
import SwiftUI

/// クリップ帯の下端に重ねる表示（属性バッジと尺）。
///
/// 本体（`TimelineClipBandView`）から切り出してあるのは行数の都合だけではない。
/// ここはジェスチャにも下書きにも触らない**純粋な表示**で、`allowsHitTesting(false)`
/// を外さないかぎり操作へ影響しない。触ってよい範囲がファイル境界と一致する。
extension TimelineClipBandView {
    /// クリップ下端の表示。左に属性バッジ（写真・速度）、右に**尺**。
    ///
    /// 尺は「情報が読み取れない」の直球の答え。帯の長さは px でしか分からず、
    /// ズーム段が変わるたびに同じクリップが伸び縮みするので、数字が無いと
    /// 「このクリップは何秒か」を目盛りから引き算して読むしかなかった。
    ///
    /// **狭い帯では消す。** はみ出させると隣のクリップの上に文字だけが乗り、
    /// 区切りが読めなくなる（適用区間の `chipLabel` と同じ規則）。
    @ViewBuilder
    func badges(_ layout: TimelineClipLayout, width: Double, duration: Double) -> some View {
        let clip = model.timeline.clips.first { $0.id == layout.clipID }
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if width >= 40, model.timeline.sourceKind(of: layout.sourceID) == .photo {
                    badgeLabel("写真")
                }
                if width >= 40, let clip, abs(clip.rate - 1) > 1e-6 {
                    badgeLabel(String(format: "%.2gx", clip.rate))
                }
                Spacer(minLength: 0)
                if width >= 72 {
                    Text(Self.durationLabel(duration))
                        .font(TimelinePalette.labelFont)
                        .foregroundStyle(TimelinePalette.primaryText)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .allowsHitTesting(false)
    }

    /// 尺の表示。10 秒未満は 0.1 秒まで（短いクリップほど 1 秒の差が効くため）。
    static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0.0s" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(TimelinePalette.badgeFont)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    /// クリップ帯の下側に重ねる音声波形。
    ///
    /// **素材時刻で引く**（`previewClip` と同じ値を使う）。トリム下書き中も
    /// 帯のコマと波形が同じ素材位置を指し続ける。
    @ViewBuilder
    func waveformOverlay(_ layout: TimelineClipLayout,
                         band: (start: Double, end: Double),
                         width: Double) -> some View {
        if let clip = model.timeline.clips.first(where: { $0.id == layout.clipID }),
           let waveform = waveforms.waveform(for: layout.sourceID), !waveform.isEmpty {
            let preview = previewClip(clip, layout: layout)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TimelineWaveformView(
                    waveform: waveform, sourceStart: preview.sourceStart, rate: clip.rate,
                    width: CGFloat(max(width, 1)),
                    secondsPerPixel: geometry.duration(forWidth: 1))
            }
            .frame(width: max(width, 2), height: TimelineMetrics.clipHeight)
            .allowsHitTesting(false)
        }
    }

}
