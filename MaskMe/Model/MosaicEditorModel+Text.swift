import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` のテキスト（E3）編集 API。
///
/// `MosaicEditorModel+Audio.swift` と同じ骨格: 編集はすべて `applyTimelineEdit` を通す
/// （undo/redo と下書きに載る、という同ファイルの規約はここでも変わらない）。
///
/// **BGM との違いは音源登録が要らないこと。** テキストは素材を持たない値型
/// （`TextItem`）なので `sources` への登録が無く、`MosaicEditorModel+Audio.swift` の
/// `registerAudioSource` に相当するものが存在しない。
extension MosaicEditorModel {
    // MARK: - テキスト（E3）

    /// テキストを 1 本追加する（UI からの入口）。
    ///
    /// プレイヘッド位置に既定の長さ（`defaultDuration`）で置く。空文字（空白だけを
    /// 含む場合も）は追加しない——コア層（`TimelineState.addingTextItem`）も弾くが、
    /// ここでも弾くのは「押したのに何も起きない」を入口で説明できるようにするため。
    public func addTextItem(_ text: String, atCompositionTime start: Double,
                            duration: Double = MosaicEditorModel.defaultTextDuration) {
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してからテキストを追加してください"
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyTimelineEdit { $0.addingTextItem(trimmed, atCompositionTime: start, duration: duration) }
    }

    /// 指定したテキストを取り除く。
    public func removeTextItem(id: UUID) {
        applyTimelineEdit { $0.removingTextItem(id: id) }
    }

    /// 文面を書き換える（空文字にはできない）。
    public func setText(id: UUID, text: String) {
        applyTimelineEdit { $0.settingText(id: id, text: text) }
    }

    /// 指定したテキストを合成時刻で `delta` 秒だけ平行移動する（隣とはぶつからない）。
    public func moveTextItem(id: UUID, byCompositionDelta delta: Double) {
        applyTimelineEdit { $0.movingTextItem(id: id, byCompositionDelta: delta) }
    }

    /// 指定したテキストの端を合成時刻で `delta` 秒だけ動かす（つまみの伸縮）。
    public func trimTextItem(id: UUID, edge: TimelineTrimEdge, byCompositionDelta delta: Double) {
        applyTimelineEdit { $0.trimmingTextItem(id: id, edge: edge, byCompositionDelta: delta) }
    }

    /// プレビュー上のドラッグ配置を確定する（E3-3b）。
    ///
    /// **ドラッグ中の下書きはここへ渡さない。** 呼び出し側（プレビューの
    /// オーバーレイ）は `@GestureState` で下書きを持ち、指を離した最終位置だけを
    /// ここへ渡す（`TimelineLayerTrackView` と同じ流儀。`applyTimelineEdit` は
    /// undo/redo に 1 エントリを積むため、ドラッグ中に連続で呼ぶと下書きの数だけ
    /// 履歴が汚れる）。
    public func setTextCenter(id: UUID, center: NormalizedPoint) {
        applyTimelineEdit { $0.settingTextCenter(id: id, center: center) }
    }

    /// 見た目（フォント・色・縁取り・背景帯）を差し替える（E3-3b）。
    ///
    /// **適用はスライダー確定時に呼ぶこと**（`TimelineVolumeSheet` / `TimelineSpeedSheet` と
    /// 同じ流儀）。連続適用すると 1 ドラッグで `applyTimelineEdit` の再構築が何十回も走る。
    public func setTextStyle(id: UUID, style: TextStyle) {
        applyTimelineEdit { $0.settingTextStyle(id: id, style: style) }
    }

    /// 出し方（アニメーション）を差し替える（E3-3b）。
    public func setTextAnimation(id: UUID, animation: TextAnimation) {
        applyTimelineEdit { $0.settingTextAnimation(id: id, animation: animation) }
    }

    /// 新規テキストの既定の長さ（秒）。プレイヘッド位置に置いたとき、指で伸縮しなくても
    /// 掴んで動かせる幅を確保する。
    public static let defaultTextDuration: Double = 3.0

    // MARK: - ステッカー（絵文字の重ね、S12）

    /// ステッカー（絵文字 1 個）を 1 本追加する（UI からの入口）。
    ///
    /// **活性条件・置く場所は `addTextItem` と同じ。** ツールバー・空段どちらの入口も
    /// 同じシート（`TimelineTextInputSheet`）を通るため、文字とステッカーで判定を
    /// 割らない。書記素クラスタ 1 個への切り詰めはコア層
    /// （`TimelineState.addingStickerItem` → `normalizedTextItems`）が行うので、
    /// ここでは前後の空白を落として空かどうかだけを見る。
    public func addStickerItem(_ emoji: String, atCompositionTime start: Double,
                               duration: Double = MosaicEditorModel.defaultTextDuration) {
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してからステッカーを追加してください"
            return
        }
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyTimelineEdit { $0.addingStickerItem(trimmed, atCompositionTime: start, duration: duration) }
    }
}

#endif
