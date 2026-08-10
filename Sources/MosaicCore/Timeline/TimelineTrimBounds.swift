import Foundation

/// クリップ端トリムの確定域（素材時刻）を求める層。
///
/// `TimelineViewGeometry.swift` が file_length の閾値に張り付いているため分けてある。
/// 中身は `TimelineBandLayout` の一部で、**確定側（`MosaicEditorModel.trimClip`）と
/// 同じ規則**を 1 箇所に持つのが役目である。
extension TimelineBandLayout {
    /// 端ドラッグ後のクリップ使用範囲（素材時刻）。
    ///
    /// ドラッグ量は**合成時刻の差分**で受け取り、`rate` を掛けて素材時刻の差分に写す
    /// （2x のクリップでは帯を 1 秒縮めると素材は 2 秒縮む）。
    /// 結果は「最小合成尺（`TimelineEditOperations.minimumClipDuration`）を割らない」
    /// 範囲へクランプするため、ドラッグが行き過ぎても操作が無反応にならず端で止まる。
    ///
    /// **クランプ可能域が空のクリップでは端トリムを拒否して元の範囲を返す。**
    /// クランプの上下限は「最小合成尺を残す」制約から作るので、合成尺が既に最小尺を
    /// 割っているクリップ（`.start` 側）や素材末尾に張り付いたクリップ（`.end` 側）では
    /// 上限 < 下限になる。そのまま `min` / `max` を掛けると**ドラッグと逆方向へ端が飛ぶ**:
    /// 実測では 10x のクリップ（合成尺 0.05 秒）の左ハンドルを右へ 0.025 秒動かすと
    /// `sourceStart` が 9.5 → 9.0 へ落ち、前クリップと素材使用範囲が重複した。
    /// `MosaicEditorModel.trimClip` のクランプは `sourceEnd` 側だけなので素通しする。
    ///
    /// - Parameter sourceDuration: 素材の実尺（分かる場合）。`end` 側の上限に使う。
    public static func trimmedBounds(clip: TimelineClip,
                                     edge: TimelineTrimEdge,
                                     deltaCompositionSeconds delta: Double,
                                     sourceDuration: Double?) -> (sourceStart: Double, sourceEnd: Double) {
        let original = (sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
        guard delta.isFinite else { return original }
        let minimumSourceSpan = TimelineEditOperations.minimumClipDuration * clip.rate
        switch edge {
        case .start:
            let upperBound = clip.sourceEnd - minimumSourceSpan
            guard upperBound >= 0, upperBound >= clip.sourceStart else { return original }
            let raw = clip.sourceStart + delta * clip.rate
            return (min(max(raw, 0), upperBound), clip.sourceEnd)
        case .end:
            let lowerBound = clip.sourceStart + minimumSourceSpan
            var upperBound = Double.infinity
            if let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 {
                upperBound = sourceDuration
            }
            guard lowerBound <= upperBound else { return original }
            let raw = clip.sourceEnd + delta * clip.rate
            return (clip.sourceStart, min(max(raw, lowerBound), upperBound))
        }
    }

    /// 長押しドラッグ中のクリップを差し込むべき index。
    ///
    /// ドラッグ中クリップの帯の**中心**が移動後にどの帯へ入ったかで判定する
    /// （指の位置ではなく中心を使うことで、掴んだ場所によらず挙動が一定になる）。
    /// 端をはみ出した場合は先頭・末尾へ寄せる。`clipID` が無ければ nil。
    public static func reorderTargetIndex(layouts: [TimelineClipLayout],
                                          clipID: UUID,
                                          translationSeconds: Double) -> Int? {
        guard let current = layouts.first(where: { $0.clipID == clipID }),
              translationSeconds.isFinite, !layouts.isEmpty else { return nil }
        let center = (current.bandStart + current.bandEnd) / 2 + translationSeconds
        if let hit = layouts.firstIndex(where: { center >= $0.bandStart && center < $0.bandEnd }) {
            return layouts[hit].index
        }
        guard let first = layouts.first, let last = layouts.last else { return nil }
        return center < first.bandStart ? first.index : last.index
    }
}
