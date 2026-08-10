import Foundation
import MosaicCore

// モザイク適用区間（S9 で状態編集と表示、S10 で描画ゲートを配線）の編集 API。
// `MosaicEditorModel+Timeline.swift` が file_length 上限に達したため分けてある。

extension MosaicEditorModel {

    /// 合成時刻の区間 [from, to) をモザイク適用区間として追加する。
    ///
    /// UI は合成時刻で操作し、保存は素材時刻アンカーへ写す（`MosaicApplyGate` が担当）。
    /// クリップを跨ぐ区間は素材ごとに分解され、重複・隣接はマージされる。
    public func addMosaicApplyRange(fromCompositionTime from: Double, to: Double) {
        applyTimelineEdit { $0.addingApplyRange(fromCompositionTime: from, to: to) }
    }

    /// 指定した適用区間を取り除く。
    public func removeMosaicApplyRange(id: UUID) {
        applyTimelineEdit { $0.removingApplyRange(id: id) }
    }

    /// 適用区間が 1 本も無ければ区間を作る。**クリップを選択しているときはそのクリップ
    /// だけ**、選択が無い（または選択が解決できない）ときは**従来どおり全クリップ**に
    /// 全域の区間を作る。
    ///
    /// **モザイクを「かける」操作の入口で必ず通すこと。** 区間 0 本は
    /// 「全区間 OFF」であり（`MosaicApplyGate` の仕様）、効果のフラグを立てただけでは
    /// 何も描かれない。実際に「加工レイヤーを消す → もう一度かける → 完了を押しても
    /// 何も起きない」というユーザー報告になった。効果の ON/OFF と区間の有無は
    /// 別々に持っているので、**繋ぐのは操作の入口の責任**である。
    ///
    /// クリップ 1 本だけに絞るのは、実機で「1 本選んでからモザイクを掛けたのに全クリップに
    /// 掛かる」という報告があったため（安全側＝モザイクが掛かる範囲を狭める変更）。
    /// 判定は `timelineSelection.clipID`。`TimelineSelection.prune(against:)` が
    /// タイムライン変化のたびに消えたクリップの選択を刈っているので、ここで見る値は
    /// 常に「今も存在するクリップ」か `nil` のどちらかのはずだが、`fullCoverRange` が
    /// nil を返す壊れたクリップ（非有限・`sourceStart >= sourceEnd`）に対しては
    /// **安全側の全クリップへフォールバックする**（選択が無いときと同じ扱い）。
    ///
    /// **判定の単位は「選んだクリップ」であって「全体」ではない。**
    ///
    /// クリップを選んでいるときに見るのは**そのクリップに区間があるか**だけで、
    /// 他のクリップの区間の有無は関係ない。ここを「`applyRanges` が空のときだけ」に
    /// すると、**A に掛けた後で B を選んで掛けても何も起きない**（全体としては
    /// 空でないため入口で弾かれる）。ユーザーからは「掛けたのに反応しない」に見える。
    ///
    /// **一部だけ残っているときは触らない**（選択が無い場合）。特定のクリップの区間を
    /// 消したのは意図的な操作なので、別のクリップで効果を入れ直したからといって
    /// 復活させない。全部消えているときだけ「掛けるつもりで何も無い」＝繋ぎ忘れとみなす。
    ///
    /// **「区間があるか」は `timeline.applyRanges` ではなく `effectiveApplyRanges`
    /// （＝孤児区間を除いた有効区間）で見ること。**
    ///
    /// 適用区間は素材時刻アンカーなので、クリップをトリムすると区間がクリップの使用範囲と
    /// 交差しなくなる（孤児区間）。孤児はデータとしては温存されるが**帯にも出ずゲートも
    /// 全区間 OFF** で（不変条件 I1）、ユーザーから見れば「区間は 1 本も無い」状態である。
    /// ここを生データで判定すると、**孤児だけが残った状態でモザイクを掛け直しても
    /// 入口で弾かれ、何も起きない**（トリムしただけのユーザーには理由が分からない）。
    /// 孤児は `effectiveApplyRanges` が既に除いているので、そちらを見れば同じ規則のまま
    /// この穴だけが閉じる。
    func ensureApplyRangesExist() {
        guard !timeline.clips.isEmpty else { return }
        let selectedClipID = timelineSelection.clipID
        // 選択中のクリップが解決でき、まだそのクリップの**有効な**区間が無いときだけ 1 本足す。
        if let selectedClipID,
           timeline.clips.contains(where: { $0.id == selectedClipID }),
           !effectiveApplyRanges.contains(where: { $0.clipID == selectedClipID }) {
            applyTimelineEdit { state in
                guard let clip = state.clips.first(where: { $0.id == selectedClipID }),
                      let range = MosaicApplyGate.fullCoverRange(
                          for: clip, isPhoto: state.photoSourceIDs.contains(clip.sourceID))
                else { return state }   // 壊れたクリップ。ここでは何も足さない
                var next = state
                // **このクリップの孤児区間はここで捨てる。** 残すと、後でトリムを戻したとき
                // 孤児が生き返って今足した全域区間と重なる（同じ clipID に重複区間が並ぶ）。
                // 温存の目的は「トリムの往復で区間が戻ること」だが、ユーザーはいま
                // 「このクリップに掛け直す」と言ったので、その意思が古い区間より優先される。
                next.applyRanges.removeAll { $0.clipID == selectedClipID }
                next.applyRanges.append(range)
                return next
            }
        }
        // ここへ来るのは「選択が無い／解決できない」か、`fullCoverRange` が nil を返す
        // 壊れたクリップで何も足せなかった場合。安全側で全クリップを覆う。
        guard effectiveApplyRanges.isEmpty else { return }
        applyTimelineEdit { state in
            var next = state
            next.applyRanges = MosaicApplyGate.fullCoverRanges(
                for: state.clips, photoSourceIDs: state.photoSourceIDs)
            return next
        }
    }

    /// 掴んだセグメント（適用区間 × クリップ）を新しい合成区間で置き換える（端ドラッグの確定）。
    ///
    /// 差し替えは素材時刻で行われ、当該クリップの使用範囲外にある素材区間は温存される
    /// （`TimelineState.replacingApplyRange(id:clipID:compositionInterval:)` の doc 参照）。
    /// マージで id が変わり得るので、UI は編集後に区間を引き直すこと。
    public func setMosaicApplyRange(id: UUID, clipID: UUID, interval: CompositionInterval) {
        applyTimelineEdit { $0.replacingApplyRange(id: id, clipID: clipID, compositionInterval: interval) }
    }

    /// 掴んだセグメント（適用区間 × クリップ）を、同一クリップ内で合成時刻換算 `delta` 秒だけ
    /// 平行移動する（区間「移動」ジェスチャの確定。端ドラッグではなく本体ドラッグ）。
    ///
    /// **`TimelineState.movingApplyRange(id:clipID:byCompositionDelta:)` への薄いラッパ**
    /// （`setMosaicApplyRange` と対称）。掴んだセグメントの現在位置を素材アンカーから
    /// 求め直したうえで移動するため、`replacingApplyRange` に絶対区間を渡すのと違い、
    /// UI 側の下書き表示がわずかに古くても取り違えない。クリップを跨ぐ移動はせず境界で
    /// クランプし、`delta == 0` や写真クリップは no-op。マージで id が変わり得るので、
    /// UI は編集後に区間を引き直すこと（`setMosaicApplyRange` と同じ契約）。
    public func moveMosaicApplyRange(id: UUID, clipID: UUID, byCompositionDelta delta: Double) {
        applyTimelineEdit { $0.movingApplyRange(id: id, clipID: clipID, byCompositionDelta: delta) }
    }

}
