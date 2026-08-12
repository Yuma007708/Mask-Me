import CoreGraphics
import Foundation
import MosaicCore

#if canImport(Metal)

/// 出力枠まわりの編集 API（画面比率・クロップ・余白の埋め方）。
///
/// **`MosaicEditorModel+Timeline.swift` が file_length（500 行）に達したので分けた。**
/// 中身は移設しただけで規則は変えていない。この 3 つを 1 ファイルにまとめたのは、
/// どれも「素材をどう置くか」ではなく「出力の枠をどうするか」を決める値であり、
/// **クリップ・適用区間・物体マスクの座標には一切触らない**という同じ約束を共有するため。
extension MosaicEditorModel {
    // MARK: - 出力の画面比率

    /// 出力（＝プレビューの合成フレーム）の画面比率を切り替える。
    ///
    /// `applyTimelineEdit` 経由なので、undo/redo（`EditSnapshot.timeline`）・下書き
    /// （`TimelineState` の Codable）・Composition 再構築（`replaceTimeline` が積む）に
    /// そのまま載る。**プレビューと書き出しが同時に切り替わるのはここが唯一の入口だから**
    /// で、`videoComposition` と顔座標の写像（`renderLayout`）は
    /// `apply(built:generation:)` で必ず組で差し替わる。
    ///
    /// 素材は切り取らない（レターボックス）。顔・矩形の座標は素材フレーム基準のまま
    /// 保存され、描画・書き出しの直前に `renderLayout` が同じ写像を掛ける
    /// （`TimelineAspectRatio` の doc 参照）。
    public func setOutputAspectRatio(_ ratio: TimelineAspectRatio) {
        // **比率を変えたらクロップを `.full` へリセットする**（親の裁定）。クロップ矩形は
        // 「画面比率適用後の枠」に対する正規化座標（`CropRect` 型 doc 参照）なので、
        // 比率を変えると枠の縦横比自体が変わり、既存のクロップ矩形が指す範囲の意味が
        // 変わってしまう。追従させる不可逆な再計算は持ち込まず、単純にリセットする。
        // 1 回の `applyTimelineEdit` にまとめることで undo が 1 操作に戻る。
        applyTimelineEdit { $0.settingAspectRatio(ratio).settingCrop(.full) }
    }

    /// 余白（レターボックス）の埋め方を設定する。
    ///
    /// **比率やクロップと違い、他の値をリセットしない。** 余白の見た目だけを決める値で、
    /// 素材の配置にも顔座標の写像にも影響しないため（`TimelineBackground` の doc 参照）。
    /// `applyTimelineEdit` 経由なので undo/redo と合成の作り直しは他の編集と同じに乗る。
    public func setLetterboxBackground(_ background: TimelineBackground) {
        applyTimelineEdit { $0.settingBackground(background) }
    }

    // MARK: - 出力枠のクロップ

    /// 出力枠（画面比率適用後の合成フレーム）のクロップを設定する。
    ///
    /// `applyTimelineEdit` 経由なので、undo/redo（`EditSnapshot.timeline` が
    /// `TimelineState` を丸ごと持つため追加登録は不要）・下書き（`TimelineState` の
    /// Codable）・Composition 再構築（`replaceTimeline` が積む）にそのまま載る。
    /// **クロップは合成の装着を強制する**（`VideoCompositionConditions.hasCrop`）ので、
    /// 装着なし構成の忠実度（`CompositionFidelityTests`）は `.full` を渡す限り壊れない。
    public func setCrop(_ crop: CropRect) {
        applyTimelineEdit { $0.settingCrop(crop) }
    }

    /// クロップを全面（クロップなし）へ戻す。
    public func resetCrop() {
        setCrop(.full)
    }
}

#endif
