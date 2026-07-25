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

                // クリップ構成の要約（マルチクリップのときだけ）＋ 出力解像度
                HStack(spacing: 8) {
                    Text(clipSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.yellow)

                    if let outputSizeText {
                        Text(outputSizeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(model.hasDownscaledClips ? Color.orange : Color.secondary)
                            .accessibilityLabel(outputSizeAccessibilityLabel)
                    }
                }

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

                undoRedoButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.black.opacity(0.35))
    }

    /// タイムライン編集用の Undo / Redo。
    ///
    /// **`EditorView.adjustmentBar` の undo/redo とは別に置いている。**
    /// あちらは `model.activeTab != nil`（＝効果タブを開いている間）だけ現れるので、
    /// タブを閉じているのが既定のタイムライン画面からは押せない。さらにタブを開く操作
    /// 自体が `commitEdit()` を通るため、undo を押すためにタブを開くと
    /// 「直前の編集」がタブ操作そのものにすり替わる（背景 ON の取り消しになる）。
    /// 動画コントロールの中に常設することで、その経路を通らずに戻せるようにする。
    ///
    /// 写真モードの UI 契約が `adjustmentBar` に依存しているため、あちらは触っていない
    /// （動画コントロールは動画プレビューでしか出ないので二重表示にはならない）。
    private var undoRedoButtons: some View {
        HStack(spacing: 12) {
            Button { model.undo() } label: {
                undoRedoLabel("arrow.uturn.backward", enabled: model.canUndo)
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .accessibilityLabel("取り消す")

            Button { model.redo() } label: {
                undoRedoLabel("arrow.uturn.forward", enabled: model.canRedo)
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .accessibilityLabel("やり直す")
        }
    }

    /// 無効時は半透明にして「押せない」ことを見た目で示す（`.disabled` だけだと
    /// `.plain` スタイルの Image は色が変わらず、押せるように見えてしまう）。
    private func undoRedoLabel(_ systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.35)
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

    /// 出力解像度の表示（例: "1080×1920"）。縮小されるクリップがあるときは注意記号を付ける。
    ///
    /// **常時表示にしている**（「変わったときだけ警告」にしない）。出力解像度は先頭クリップが
    /// 決めるため並べ替えのたびに変わり得るが、並べ替えは日常操作なので都度の警告は
    /// 無視されるようになる。さらに「変化時だけ」だと、後から画面を見たユーザーが
    /// 現在の出力解像度を知る手段が無くなる。仕様は
    /// `VideoCompositionFactory.renderSize(for:)` の doc 参照。
    ///
    /// 値は `model.outputRenderSize`（`@Published`）から取る。`model.videoComposition` は
    /// `@Published` ではないうえ無変換構成では nil なので、直接読んではならない。
    private var outputSizeText: String? {
        guard let size = model.outputRenderSize else { return nil }
        let text = "\(Int(size.width))×\(Int(size.height))"
        // 出力枠より大きいクリップは縮小されて収まる（レターボックス）。
        // 配色（.orange）と併せた受動的な注意表示。
        return model.hasDownscaledClips ? text + " ⚠︎" : text
    }

    private var outputSizeAccessibilityLabel: String {
        guard let size = model.outputRenderSize else { return "" }
        let base = "出力解像度 \(Int(size.width)) × \(Int(size.height))"
        return model.hasDownscaledClips ? base + "、縮小されるクリップがあります" : base
    }
}
