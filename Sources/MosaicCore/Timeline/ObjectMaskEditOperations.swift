import CoreGraphics
import Foundation

/// `ObjectMask` をクリップ編集に追従させる純関数群。
///
/// `MosaicApplyGate.ranges(splittingClip:...)` と同じ役割・同じ引数の並びにしてある
/// （追従の規則が 2 系統に割れると、片方だけ直して片方が腐る）。
///
/// **追従が要るのは分割・複製・削除だけ。** 並べ替え・トリム・速度変更・音量変更・追加は
/// `clipID` も素材時刻も変えないので、素材時刻アンカーがそのまま自動追従する
/// （`TimelineState.moving` の doc と同じ理屈）。
public enum ObjectMaskEditOperations {
    // MARK: - クリップ編集への追従（唯一の入口）

    /// クリップ編集の前後でマスクを付け替える**唯一の入口**（アプリ層の
    /// `MosaicEditorModel.followClipEdit(from:to:lineage:)` が呼ぶ）。
    ///
    /// ## 見分け方は「推測」ではなく「血統」
    ///
    /// 消えたクリップは差分で分かる（id が消えたという事実そのもの）が、**新しく生まれた
    /// クリップが分割の後半なのか複製先なのかは差分からは決められない**。複製は
    /// 「元の直後・同じ `sourceID`・元は編集前から存在」という分割の後半とまったく同じ
    /// 見た目になるためで、実際にこの推測で複製が分割として処理され、元クリップのマスクが
    /// キーフレーム 1 個へ潰れる（＝追っていた矩形が止まり顔が露出する）バグが出た。
    /// そこで編集操作の側が `ClipLineage` で種類を伝える（`ClipLineage` の doc）。
    ///
    /// ## 血統に載っていない新規クリップ
    ///
    /// 素材追加（`appending(clip:source:...)`）は**必ず新しい `sourceID`** を連れてくるので、
    /// 既存クリップのマスクとは無関係であり何もしなくてよい。逆に、既存の `sourceID` を持つ
    /// 新規クリップが血統無しで現れたら、それは**クリップを生む編集操作を足したのに血統を
    /// 返し忘れた**ということなので、DEBUG では `assertionFailure` で落とす
    /// （黙って推測に落とすと、今回のバグと同じものを別の操作で再生産する）。
    public static func masks(following lineage: [ClipLineage],
                             from before: TimelineState,
                             to after: TimelineState,
                             existing: [ObjectMask]) -> [ObjectMask] {
        assertLineageCoversNewClips(lineage, from: before, to: after)
        var result = existing
        // 消えたクリップのマスクを落とす（分割・複製では消えない＝元が id を保つ）。
        let afterIDs = Set(after.clips.map(\.id))
        for removed in before.clips.map(\.id) where !afterIDs.contains(removed) {
            result = masks(removingClipID: removed, from: result)
        }
        for entry in lineage {
            switch entry {
            case let .split(frontID, backID):
                guard let front = after.clips.first(where: { $0.id == frontID }),
                      let back = after.clips.first(where: { $0.id == backID }) else { continue }
                result = masks(splittingClip: front, into: back,
                               atSourceTime: back.sourceStart,
                               isPhoto: after.sourceKind(of: back.sourceID) == .photo,
                               existing: result)
            case let .duplicate(originalID, copyID):
                guard let copy = after.clips.first(where: { $0.id == copyID }) else { continue }
                result = masks(duplicatingClipID: originalID, into: copy, existing: result)
            }
        }
        return result
    }

    /// 血統が新規クリップを覆っているかの検査（DEBUG のみ。本文は上の doc 参照）。
    private static func assertLineageCoversNewClips(_ lineage: [ClipLineage],
                                                    from before: TimelineState,
                                                    to after: TimelineState) {
        #if DEBUG
        let beforeIDs = Set(before.clips.map(\.id))
        let beforeSourceIDs = Set(before.clips.map(\.sourceID))
        let described = Set(lineage.map(\.createdClipID))
        for clip in after.clips
        where !beforeIDs.contains(clip.id) && !described.contains(clip.id)
            && beforeSourceIDs.contains(clip.sourceID) {
            assertionFailure("""
                既存の素材を使う新規クリップ \(clip.id) が ClipLineage に載っていない。\
                クリップを生む編集操作を足したなら TimelineEdit へ血統を返すこと\
                （推測で分割として扱うと元クリップのマスクが潰れる）。
                """)
        }
        #endif
    }

    // MARK: - 複製

    /// クリップ複製にマスクを追従させる（**元クリップのマスクは一切変更しない**）。
    ///
    /// 複製先へは元のマスクを**丸ごとコピー**する。`MosaicApplyRange` を
    /// `TimelineState.duplicatingEdit(clipID:)` が clipID だけ差し替えて複製しているのと
    /// 同じ扱いで、複製したのにモザイクの設定だけ引き継がれない状態を作らない。
    ///
    /// - `ObjectMask.id` は**新規発番**する（同じ id が 2 個並ぶと SwiftUI の `ForEach` と
    ///   `firstIndex(where:)` が片方にしか当たらない。分割の後半に新しい id を振るのと同じ理由）
    /// - キーフレームは**全部そのまま**（素材時刻・矩形・傾き）。素材使用範囲も速度も
    ///   元クリップと同一なので、素材時刻アンカーはそのまま成立する。id だけは
    ///   新規発番する（マスクが別物である以上、その部品も別物として扱う）
    /// - `isRegionPlaceholder` は引き継ぐ（分割が前後どちらにも引き継ぐのと同じ。
    ///   第 2 段が矩形サーチ由来の暫定マスクを見分けるためのフラグなので、
    ///   複製先で落とすと見失う）
    public static func masks(duplicatingClipID originalID: UUID,
                             into copy: TimelineClip,
                             existing: [ObjectMask]) -> [ObjectMask] {
        let copies = existing.compactMap { mask -> ObjectMask? in
            guard mask.anchor.clipID == originalID else { return nil }
            return ObjectMask(anchor: .clip(clipID: copy.id, sourceID: copy.sourceID),
                              keyframes: mask.keyframes.map {
                                  ObjectMask.Keyframe(sourceTime: $0.sourceTime, rect: $0.rect,
                                                      angle: $0.angle)
                              },
                              isRegionPlaceholder: mask.isRegionPlaceholder)
        }
        return existing + copies
    }

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
        // **角度も必ず渡すこと。** `Keyframe.init` の `angle` は既定 0 なので、
        // 省くと境界のキーフレームだけ無回転になり、分割点へ向かって傾きが
        // 0 まで滑り落ちる（実測: 0.5 rad の矩形が 0.46 → 0.42 → … → 0）。
        // 傾けた矩形は「検出が効かない斜めの顔」を手で隠すために置くものなので、
        // 無回転へ戻ると顔からずれて**素通しになる**。位置だけを見るテストでは
        // この欠落を捕まえられない（`test_分割しても矩形の傾きが変わらない` が番人）。
        let boundary = ObjectMask.Keyframe(sourceTime: split,
                                           rect: mask.rect(atSourceTime: split),
                                           angle: mask.angle(atSourceTime: split))
        let frontFrames = mask.keyframes.filter { $0.sourceTime < split } + [boundary]
        let backFrames = [ObjectMask.Keyframe(sourceTime: split, rect: boundary.rect,
                                              angle: boundary.angle)]
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
        // 傾きも渡すこと（`videoSplit` と同じ理由。省くと写真の分割で矩形が
        // 完全に無回転へ戻り、斜めの顔から外れる）。
        let angle = mask.angle(atSourceTime: 0)
        let frontMask = ObjectMask.single(id: mask.id,
                                          anchor: .clip(clipID: front.id, sourceID: front.sourceID),
                                          rect: rect, angle: angle,
                                          isRegionPlaceholder: mask.isRegionPlaceholder)
        let backMask = ObjectMask.single(anchor: .clip(clipID: back.id, sourceID: back.sourceID),
                                         rect: rect, angle: angle,
                                         isRegionPlaceholder: mask.isRegionPlaceholder)
        guard let frontMask, let backMask else { return [mask] }
        return [frontMask, backMask]
    }

    // MARK: - フリーズフレーム

    /// フリーズフレーム挿入（`TimelineState.freezing`）にマスクを追従させる。
    ///
    /// **これは見落とすと致命的な経路である。** 手描き矩形は「検出が効かない顔」を隠す
    /// 最後の手段なので、引き継がれないと検出も矩形も無いフレームが生まれる
    /// （＝そのコマだけ顔が露出する）。
    ///
    /// 元クリップ（`clipID`）に属する各マスクを、フリーズ点の**素材時刻**
    /// （`sourceTime`。`TimelineState.freezingEdit` が分割した場合は分割点の素材時刻、
    /// 分割しなかった場合は挿入直後のクリップの `sourceStart`）で解決し、
    /// **キーフレーム 1 個（`sourceTime == 0`）** のマスクとして `freezeClip` 用に作る。
    /// 解決には `ObjectMask.rect(atSourceTime:)` / `angle(atSourceTime:)`（補間 + 端 clamp）を
    /// そのまま使う——分岐を書き写すと `videoSplit` と同じ「端で位置が飛ぶ」事故を再生産する。
    ///
    /// - **元クリップのマスクは一切変更しない**（`existing` に含まれる元のエントリはそのまま
    ///   残り、新しいマスクが追加されるだけ。`masks(duplicatingClipID:into:existing:)` と
    ///   同じ「複製」の扱いであり、フリーズクリップは元クリップの延長ではなく独立した
    ///   静止画クリップだからである）。
    /// - `ObjectMask.id` は新規発番する（複製・分割の後半と同じ理由。同じ id が並ぶと
    ///   `ForEach` / `firstIndex(where:)` が片方にしか当たらない）。
    /// - `isRegionPlaceholder` は引き継ぐ（分割・複製と同じ規則）。
    /// - 対象クリップにマスクが 0 本なら、追加も 0 本（`existing` をそのまま返す）。
    public static func masks(freezingClip clipID: UUID, atSourceTime sourceTime: Double,
                             into freezeClip: TimelineClip,
                             existing: [ObjectMask]) -> [ObjectMask] {
        let frozen = existing.compactMap { mask -> ObjectMask? in
            guard mask.anchor.clipID == clipID else { return nil }
            let keyframe = ObjectMask.Keyframe(sourceTime: 0,
                                               rect: mask.rect(atSourceTime: sourceTime),
                                               angle: mask.angle(atSourceTime: sourceTime))
            return ObjectMask(anchor: .clip(clipID: freezeClip.id, sourceID: freezeClip.sourceID),
                              keyframes: [keyframe],
                              isRegionPlaceholder: mask.isRegionPlaceholder)
        }
        return existing + frozen
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
