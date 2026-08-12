import CoreGraphics
import Foundation

// 出力の画面比率の編集。`TimelineState.swift` が file_length 上限に達したため分けてある
// （`TimelineStateApplyRangeEditing` 等と同じ分け方）。

extension TimelineState {
    // MARK: - 出力の画面比率

    /// 出力の画面比率を設定する。同じ値なら self を返す（他の編集操作と同じ契約なので、
    /// 呼び出し側は状態比較だけで「変わったか」を判定できる）。
    ///
    /// **クリップ・適用区間・物体マスクには一切触らない。** これらは素材フレーム基準で
    /// 保存されており、出力枠の変化は `TimelineRenderLayout` が描画・書き出しの直前に
    /// 吸収する。ここで座標を書き換えると、比率を戻したときに元へ戻らない（不可逆な
    /// 二重変換になる）。
    public func settingAspectRatio(_ ratio: TimelineAspectRatio) -> TimelineState {
        guard ratio != aspectRatio else { return self }
        var result = self
        result.aspectRatio = ratio
        return result
    }
}

extension TimelineState {
    // MARK: - レターボックスの埋め方

    /// 余白（レターボックス）の埋め方を設定する。同じ値なら self を返す
    /// （`settingAspectRatio` と同じ契約）。
    ///
    /// **配置にも座標の写像にも触らない。** これは余白の見た目だけを決める値で、
    /// 素材の置き場所（`TimelineRenderLayout` / `RenderPlacement`）とは無関係である。
    /// そのため比率やクロップと違い、他の値をリセットする必要が無い。
    public func settingBackground(_ background: TimelineBackground) -> TimelineState {
        let normalized = background.clamped
        guard normalized != self.background else { return self }
        var result = self
        result.background = normalized
        return result
    }
}
