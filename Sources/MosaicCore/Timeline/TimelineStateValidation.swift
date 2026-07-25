import Foundation

/// `TimelineState` の不変条件チェック（デバッグ/テスト用）。
///
/// 本体（`TimelineState.swift`）が file_length の閾値に張り付いているため分冊してある。
extension TimelineState {
    /// 不変条件を満たしているかを返す。
    ///
    /// - transitions のキーが実在する**非末尾**クリップであること
    /// - 各トランジションが有限の `0 < duration <= min(両クリップ合成尺)/2`（浮動小数点誤差は許容）
    /// - applyRanges が全て有限の `sourceStart < sourceEnd`
    ///   （NaN は比較を素通りしてゲート判定を黙って全滅させるため、ここで明示的に弾く）
    /// - 各適用区間の `clipID` が実在クリップを指し、その `sourceID` が一致すること
    ///   （食い違うとその区間は永久に効かない。S11 の `clipID` アンカーの不変条件）
    /// - **写真クリップの適用区間は `sourceStart == 0`**（`MosaicApplyRange` 型 doc の不変条件）。
    ///   写真の素材時刻は `clampedSourceTime` が常に 0 へ丸めるため、`sourceStart > 0` の区間は
    ///   ゲートに**絶対にヒットしない**（帯だけ出てモザイクが消える I1 違反）。
    ///   区間生成器（`fullCoverRange` / 分割追従 / v1 移行）の写真扱いの退行はここで落ちる。
    /// - 素材メタ辞書のキーが `TimelineSource.id` と一致すること
    public func validate() -> Bool {
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }), index + 1 < clips.count,
                  spec.duration.isFinite, spec.duration > 0,
                  spec.duration <= min(clips[index].duration, clips[index + 1].duration) / 2 + 1e-9
            else { return false }
        }
        for range in applyRanges {
            guard range.sourceStart.isFinite, range.sourceEnd.isFinite,
                  range.sourceStart < range.sourceEnd else { return false }
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID else { return false }
            guard sourceKind(of: clip.sourceID) != .photo || range.sourceStart == 0 else { return false }
        }
        // 素材メタは「キー = TimelineSource.id」で引く辞書。食い違うと kind の参照が
        // 黙って .video フォールバックに落ちるため、不変条件として明示する。
        for (key, source) in sources where source.id != key {
            return false
        }
        return true
    }
}
