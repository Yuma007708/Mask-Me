import SwiftUI

/// 動画プレビュー専用コントロール：シークバー、再生ボタン、再検出ボタン。
struct VideoControlsView: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        VStack(spacing: 0) {
            // シークバー
            HStack(spacing: 8) {
                Text(timeString(from: model.playbackPosition * model.videoDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Slider(value: Binding(
                    get: { model.playbackPosition },
                    set: { model.seekTo(position: $0) }
                ), in: 0...1)
                .tint(.white)

                Text(timeString(from: model.videoDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
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
}
