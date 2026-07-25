import MosaicCore
import SwiftUI

/// 動画プレビュー専用コントロール：タイムライン、時刻表示、再生ボタン、再検出ボタン。
struct VideoControlsView: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        VStack(spacing: 0) {
            // マルチクリップタイムライン（スクラブ + クリップ編集。S9 で全体 In/Out
            // トリムはクリップ単位のトリムへ置き換わった）
            VideoTimelineView(model: model)

            // 時刻表示（現在時刻 / クリップ構成 / 合成尺）
            HStack(spacing: 8) {
                Text(timeString(from: model.playbackPosition * model.videoDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Spacer()

                // クリップ構成の要約（マルチクリップのときだけ）
                Text(clipSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.yellow)

                Spacer()

                Text(timeString(from: model.videoDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            // 再生ボタン + 再検出ボタン
            HStack(spacing: 20) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 36)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    Task { await model.redetect(at: model.playbackPosition) }
                } label: {
                    Label("再検出", systemImage: "face.dashed")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.black.opacity(0.35))
    }

    private func timeString(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// クリップ構成の要約（例: "3 クリップ / つなぎ 1"）。単一クリップでは非表示。
    ///
    /// S9 で In/Out の全体トリム UI はクリップ単位のトリムに置き換わったため、
    /// ここも「トリム範囲」ではなくタイムラインの構成を出す。
    ///
    /// **つなぎの数は `timeline.transitions.count` ではなく合成結果から数える。**
    /// `transitions` には合成上効かないエントリ（クランプ結果 0）が載り得る
    /// （下書き v2 の直デコードは正規化を通らない）。その状態では表示が「つなぎ 1」なのに
    /// 継ぎ目ボタンは「未設定（+）」を出す、という食い違いになる。
    /// `jointLayouts` は `mapping.overlaps`（合成の単一情報源）から作られる。
    private var clipSummary: String {
        let clipCount = model.timeline.clips.count
        guard clipCount > 1 else { return "" }
        let transitionCount = TimelineBandLayout.jointLayouts(mapping: model.mapping)
            .filter { $0.kind != nil }.count
        return transitionCount > 0
            ? "\(clipCount) クリップ / つなぎ \(transitionCount)"
            : "\(clipCount) クリップ"
    }
}
