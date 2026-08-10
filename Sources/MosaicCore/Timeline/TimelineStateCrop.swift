import CoreGraphics
import Foundation

// 出力枠のクロップ編集。`TimelineState.swift` が file_length 上限に達したため分けてある
// （`TimelineStateAspectRatio` 等と同じ分け方）。

extension TimelineState {
    // MARK: - 出力枠のクロップ

    /// 出力枠のクロップを設定する。同じ値なら self を返す（他の編集操作と同じ契約なので、
    /// 呼び出し側は状態比較だけで「変わったか」を判定できる）。
    ///
    /// **クリップ・適用区間・物体マスク・テキストには一切触らない。** これらは素材フレーム
    /// （物体マスク）または出力枠固定（テキスト）基準で保存されており、出力枠の変化は
    /// `TimelineRenderLayout` / `RenderPlacement.make` が描画・書き出しの直前に吸収する。
    /// ここで座標を書き換えると、クロップを `.full` へ戻したときに元へ戻らない
    /// （不可逆な二重変換になる。`settingAspectRatio(_:)` の doc と同じ理由）。
    public func settingCrop(_ crop: CropRect) -> TimelineState {
        guard crop != self.crop else { return self }
        var result = self
        result.crop = crop
        return result
    }
}
