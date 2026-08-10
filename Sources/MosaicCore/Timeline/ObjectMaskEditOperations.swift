import CoreGraphics
import Foundation

/// `ObjectMask` をクリップ編集に追従させる純関数群。
///
/// `MosaicApplyGate.ranges(splittingClip:...)` と同じ役割・同じ引数の並びにしてある
/// （追従の規則が 2 系統に割れると、片方だけ直して片方が腐る）。
///
/// **追従が要るのは分割と削除だけ。** 並べ替え・トリム・速度変更・音量変更・追加は
/// `clipID` も素材時刻も変えないので、素材時刻アンカーがそのまま自動追従する
/// （`TimelineState.moving` の doc と同じ理屈）。
public enum ObjectMaskEditOperations {
    // MARK: - 分割

    /// クリップ分割にマスクを追従させる。
    ///
    /// 分割点の素材時刻 `m`（= 後半クリップの `sourceStart`）を境に、`frontClip.id` に
    /// 属するマスクを前後 2 個へ複製する:
    ///
    /// - front: `m` 未満のキーフレーム + **`m` での補間矩形**（id・アンカー据え置き）
    /// - back: **`m` での補間矩形** + `m` 超のキーフレーム（**新しい `ObjectMask.id`**）
    ///
    /// ## `m` の矩形を必ず両側へ入れる理由
    ///
    /// 入れないと、境界側のキーフレームを失った方が clamp に落ちて位置が飛ぶ。
    /// 実測で正規化 0.25（画面幅の 25%）ずれた。**`m` ちょうどにキーフレームがある
    /// 場合も同じで、片側にしか渡さないともう片方が clamp する**。この実装は
    /// 「`m` 未満」「`m` 超」で分けて `m` を両側に必ず足すので、両方が同じ形で片づく。
    ///
    /// ## back に新しい id を振る理由
    ///
    /// 同じ id のマスクが 2 個並ぶと、SwiftUI の `ForEach` と
    /// `firstIndex(where: { $0.id == ... })` が片方にしか当たらず、
    /// 「消したのに片方が残る」「動かしたのに別の方が動く」になる。
    ///
    /// ## 分割前後の一致について
    ///
    /// 分割点は 1/600 秒グリッドへ量子化してから使う（`ObjectMask` のキーフレーム時刻が
    /// グリッド上にしか置けないため）。よって:
    ///
    /// - `rect(atSourceTime:)` は分割前後で **bit 一致しない**（線分の再パラメータ化は
    ///   数学的に同値でも浮動小数点では非同値。実測で評価点の約 9% が不一致）。
    ///   一致するのは**絶対差 3.4e-16 以内**という意味で——正規化座標なので
    ///   1080px 換算 4e-13 ピクセル。ランダム 2000 マスク × 180 万評価点での最大値である。
    ///   相対（ulp 比）で見ないのは、補間結果が 0 付近で桁落ちしたときだけ 136 ulp まで
    ///   跳ね上がり、実害の無い差を過大に見せるため
    /// - `m` が グリッド外のとき、`[m, 量子化した m]` の**幅 1/600 秒未満の窓**だけは
    ///   分割前の値と食い違う（front がその窓で clamp するため）。60fps の 1 フレーム
    ///   (16.7ms) より短く、ずれ幅もその間の移動量に比例するので実害はない
    ///
    /// - Parameter isPhoto: 写真素材のクリップなら true。写真の素材時刻は
    ///   `TimelineState.clampedSourceTime` が必ず 0 へ丸めるので、`m` で割ると後半の
    ///   キーフレームが**絶対に引かれなくなる**。前後どちらにも「時刻 0 の 1 個」を配る。
    ///   **既定値は置かない**（渡し忘れが黙って通ると、帯は出ているのにモザイクが消える）。
    public static func masks(splittingClip frontClip: TimelineClip,
                             into backClip: TimelineClip,
                             atSourceTime m: Double,
                             isPhoto: Bool,
                             existing: [ObjectMask]) -> [ObjectMask] {
        guard let split = ObjectMask.quantize(m) else { return existing }
        return existing.flatMap { mask -> [ObjectMask] in
            guard mask.anchor.clipID == frontClip.id else { return [mask] }
            if isPhoto {
                return photoSplit(mask: mask, front: frontClip, back: backClip)
            }
            return videoSplit(mask: mask, front: frontClip, back: backClip, at: split)
        }
    }

    private static func videoSplit(mask: ObjectMask, front: TimelineClip, back: TimelineClip,
                                   at split: Double) -> [ObjectMask] {
        let boundary = ObjectMask.Keyframe(sourceTime: split, rect: mask.rect(atSourceTime: split))
        let frontFrames = mask.keyframes.filter { $0.sourceTime < split } + [boundary]
        let backFrames = [ObjectMask.Keyframe(sourceTime: split, rect: boundary.rect)]
            + mask.keyframes.filter { $0.sourceTime > split }
        // `isRegionPlaceholder` は分割の前後どちらにも引き継ぐ（第2段が矩形サーチ由来の
        // 暫定マスクを見分けるためのフラグなので、分割で片方だけ落とすと見失う）。
        let frontMask = ObjectMask(id: mask.id,
                                   anchor: .clip(clipID: front.id, sourceID: front.sourceID),
                                   keyframes: frontFrames,
                                   isRegionPlaceholder: mask.isRegionPlaceholder)
        let backMask = ObjectMask(anchor: .clip(clipID: back.id, sourceID: back.sourceID),
                                  keyframes: backFrames,
                                  isRegionPlaceholder: mask.isRegionPlaceholder)
        // 生成に失敗する入力は無い（境界キーフレームを必ず 1 個含むため）が、
        // 万一 nil になったら元のマスクを落とさず残す（隠し忘れより隠しすぎへ倒す）。
        guard let frontMask, let backMask else { return [mask] }
        return [frontMask, backMask]
    }

    /// 写真クリップの分割: 前後どちらにも「時刻 0 のキーフレーム 1 個」を配る。
    /// 元 id は前半が継承する（UI の選択が飛ばない）。
    private static func photoSplit(mask: ObjectMask, front: TimelineClip,
                                   back: TimelineClip) -> [ObjectMask] {
        let rect = mask.rect(atSourceTime: 0)
        let frontMask = ObjectMask.single(id: mask.id,
                                          anchor: .clip(clipID: front.id, sourceID: front.sourceID),
                                          rect: rect, isRegionPlaceholder: mask.isRegionPlaceholder)
        let backMask = ObjectMask.single(anchor: .clip(clipID: back.id, sourceID: back.sourceID),
                                         rect: rect, isRegionPlaceholder: mask.isRegionPlaceholder)
        guard let frontMask, let backMask else { return [mask] }
        return [frontMask, backMask]
    }

    // MARK: - 削除

    /// クリップ削除にマスクを追従させる（**そのクリップのマスクは消す**）。
    ///
    /// `clipID` は復活しないので、温存すると画面のどこにも出ないのに消せない永久のゴミになる
    /// （`MosaicApplyGate.ranges(removingClipID:from:)` と同じ判断）。
    /// undo は `EditSnapshot` が状態ごと戻すため復元性は落ちない。
    public static func masks(removingClipID clipID: UUID, from masks: [ObjectMask]) -> [ObjectMask] {
        masks.filter { $0.anchor.clipID != clipID }
    }

    // MARK: - 旧データの移行

    /// 旧 `manualRects`（矩形 1 個・時間軸なし・**全フレーム適用**）をマスクへ移行する。
    ///
    /// **全クリップへ 1 本ずつ配る。** 先頭クリップだけに付けると、3 クリップ構成の
    /// 下書きを再開したときクリップ 2・3 のモザイクが消える
    /// （「検出の退行は誤モザイクより重い」に反する）。
    ///
    /// - Parameter sourceTimes: クリップ id ごとの「マスクを置く素材時刻」。
    ///   `TimelineState.clampedSourceTime` を通した値を渡すこと（写真なら 0）。
    ///   キーフレームは 1 個なので `rect(atSourceTime:)` は全時刻で同じ矩形を返す
    ///   （= 旧仕様の全フレーム適用と一致する）。**渡されていないクリップは飛ばす**。
    public static func migrated(manualRects: [CGRect], clips: [TimelineClip],
                                sourceTimes: [UUID: Double]) -> [ObjectMask] {
        clips.flatMap { clip -> [ObjectMask] in
            guard let time = sourceTimes[clip.id] else { return [] }
            return manualRects.compactMap {
                ObjectMask.single(anchor: .clip(clipID: clip.id, sourceID: clip.sourceID),
                                  sourceTime: time, rect: $0)
            }
        }
    }

    /// 静止画編集（時間軸なし）の旧 `manualRects` を `.still` マスクへ移行する。
    public static func migratedStill(manualRects: [CGRect]) -> [ObjectMask] {
        manualRects.compactMap { ObjectMask.single(anchor: .still, rect: $0) }
    }
}
