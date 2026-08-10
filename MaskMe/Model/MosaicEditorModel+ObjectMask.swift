import CoreGraphics
import Foundation
import MosaicCore

/// 物体モザイク（`ObjectMask`）の解決と編集。
///
/// ## 座標系（最重要）
///
/// **`ObjectMask.Keyframe.rect` は素材フレーム基準**で持つ。ユーザーがプレビュー上に
/// 描く矩形は合成フレーム基準なので、保存前に `renderLayout.inverseRemap` で素材基準へ
/// 落とし、描画直前に `renderLayout.remap` で合成基準へ戻す（顔ランドマークが
/// `displayFaces(at:)` で通っているのと同じ往復）。
///
/// 旧 `ManualRegion` は合成フレーム基準のまま持っていた。素材アンカー（`clipID` +
/// 素材時刻）を名乗るなら合成基準では成立しない——アスペクトの違うクリップを足した
/// 瞬間にレターボックスが変わり、保存済みの矩形が物体から外れる。
///
/// ## 描画の入口は 1 本
///
/// プレビュー 2 経路（`renderPreview` / `MosaicPreviewController`）とエクスポートが
/// **全て `objectMaskRects(atComposition:)` を通る**。`MosaicApplyRange` の
/// 「編集の入口は 1 本だけ」と同じ理由で、解決規則（clipID の絞り込み・適用区間ゲート・
/// レイアウト写像・トランジションの union）を書き写さない。
@MainActor
extension MosaicEditorModel {
    // MARK: - 描画用の解決

    /// **画面に映る物体マスクの矩形**（合成フレーム基準の正規化座標）を返す描画用の唯一の入口。
    ///
    /// `displayFaces(at:)` と同じ順序で処理する:
    ///
    /// 1. 合成時刻を素材位置へ写す（`resolveSourceLocation` / `sourceLocations`）
    /// 2. **`anchor.clipID == location.clipID` のマスクだけ**を選ぶ。絞り込まないと
    ///    クリップ A に置いたマスクが B にも出る
    /// 3. 適用区間ゲート（`isMosaicActive`）を素材ごとに掛ける
    /// 4. `rect(atSourceTime:)` で補間し、`renderLayout.remap` で合成基準へ写す
    /// 5. トランジションの重なりでは両側を `TransitionKind.visibleRect` で変換して union
    ///
    /// 静止画編集（クリップ無し）では `.still` のマスクをそのまま返す
    /// （時間軸が無いので写像もゲートも掛からない）。
    func objectMaskRects(atComposition time: Double) -> [CGRect] {
        guard !clips.isEmpty else {
            return objectMasks.filter(\.anchor.isStill).map { $0.rect(atSourceTime: 0) }
        }
        let locations = mapping.sourceLocations(at: time)
        guard locations.count >= 2, let overlap = mapping.overlap(at: time) else {
            // 重なり外。`resolveSourceLocation` は写像範囲外（終端フレーム）でも
            // クランプ付きで解決するので、顔側と同じ値でゲート・絞り込み・写像を揃える。
            let resolved = resolveSourceLocation(atComposition: time)
            guard isMosaicActive(clipID: resolved.clipID, sourceID: resolved.sourceID,
                                 sourceTime: resolved.time) else { return [] }
            return ObjectMaskResolver.rects(objectMasks, tracks: objectTracks,
                                            clipID: resolved.clipID,
                                            sourceTime: resolved.time, layout: renderLayout)
        }
        return locations.flatMap { entry -> [CGRect] in
            guard let side = entry.side, let progress = entry.progress else { return [] }
            let sourceTime = timeline.clampedSourceTime(entry.location.time,
                                                        sourceID: entry.location.sourceID)
            guard isMosaicActive(clipID: entry.location.clipID,
                                 sourceID: entry.location.sourceID,
                                 sourceTime: sourceTime) else { return [] }
            return ObjectMaskResolver.rects(objectMasks, tracks: objectTracks,
                                            clipID: entry.location.clipID,
                                            sourceTime: sourceTime, layout: renderLayout)
                .compactMap { overlap.kind.visibleRect($0, progress: progress, side: side) }
        }
    }

    /// 物体マスクを `FaceMaskBuilder.RegionPath` に変換する（描画層の入口）。
    func objectMaskPaths(for size: CGSize, atComposition time: Double) -> [FaceMaskBuilder.RegionPath] {
        objectMaskRects(atComposition: time).map {
            FaceMaskBuilder.RegionPath(path: FaceMaskBuilder.rectPath(from: $0, in: size), value: 0.4)
        }
    }

    /// UI のチップ表示用: マスク id と**現在の再生位置での**合成基準矩形。
    ///
    /// `objectMasks` をそのまま `ForEach` してはいけない。矩形はキーフレーム補間で
    /// 時刻ごとに変わるので、シークしてもチップの枠が動かなくなる。
    public var visibleObjectMasks: [(id: UUID, rect: CGRect)] {
        let time = compositionTimeForOverlay
        guard !clips.isEmpty else {
            return objectMasks.filter(\.anchor.isStill).map { ($0.id, $0.rect(atSourceTime: 0)) }
        }
        let resolved = resolveSourceLocation(atComposition: time)
        return objectMasks.filter { $0.anchor.clipID == resolved.clipID }.map { mask in
            // チップの枠も軌跡に乗せる（描画だけ追跡位置・枠はキーフレーム位置、では
            // ユーザーが「どこを掴めば直せるのか」を見失う）。
            let rect = ObjectMaskResolver.rect(of: mask, tracks: objectTracks,
                                               atSourceTime: resolved.time)
            return (mask.id, renderLayout.remap(rect, clipID: resolved.clipID))
        }
    }

    /// オーバーレイ（矩形チップ・キーフレーム編集）が使う合成時刻。
    ///
    /// **描画に使う `timeSec`（実フレームの合成時刻）とは別物**である。あちらは
    /// デコード済みフレームの実時刻で、こちらは UI が握っている再生位置。
    /// 描画に `@Published` の再生位置を使うと再生中にマスクだけ 1〜3 コマずれるので、
    /// 用途を混ぜないこと。
    var compositionTimeForOverlay: Double {
        playbackPosition * mapping.totalDuration
    }

    // MARK: - 編集

    /// プレビュー上に描かれた矩形（**合成フレーム基準**）から新しいマスクを作る。
    ///
    /// 旧 `appendManualRect` の後継。矩形サーチで顔が見つからなかったときの
    /// フォールバック経路であることは変えていない（顔として見つかれば顔追跡に乗り、
    /// 物体モザイクの話ではなくなる）。
    func appendObjectMask(compositionRect rect: CGRect) {
        guard let mask = makeObjectMask(compositionRect: rect) else { return }
        objectMasks.append(mask)
        commitEdit()
    }

    private func makeObjectMask(compositionRect rect: CGRect) -> ObjectMask? {
        guard !clips.isEmpty else { return ObjectMask.single(anchor: .still, rect: rect) }
        let resolved = resolveSourceLocation(atComposition: compositionTimeForOverlay)
        guard let clipID = resolved.clipID,
              let clip = clips.first(where: { $0.id == clipID }),
              let sourceRect = renderLayout.inverseRemap(rect, clipID: clipID) else { return nil }
        return ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: clip.sourceID),
                                 sourceTime: resolved.time, rect: sourceRect)
    }

    /// マスクごと削除する（UI のチップの ✕）。
    public func removeObjectMask(_ id: UUID) {
        guard objectMasks.contains(where: { $0.id == id }) else { return }
        objectMasks.removeAll { $0.id == id }
        renderPreview()
        previewController?.invalidate()
        commitEdit()
    }

    /// 現在の再生位置にキーフレームを置く（矩形をドラッグして位置を直す操作）。
    ///
    /// 渡す矩形は**合成フレーム基準**。素材基準へ落としてから積む。
    /// 同じ時刻に既にキーフレームがあれば置換される（`ObjectMask.settingKeyframe`）。
    public func setObjectMaskKeyframe(_ id: UUID, compositionRect rect: CGRect) {
        guard let index = objectMasks.firstIndex(where: { $0.id == id }) else { return }
        let mask = objectMasks[index]
        let sourceRect: CGRect
        let sourceTime: Double
        if let clipID = mask.anchor.clipID {
            guard let mapped = renderLayout.inverseRemap(rect, clipID: clipID) else { return }
            sourceRect = mapped
            sourceTime = resolveSourceLocation(atComposition: compositionTimeForOverlay).time
        } else {
            sourceRect = rect
            sourceTime = 0
        }
        let updated = mask.settingKeyframe(atSourceTime: sourceTime, rect: sourceRect)
        guard updated != mask else { return }
        objectMasks[index] = updated
        renderPreview()
        previewController?.invalidate()
        commitEdit()
    }

    /// キーフレームを 1 個消す。最後の 1 個を消すと**マスクごと**消える
    /// （`ObjectMask.removingKeyframe` が nil を返す＝「マスクごと消せ」の合図）。
    public func removeObjectMaskKeyframe(maskID: UUID, keyframeID: UUID) {
        guard let index = objectMasks.firstIndex(where: { $0.id == maskID }) else { return }
        let mask = objectMasks[index]
        if let updated = mask.removingKeyframe(id: keyframeID) {
            guard updated != mask else { return }
            objectMasks[index] = updated
        } else {
            objectMasks.remove(at: index)
        }
        renderPreview()
        previewController?.invalidate()
        commitEdit()
    }

    /// 現在のクリップに属するマスクのキーフレーム位置（合成時刻）。タイムラインのマーカー用。
    ///
    /// **クリップの使用区間の外に落ちたキーフレームは返さない。** 分割で境界へ挿入した
    /// キーフレームは front の素材範囲 `[sourceStart, m)` の**外側**（`m` ちょうど）に
    /// 落ちるため、合成時刻へ写せない。描画は clamp で正しく出るが、マーカーとしては
    /// 置き場が無いので出さない（出すとクリップ帯の外に浮いてタップできない）。
    public func objectMaskKeyframeMarkers(maskID: UUID) -> [(id: UUID, compositionTime: Double)] {
        guard let mask = objectMasks.first(where: { $0.id == maskID }),
              let clipID = mask.anchor.clipID else { return [] }
        return mask.keyframes.compactMap { frame in
            guard let time = mapping.compositionTime(clipID: clipID, sourceTime: frame.sourceTime)
            else { return nil }
            return (frame.id, time)
        }
    }

    // MARK: - 旧下書きの移行

    /// 旧 `manualRects`（矩形 1 個・時間軸なし・**全フレーム適用**）を取り込む。
    ///
    /// 写真は `.still`、クリップが立っている動画は**全クリップへ 1 本ずつ**。
    /// クリップ未構築の動画（v1 下書き）は保留し、`replaceTimeline` がクリップを
    /// 立てた瞬間に配る（`pendingLegacyManualRects` の doc）。
    func migrateLegacyManualRects(_ rects: [CGRect]) {
        pendingLegacyManualRects = []
        guard !rects.isEmpty else { return }
        guard mode == .video else {
            objectMasks += ObjectMaskEditOperations.migratedStill(manualRects: rects)
            return
        }
        guard !clips.isEmpty else {
            pendingLegacyManualRects = rects
            return
        }
        objectMasks += migratedMasks(from: rects)
    }

    /// 保留中の旧矩形を、クリップが立ったところで配る。
    func migratePendingManualRectsIfNeeded() {
        guard !pendingLegacyManualRects.isEmpty, !clips.isEmpty else { return }
        let rects = pendingLegacyManualRects
        pendingLegacyManualRects = []
        objectMasks += migratedMasks(from: rects)
    }

    /// 素材時刻は必ず `clampedSourceTime` を通す（写真クリップは 0 でなければ
    /// ゲートにも補間にもヒットしない）。
    private func migratedMasks(from rects: [CGRect]) -> [ObjectMask] {
        let times = Dictionary(uniqueKeysWithValues: clips.map { clip in
            (clip.id, timeline.clampedSourceTime(clip.sourceStart, sourceID: clip.sourceID))
        })
        return ObjectMaskEditOperations.migrated(manualRects: rects, clips: clips, sourceTimes: times)
    }

    // MARK: - クリップ編集への追従

    /// クリップ編集の前後でマスクを付け替える（`applyTimelineEdit` から呼ぶ）。
    ///
    /// 素材時刻アンカーなので、追従が要るのは**分割と削除だけ**
    /// （`ObjectMaskEditOperations` の doc）。分割・削除の検出はクリップ列の差分で行う:
    /// 個々の編集 API に手を入れると、新しい編集操作を足したときに漏れる。
    func followClipEdit(from before: TimelineState, to after: TimelineState) {
        let beforeIDs = before.clips.map(\.id)
        let afterIDs = Set(after.clips.map(\.id))
        // 消えたクリップのマスクを落とす（分割では消えない＝front が id を継承する）。
        var result = objectMasks
        for removed in beforeIDs where !afterIDs.contains(removed) {
            result = ObjectMaskEditOperations.masks(removingClipID: removed, from: result)
        }
        // 分割: 直前のクリップと素材が同じ新規クリップが「後半」。
        let newIDs = after.clips.filter { !Set(beforeIDs).contains($0.id) }.map(\.id)
        for newID in newIDs {
            guard let backIndex = after.clips.firstIndex(where: { $0.id == newID }), backIndex > 0
            else { continue }
            let back = after.clips[backIndex]
            let front = after.clips[backIndex - 1]
            guard front.sourceID == back.sourceID, Set(beforeIDs).contains(front.id) else { continue }
            result = ObjectMaskEditOperations.masks(
                splittingClip: front, into: back, atSourceTime: back.sourceStart,
                isPhoto: after.sourceKind(of: back.sourceID) == .photo, existing: result)
        }
        guard result != objectMasks else { return }
        objectMasks = result
    }
}
