import SwiftUI

/// 動画プレビュー専用コントロール：タイムライン + 再生行（時刻・情報・再検出・Undo/Redo）。
struct VideoControlsView: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        VStack(spacing: 0) {
            // マルチクリップタイムライン（スクラブ + クリップ編集。S9 で全体 In/Out
            // トリムはクリップ単位のトリムへ置き換わった）
            VideoTimelineView(model: model)
            transportRow
        }
        .background(.black.opacity(0.35))
    }

    /// 再生行。**時刻行と再生行を 1 段に統合**してある（約 20pt の回収）。
    ///
    /// 一般的な動画編集アプリと同じ `[▶] 現在 / 全体 … [再検出] [↩][↪]` の並び。
    /// 分けていた版は「時刻だけの 17pt の段」が丸ごと余白になっていた。
    ///
    /// **クリップ構成の要約（"3 クリップ / つなぎ 1"）はここから外した。** 1 段に
    /// 詰めた結果 iPhone の幅では出力解像度と両立せず、かつクリップ本数も継ぎ目も
    /// 真上のタイムライン（帯の数・継ぎ目ボタンの見た目）で直接読める情報だった。
    /// 出力解像度だけは画面のどこにも出ないので**常時表示のまま残す**
    /// （`VideoCompositionFactory.renderSize(for:)` の doc が要求している）。
    private var transportRow: some View {
        HStack(spacing: 6) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")

            Text(timeString(from: model.playbackPosition * model.videoDuration)
                 + " / " + timeString(from: model.videoDuration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let outputSizeText {
                Text(outputSizeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.hasDownscaledClips ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(outputSizeAccessibilityLabel)
            }

            Spacer(minLength: 4)

            Button {
                Task { await model.redetect(at: model.playbackPosition) }
            } label: {
                Label("再検出", systemImage: "face.dashed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            undoRedoButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
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
        HStack(spacing: 6) {
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
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.35)
    }

    private func timeString(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
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
