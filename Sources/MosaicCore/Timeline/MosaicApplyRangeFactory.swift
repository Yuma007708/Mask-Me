import Foundation

/// 適用区間の**生成**と、クリップ編集への**追従**（S11 / S13）。
///
/// 本体（`MosaicApplyRange.swift`）が file_length の閾値に張り付いているため分冊してある。
/// 判定・マージの実体は本体側にあり、こちらはそれを使う側。
///
/// **写真クリップの区間は常に素材 [0, clip.sourceEnd) を覆う**（`MosaicApplyRange` 型の
/// doc の不変条件）。写真の素材時刻は `TimelineState.clampedSourceTime` が必ず 0 へ
/// 丸めるので、`sourceStart > 0` の区間を作るとゲートが**絶対にヒットしない**。
/// このファイルの生成器は全て `isPhoto` を**必須引数**で受け取る（既定値を置くと
/// 渡し忘れが黙って通り、帯は出ているのにモザイクが消える I1 違反になる）。
extension MosaicApplyGate {
    // MARK: - 全体を覆う区間のファクトリ（S11）

    /// クリップ全体（そのクリップが使っている素材範囲）を覆う適用区間を 1 本作る。
    ///
    /// **「新しいクリップが生まれる瞬間」の唯一の生成器である**（新規プロジェクト・
    /// 素材追加・旧データ移行の「区間 0 本」ケース）。アプリ層で `MosaicApplyRange(...)` を
    /// 直に書かないこと。**既存区間から派生させる編集追従**（`ranges(splittingClip:into:...)` /
    /// `ranges(trimmingPhotoClip:existing:)` / `TimelineState.migratedApplyRanges` の
    /// 非空ケース）はこの関数を通らず `MosaicApplyGate` 内で組み立てる——これらは
    /// 「新規生成」ではなく「既にある区間の付け替え」だからである。いずれにせよ
    /// **生成点はコア層のこの 2 系統だけ**に閉じる。
    ///
    /// 壊れたクリップ（非有限・`sourceStart >= sourceEnd`）では nil。
    ///
    /// - Parameter isPhoto: 写真素材のクリップなら true。区間は `[0, clip.sourceEnd)` になる
    ///   （`clip.sourceStart` からではない）。**既定値は置かない**。
    public static func fullCoverRange(for clip: TimelineClip, isPhoto: Bool) -> MosaicApplyRange? {
        guard clip.sourceStart.isFinite, clip.sourceEnd.isFinite,
              clip.sourceStart < clip.sourceEnd else { return nil }
        let start = isPhoto ? 0 : clip.sourceStart
        guard start < clip.sourceEnd else { return nil }
        return MosaicApplyRange(clipID: clip.id, sourceID: clip.sourceID,
                                sourceStart: start, sourceEnd: clip.sourceEnd)
    }

    /// `fullCoverRange(for:isPhoto:)` をクリップ列へ適用する（壊れたクリップは飛ばす）。
    ///
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合（`TimelineState.photoSourceIDs`）。
    ///   **既定値は置かない**（渡し忘れをコンパイルエラーにする）。
    public static func fullCoverRanges(for clips: [TimelineClip],
                                       photoSourceIDs: Set<UUID>) -> [MosaicApplyRange] {
        clips.compactMap { fullCoverRange(for: $0, isPhoto: photoSourceIDs.contains($0.sourceID)) }
    }

    // MARK: - 編集操作の区間追従（S11）

    /// クリップ分割に区間を追従させる。
    ///
    /// `atSourceTime`（= 後半クリップの `sourceStart`。以下 m）を境に、
    /// **`frontClip.id` に属する**区間を前後のクリップへ振り分ける:
    ///
    /// - `sourceEnd <= m` → 前半へ（id 据え置き）
    /// - `sourceStart >= m` → 後半へ付け替え（id 据え置き）
    /// - m をまたぐ → 2 本に割る。前半片が元 id を継承し、後半片は新規 id
    ///
    /// クリップ使用範囲の外へはみ出した部分（トリム由来で温存されている区間）も
    /// **m だけを基準に**前後へ振り分けるので温存される。他クリップの区間・順序は不変。
    ///
    /// **写真クリップは区間を割らない**（`isPhoto == true`）。m で割ると後半の区間が
    /// `[m, ...)` になり、素材時刻 0 へ丸められるゲートに永久にヒットしなくなる
    /// （実測: 3 秒の写真を 1.5 秒で分割すると合成 1.5 秒以降が全 OFF・帯は 2 本のまま
    /// ＝ I1 違反）。代わりに前後どちらのクリップにも `[0, sourceEnd)` を配る。
    /// 区間が 1 本も無いクリップ（ユーザーが削除した）には何も配らない（不変条件 I5）。
    ///
    /// **振り分け対象の識別子を別引数で取らないのは**、`TimelineEditOperations.split` が
    /// 前半クリップに元の `id` を引き継がせるからである（＝分割前のクリップ id は常に
    /// `frontClip.id`）。別引数にすると「食い違った id を渡しても黙って no-op」が作れてしまう。
    public static func ranges(splittingClip frontClip: TimelineClip,
                              into backClip: TimelineClip,
                              atSourceTime m: Double,
                              isPhoto: Bool,
                              existing: [MosaicApplyRange]) -> [MosaicApplyRange] {
        guard m.isFinite else { return existing }
        if isPhoto { return photoSplitRanges(front: frontClip, back: backClip, existing: existing) }
        return existing.flatMap { range -> [MosaicApplyRange] in
            guard range.clipID == frontClip.id else { return [range] }
            if range.sourceEnd <= m {
                return [MosaicApplyRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                                         sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            if range.sourceStart >= m {
                return [MosaicApplyRange(id: range.id, clipID: backClip.id, sourceID: range.sourceID,
                                         sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            return [
                MosaicApplyRange(id: range.id, clipID: frontClip.id, sourceID: range.sourceID,
                                 sourceStart: range.sourceStart, sourceEnd: m),
                MosaicApplyRange(clipID: backClip.id, sourceID: range.sourceID,
                                 sourceStart: m, sourceEnd: range.sourceEnd)
            ]
        }
    }

    /// 写真クリップの分割: 元の区間 1 本を前後の「全体を覆う区間」2 本へ置き換える。
    /// 元 id は前半が継承する（UI の選択が飛ばない）。
    private static func photoSplitRanges(front: TimelineClip,
                                         back: TimelineClip,
                                         existing: [MosaicApplyRange]) -> [MosaicApplyRange] {
        var handled = false
        return existing.flatMap { range -> [MosaicApplyRange] in
            guard range.clipID == front.id else { return [range] }
            // 写真の区間は正規化により高々 1 本。保険で 2 本目以降は畳む。
            guard !handled else { return [] }
            handled = true
            return [MosaicApplyRange(id: range.id, clipID: front.id, sourceID: range.sourceID,
                                     sourceStart: 0, sourceEnd: front.sourceEnd),
                    MosaicApplyRange(clipID: back.id, sourceID: range.sourceID,
                                     sourceStart: 0, sourceEnd: back.sourceEnd)]
                .filter { $0.sourceStart < $0.sourceEnd }
        }
    }

    /// **写真クリップ**のトリムに区間を追従させる。
    ///
    /// 動画クリップは素材時刻アンカーが自動追従するので何もしない（`TimelineState.trimming`
    /// の doc 参照）が、写真は区間が `[0, sourceEnd)` でなければならないため、
    /// `sourceEnd` を新しいクリップに合わせて引き直す必要がある。
    /// これをしないと「右端を伸ばしてから左端をトリムする」操作で区間がクリップと
    /// 交差しなくなり（孤児化）、帯もゲートも消える（実測: 区間 [0,3) × クリップ [4,15)）。
    ///
    /// 区間が 1 本も無いクリップには何も作らない（不変条件 I5）。
    public static func ranges(trimmingPhotoClip clip: TimelineClip,
                              existing: [MosaicApplyRange]) -> [MosaicApplyRange] {
        guard clip.sourceEnd.isFinite, clip.sourceEnd > 0 else { return existing }
        var handled = false
        return existing.flatMap { range -> [MosaicApplyRange] in
            guard range.clipID == clip.id else { return [range] }
            guard !handled else { return [] }
            handled = true
            return [MosaicApplyRange(id: range.id, clipID: clip.id, sourceID: range.sourceID,
                                     sourceStart: 0, sourceEnd: clip.sourceEnd)]
        }
    }

    /// クリップ削除に区間を追従させる（**そのクリップの区間は消す**）。
    ///
    /// `clipID` は復活しないので、温存すると帯にも出ず削除もできない永久のゴミになる。
    /// undo は `EditSnapshot.timeline` が状態ごと戻すため復元性は落ちない。
    public static func ranges(removingClipID clipID: UUID,
                              from ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        ranges.filter { $0.clipID != clipID }
    }
}
