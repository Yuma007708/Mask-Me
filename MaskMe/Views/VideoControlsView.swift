import MosaicCore
import SwiftUI

/// 動画プレビュー専用コントロール：タイムライン + 再生行（時刻・情報・Undo/Redo）。
struct VideoControlsView: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        VStack(spacing: 0) {
            // 再生行は**タイムラインより上**。ツールバーが階層で入れ替わっても
            // ▶ と ↩↪ の位置が動かないようにする（動くと、粗さを調整しながら
            // 再生位置を確かめる操作のたびに指の行き先が変わる）。
            transportRow
            // マルチクリップタイムライン（スクラブ + クリップ編集）。
            // この下が `EditorDockView`（唯一のツールバー）で、画面の最下段になる。
            VideoTimelineView(model: model)
        }
        .background(.black.opacity(0.35))
    }

    /// 再生行。**時刻行と再生行を 1 段に統合**してある（約 20pt の回収）。
    ///
    /// 一般的な動画編集アプリと同じ `[▶] 現在 / 全体 … [↩][↪]` の並び。
    /// 分けていた版は「時刻だけの 17pt の段」が丸ごと余白になっていた。
    ///
    /// **「再検出」ボタンは撤去した。** 途中から現れた人は
    /// `MosaicEditorModel+PersonAdmission` が署名で見分けて自動で顔一覧へ足すので、
    /// 押す理由が無くなった。押した結果が「その素材の顔を作り直す」＝
    /// 選択の引き継ぎ次第でモザイクが外れうる操作でもあったので、経路ごと消してある。
    ///
    /// **クリップ構成の要約（"3 クリップ / つなぎ 1"）はここから外した。** 1 段に
    /// 詰めた結果 iPhone の幅では出力解像度と両立せず、かつクリップ本数も継ぎ目も
    /// 真上のタイムライン（帯の数・継ぎ目ボタンの見た目）で直接読める情報だった。
    /// 出力解像度だけは画面のどこにも出ないので**常時表示のまま残す**
    /// （`VideoCompositionFactory.renderSize(for:)` の doc が要求している）。
    private var transportRow: some View {
        HStack(spacing: 6) {
            // コマ送り（戻る）。一般的な編集アプリと同じ `◀| ▶ |▶` の並びで
            // 再生ボタンの左右に置く。活性判定・実行はどちらも `stepFrame(by:)` と
            // `canStepFrame(by:)` という同じ 1 組の関数から読む
            // （分割・音量ボタンが守っている「活性判定と実行を同じ規則にする」規約）。
            Button {
                stepFrame(by: -1)
            } label: {
                frameStepLabel("backward.frame.fill", enabled: canStepFrame(by: -1))
            }
            .buttonStyle(.plain)
            .disabled(!canStepFrame(by: -1))
            .accessibilityLabel("1コマ戻る")

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            // 読み込み中は押せないことを見た目でも示す。`togglePlayback` は
            // previewController が未構築のあいだ**黙って no-op** になる契約なので
            // （そちらの doc 参照）、押せる見た目のままだと「押しても何も起きない」に見える。
            // 編集画面は読み込み完了を待たずに開くため、この窓は実際に存在する。
            .disabled(model.isLoading)
            .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")

            // コマ送り（進む）。
            Button {
                stepFrame(by: 1)
            } label: {
                frameStepLabel("forward.frame.fill", enabled: canStepFrame(by: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canStepFrame(by: 1))
            .accessibilityLabel("1コマ進む")

            Text(timeString(from: model.playbackPosition * model.videoDuration)
                 + " / " + timeString(from: model.videoDuration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("editor.currentTime")
                // UI テストが払った量を 0.001 秒単位で突き合わせるための値。
                // 表示は秒単位なので、これが無いと小さなシークを検出できない
                // （`MaskMeUITests/TimelineGestureUITests.swift`）。
                .accessibilityValue(String(format: "%.3f",
                                           model.playbackPosition * model.videoDuration))

            Spacer(minLength: 4)

            if let outputSizeText {
                Text(outputSizeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.hasDownscaledClips ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(outputSizeAccessibilityLabel)
                    .accessibilityIdentifier("editor.outputSize")
                    // クロップの確定が書き出し経路（`outputRenderSize`）まで届いていることを
                    // UI テストが読める値で確かめるための番人（`EditorCropUITests`）。
                    // 表示文字列（`outputSizeText`）は "⚠︎" が付くことがあるため、
                    // 数値だけを別途 `accessibilityValue` として持たせる。
                    .accessibilityValue(model.outputRenderSize.map { "\(Int($0.width))x\(Int($0.height))" }
                                        ?? "")
            }

            Spacer(minLength: 4)

            undoRedoButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // 画面比率を選ぶ入口は**下部ツールバーの「比率」**へ移した
    // （`VideoTimelineView+Toolbar.aspectRatioItem`）。この再生行は
    // コマ戻し・再生・コマ送り・時刻・出力解像度・取り消し・やり直しで既に 8 要素あり、
    // iPhone の幅では潰れる。比率はクリップ操作ではなく作品全体の設定なので、
    // 「素材を足す」と同じ段にあるほうが意味の上でも自然。
    // 表示名（`aspectRatioTitle` / `aspectRatioShortTitle`）はシート側から使うので
    // ここに残してある。

    /// メニュー項目の表示名。
    static func aspectRatioTitle(_ ratio: TimelineAspectRatio) -> String {
        switch ratio {
        case .source: return "素材に合わせる"
        case .portrait9x16: return "9:16（縦）"
        case .square1x1: return "1:1（正方形）"
        case .landscape16x9: return "16:9（横）"
        }
    }

    /// ボタン上の短い表示名（1 段に詰めた再生行に収める）。
    static func aspectRatioShortTitle(_ ratio: TimelineAspectRatio) -> String {
        switch ratio {
        case .source: return "自動"
        case .portrait9x16: return "9:16"
        case .square1x1: return "1:1"
        case .landscape16x9: return "16:9"
        }
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

    // MARK: - コマ送り

    /// 無効時は半透明にする（`undoRedoLabel` と同じ理由）。
    private func frameStepLabel(_ systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 30, height: 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.35)
    }

    /// 1 コマの長さ（秒）。**`model.outputFrameDuration` を読む**
    /// （`videoComposition.frameDuration` を直接読んではならない、という
    /// `MosaicEditorModel.outputRenderSize` / `outputFrameDuration` の規約。
    /// `videoComposition` は `@Published` ではないので更新が届かず、無装着構成では
    /// nil になる。同じファイルの解像度表示 `model.outputRenderSize` も同じ規約で書いてある）。
    ///
    /// モデルが値を持たないのはクリップ未構築のときだけで、そのときは
    /// `VideoCompositionFactory.defaultFrameRate`（= 30fps、フレームレート不明時に
    /// プロジェクト全体で使っている既定値）へ落とす。
    private var frameStepDuration: Double {
        if let seconds = model.outputFrameDuration, seconds.isFinite, seconds > 0 {
            return seconds
        }
        return 1.0 / VideoCompositionFactory.defaultFrameRate
    }

    /// 指定方向へ 1 コマ動かせるか。**`stepFrame(by:)` と同じ式**で判定する
    /// （活性判定と実行を別の式にすると「押せるのに動かない／押せないが動く」が
    /// 作れてしまう。分割ボタンが守っている規則と同じ）。
    ///
    /// 読み込み中を弾くのは再生ボタン（`.disabled(model.isLoading)`）と同じ理由で、
    /// `seekTo` は previewController が未構築のあいだ効かないため押せる見た目にしない。
    private func canStepFrame(by direction: Int) -> Bool {
        guard !model.isLoading, model.videoDuration > 0 else { return false }
        let current = model.compositionTime(forPosition: model.playbackPosition)
        let target = current + Double(direction) * frameStepDuration
        let clamped = min(max(target, 0), model.videoDuration.nextDown)
        // 端では「動かした先が今と変わらない」ので押せない見た目にする。
        return abs(clamped - current) > frameStepDuration / 2
    }

    /// 1 コマ戻る（`direction < 0`）／進む（`direction > 0`）。
    /// **再生中に押したら先に一時停止する**（一般的な動画編集アプリと同じ挙動）。
    private func stepFrame(by direction: Int) {
        guard canStepFrame(by: direction) else { return }
        if model.isPlaying { model.togglePlayback() }
        let current = model.compositionTime(forPosition: model.playbackPosition)
        let target = current + Double(direction) * frameStepDuration
        let clamped = min(max(target, 0), model.videoDuration.nextDown)
        model.seekTo(position: clamped / model.videoDuration)
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
