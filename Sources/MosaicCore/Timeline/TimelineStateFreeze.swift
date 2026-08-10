import Foundation

/// クリップの**フリーズフレーム挿入**（`TimelineState.freezing` / `freezingEdit`）。
///
/// `TimelineState.swift` 本体から分離してあるのは、あちらが `file_length`（500 行）の
/// 上限に張り付いているため（`TimelineStateDuplication` と同じ分け方）。
///
/// ## フリーズフレームとは
///
/// 再生位置で 1 フレームを止め、その静止画を素材として新しいクリップに挟み込む編集
/// （「止め絵」）。挿入されるクリップ（`freezeClip`）自体の**エンコードや素材登録は
/// アプリ層の責務**であり、この層は「タイムライン上のどこに、どう挟み込むか」だけを扱う。
///
/// ## 挿入位置の決め方（`canFreeze` / `freezing` 共通）
///
/// - **トランジションの重なりの中では不可。** 画面に出ているのは 2 クリップの合成結果
///   （`TimelineMapping.overlap(at:)` が非 nil）であり、単一素材から取った 1 コマとは
///   一致しないため。
/// - **クリップ先頭ちょうど（許容幅つき）なら分割しない。** 挿入したいのが「このクリップの
///   直前」そのものなので、分割してから境界へ挟むのは無駄な上に、分割の最小尺制約
///   （`TimelineEditOperations.minimumClipDuration`）に不必要に引っかかる。
/// - **それ以外は `canSplit(clipID:atDisplayTime:)` と同じ判定に委ねる。** 素材時刻の算出を
///   別式で書くと分割位置とフリーズ位置が 1 ulp ずれるため（`TimelineEditOperations.split`
///   の doc 参照）、分割が要るケースは既存の分割経路をそのまま使う。
extension TimelineState {
    /// 「クリップ先頭ちょうど」とみなす許容幅（秒）。
    ///
    /// 再生位置は UI 側の時刻計算を経由するため、クリップ開始時刻と数値的に
    /// 完全一致しないことがある。`TimelineEditOperations.minimumClipDuration`（0.1 秒）より
    /// 十分小さく、60fps の 1 フレーム（約 16.7ms）より 1 桁小さい値にすることで、
    /// 「本当に先頭を狙った操作」だけを拾い、分割が必要な位置を誤って先頭扱いしない。
    private static let clipStartTolerance: Double = 1e-6

    /// 指定した表示時刻にフリーズフレームを挿入できるか。
    ///
    /// **ボタンの活性判定はこれを使うこと**（`canSplit` と同じ理由。判定と実行が別の規則で
    /// 決まると「押せるのに何も起きない」が起こる）。
    public func canFreeze(clipID: UUID, atDisplayTime displayTime: Double) -> Bool {
        freezeInsertionNeedsSplit(clipID: clipID, atDisplayTime: displayTime) != nil
    }

    /// 指定した表示時刻にフリーズフレームを挿入する。
    ///
    /// - Parameters:
    ///   - clipID: フリーズ元のクリップ。
    ///   - displayTime: 表示タイムライン（トランジションの重なり込み）の時刻。
    ///   - freezeClip: 挿入する静止画クリップ。**新規発番の `sourceID`** を持つこと
    ///     （素材登録・エンコードはアプリ層の責務）。
    ///   - source: `freezeClip.sourceID` の素材メタ。渡すと `sources` へ登録される
    ///     （`appending(clip:source:coveringWithApplyRange:)` と同じ流儀）。
    ///     渡さなくても既に `sources` に登録済みなら種別判定はそちらを使う
    ///     （未登録は `TimelineSource.Kind.video` 扱いになる既存の既定）。
    ///
    /// `canFreeze(clipID:atDisplayTime:)` が false の場合は self をそのまま返す
    /// （他の編集操作と同じ「失敗時は無変更」契約）。
    ///
    /// **分割が要る位置では、分割 + 挿入をこの 1 回の呼び出しで完結させる**
    /// （呼び出し側から見て undo 単位が 2 段に割れないようにするため）。
    /// 分割そのものは自前で書き直さず `splittingEdit(clipID:atDisplayTime:)` に委ねる
    /// （適用区間・トランジションの付け替えを二重実装しないため）。
    public func freezing(clipID: UUID, atDisplayTime displayTime: Double,
                         freezeClip: TimelineClip, source: TimelineSource? = nil) -> TimelineState {
        freezingEdit(clipID: clipID, atDisplayTime: displayTime,
                    freezeClip: freezeClip, source: source).state
    }

    /// `freezing(clipID:atDisplayTime:freezeClip:source:)` に**血統**
    /// （`ClipLineage`）を添えた版。
    ///
    /// 分割が起きた場合のみ `.split(front: clipID, back: 新規id)` を返す
    /// （`splittingEdit` がそのまま返す血統を透過するだけ）。`freezeClip` 自身は
    /// **新規の `sourceID` を持つ前提**（`appending` と同じ）なので血統には載らない
    /// （`ObjectMaskEditOperations.assertLineageCoversNewClips` の対象外）。
    /// アプリ層は分割が起きたときだけ物体マスクの分割追従
    /// （`ObjectMaskEditOperations.masks(splittingClip:into:atSourceTime:isPhoto:existing:)`）を
    /// 呼び、フリーズクリップ自体のマスク引き継ぎは
    /// `ObjectMaskEditOperations.masks(freezingClip:atSourceTime:into:existing:)` を別途呼ぶこと。
    public func freezingEdit(clipID: UUID, atDisplayTime displayTime: Double,
                             freezeClip: TimelineClip, source: TimelineSource? = nil) -> TimelineEdit {
        guard let needsSplit = freezeInsertionNeedsSplit(clipID: clipID, atDisplayTime: displayTime)
        else { return TimelineEdit(self) }

        let working: TimelineState
        let insertBeforeID: UUID
        var lineage: [ClipLineage] = []
        if needsSplit {
            let edit = splittingEdit(clipID: clipID, atDisplayTime: displayTime)
            guard let split = edit.lineage.first(where: {
                if case let .split(front, _) = $0 { return front == clipID }
                return false
            }), case let .split(_, back) = split
            else { return TimelineEdit(self) }
            working = edit.state
            insertBeforeID = back
            lineage = [split]
        } else {
            working = self
            insertBeforeID = clipID
        }

        guard let insertIndex = working.clips.firstIndex(where: { $0.id == insertBeforeID })
        else { return TimelineEdit(self) }
        let newClips = TimelineEditOperations.insert(clips: working.clips, clip: freezeClip,
                                                      at: insertIndex)
        guard newClips != working.clips else { return TimelineEdit(self) }

        var result = working.replacing(clips: newClips, transitions: working.transitions,
                                       applyRanges: working.applyRanges)
        if let source { result.sources[source.id] = source }
        // 全体を覆う適用区間を 1 本自動生成する（`appending` と同じ規則。新仕様では
        // 区間 0 本 = OFF なので、生成しないとフリーズフレームにだけモザイクが乗らない）。
        let isPhoto = result.sourceKind(of: freezeClip.sourceID) == .photo
        if let range = MosaicApplyGate.fullCoverRange(for: freezeClip, isPhoto: isPhoto) {
            result.applyRanges.append(range)
        }
        return TimelineEdit(result, lineage: lineage)
    }

    /// フリーズ挿入点の判定（唯一の情報源）。無効な位置は nil、有効なら分割が要るかを返す。
    ///
    /// クリップ開始時刻は `mapping.clipSpans`（表示タイムライン）から取る。
    /// `TimelineEditOperations.split` が使う編集タイムラインの累算とは別の時間軸だが、
    /// ここで求めた `displayTime` は分割が要る場合そのまま
    /// `splittingEdit(clipID:atDisplayTime:)` へ渡すため、`canSplit` と同じ判定
    /// （内部で編集タイムラインへ変換する）を再利用すれば式を書き写さずに済む。
    private func freezeInsertionNeedsSplit(clipID: UUID, atDisplayTime displayTime: Double) -> Bool? {
        guard displayTime.isFinite,
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }),
              mapping.overlap(at: displayTime) == nil
        else { return nil }
        if abs(displayTime - span.start) <= Self.clipStartTolerance { return false }
        guard displayTime > span.start, displayTime < span.end,
              canSplit(clipID: clipID, atDisplayTime: displayTime)
        else { return nil }
        return true
    }
}
