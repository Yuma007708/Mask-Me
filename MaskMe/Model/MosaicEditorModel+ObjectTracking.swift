import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore

/// 物体モザイクの自動追跡（O2）の起動・打ち切り・進捗。
///
/// ## いつ走るか
///
/// `objectMasks` か `timeline` が変わるたびに `scheduleObjectTracking()` が呼ばれ、
/// **軌跡が無い／古いマスクを持つクリップ**だけを追い直す。全マスクの軌跡が最新なら
/// 何もしない（この判定が安いので、didSet から無条件に呼んでよい）。
///
/// ## 二重起動と取り違えの防ぎ方
///
/// タスクは**クリップ id 引き**で 1 本だけ持つ。起動時のマスク列をタスクと一緒に覚えておき、
/// 今のマスク列と一致する間は張り替えない。一致しなくなったら（ユーザーが矩形を動かした）
/// 古いタスクを `cancel()` してから新しいものを張る。
///
/// 結果を書き戻すときも**もう一度キーフレームを照合する**（`ObjectTrack.matches`）。
/// 追跡中にユーザーがさらに動かしていた場合、遅れて届いた古い軌跡を採ると
/// 手直しが画面に反映されない——プライバシーアプリでは「隠したい場所を隠せていない」
/// という実害になる。
@MainActor
extension MosaicEditorModel {
    /// 追跡開始までの待ち（秒）。矩形をドラッグ中は毎フレーム `setObjectMaskKeyframe` が
    /// 飛んでくるので、まとめて 1 回にするための遅延。
    private static var trackingDebounce: Double { 0.4 }

    /// 追跡が要るマスクを見つけて、クリップごとに追跡タスクを張り直す。
    ///
    /// **`objectMasks` / `timeline` の didSet から無条件に呼んでよい**（何も要らなければ
    /// 即 return する）。個々の編集 API に散らして書くと、新しい編集を足したときに漏れる。
    func scheduleObjectTracking() {
        let pending = pendingTrackingMasksByClip()
        // 依頼が消えたクリップのタスクを畳む（マスクを消した・クリップを消した）。
        for (clipID, entry) in objectTrackingTasks where pending[clipID] == nil {
            entry.task.cancel()
            objectTrackingTasks[clipID] = nil
            objectTrackingProgressByClip[clipID] = nil
        }
        for (clipID, masks) in pending {
            // 同じ内容で既に走っているなら触らない（ドラッグ中の連打で追跡が
            // 起動 → 即キャンセルを繰り返し、いつまでも完走しなくなるのを防ぐ）。
            if let running = objectTrackingTasks[clipID], running.masks == masks { continue }
            objectTrackingTasks[clipID]?.task.cancel()
            objectTrackingTasks[clipID] = (masks, makeTrackingTask(clipID: clipID, masks: masks))
        }
        publishTrackingProgress()
    }

    /// 走行中の追跡が終わるまで待つ。**書き出しの直前に呼ぶ。**
    ///
    /// 待たないと「プレビューでは追跡済みの位置、書き出しはキーフレーム補間」という
    /// 食い違いが出る。追跡は素材から再計算する派生データなので下書きに入っておらず、
    /// 復元直後の書き出しでこれが起きやすい。
    func awaitObjectTracking() async {
        // 待っている間に別のクリップの追跡が始まることがあるので数回まわす。
        // **回数で上限を切る**のが要点: 完了しても辞書から消えないタスクが 1 つでも
        // 残ると、`while` で待つ実装は書き出しボタンが永久に返ってこない固まり方をする。
        for _ in 0..<8 {
            let tasks = objectTrackingTasks.values.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    /// 追跡を全て打ち切る（素材の入れ替え・画面を閉じるとき）。
    func cancelObjectTracking() {
        for entry in objectTrackingTasks.values { entry.task.cancel() }
        objectTrackingTasks = [:]
        objectTrackingProgressByClip = [:]
        objectTrackingProgress = nil
    }

    // MARK: - 依頼の組み立て

    /// 追跡が要るマスクをクリップごとに集める。
    ///
    /// 除外するもの:
    /// - `.still`（静止画編集。時間軸が無いので追跡の意味が無い）
    /// - 写真クリップ（全フレーム同じ絵なので動きが無い）
    /// - **キーフレームが 1 個で、その 1 個がクリップの終端にあるマスク**は除外しない。
    ///   末尾へ向かって追跡する余地があるため（`ObjectTrack` の末尾保持）。
    /// - 既に最新の軌跡があるマスク
    ///
    /// **クリップの使用区間を広げても追い直さない**（既知の制限）。判定材料はマスクの
    /// キーフレームだけで、「軌跡が短いのは追跡が凍結したからか、区間が短かったからか」を
    /// 区別できない。区間で判定すると、正当に凍結した軌跡をタイムラインが変わるたびに
    /// 追い直し続ける無限ループになる。広げた先を追わせたいときはキーフレームを 1 個足す
    /// （＝「手直しはキーフレームで」というユーザー決定の範囲内で解決できる）。
    private func pendingTrackingMasksByClip() -> [UUID: [ObjectMask]] {
        guard mode == .video, !clips.isEmpty else { return [:] }
        var result: [UUID: [ObjectMask]] = [:]
        for mask in objectMasks {
            guard let clipID = mask.anchor.clipID,
                  let clip = clips.first(where: { $0.id == clipID }),
                  timeline.sourceKind(of: clip.sourceID) != .photo,
                  sources[clip.sourceID] != nil else { continue }
            if let track = objectTracks[mask.id], track.matches(mask) { continue }
            result[clipID, default: []].append(mask)
        }
        return result
    }

    private func makeTrackingTask(clipID: UUID, masks: [ObjectMask]) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.trackingDebounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard let clip = self.clips.first(where: { $0.id == clipID }),
                  let asset = self.sources[clip.sourceID] else {
                self.finishTracking(clipID: clipID, tracks: [:], masks: masks)
                return
            }
            let requests = masks.map {
                ObjectMaskTracker.Request(mask: $0, clipID: clipID, sourceID: clip.sourceID)
            }
            let range = clip.sourceStart...max(clip.sourceStart.nextUp, clip.sourceEnd)
            let tracks = await ObjectMaskTracker.track(
                requests, asset: asset, sourceRange: range,
                // デコーダの譲り方は `shouldYieldTrackingDecoder` の doc を参照
                // （書き出し中は譲らない＝待ち合わせのデッドロックを作らない）。
                shouldYield: { [weak self] in await self?.shouldYieldTrackingDecoder ?? false },
                onProgress: { [weak self] value in
                    Task { @MainActor in self?.updateTrackingProgress(clipID: clipID, value: value) }
                })
            guard !Task.isCancelled else { return }
            self.finishTracking(clipID: clipID, tracks: tracks, masks: masks)
        }
    }

    // MARK: - 結果の書き戻し

    /// 追跡結果を採り込む。**採る直前にもう一度キーフレームを照合する**
    /// （追跡中にユーザーが動かしていたら、その軌跡はもう嘘）。
    private func finishTracking(clipID: UUID, tracks: [UUID: ObjectTrack], masks: [ObjectMask]) {
        objectTrackingTasks[clipID] = nil
        objectTrackingProgressByClip[clipID] = nil
        var changed = false
        for (maskID, track) in tracks {
            guard let mask = objectMasks.first(where: { $0.id == maskID }), track.matches(mask)
            else { continue }
            objectTracks[maskID] = track
            changed = true
        }
        // 軌跡が作れなかったマスクの古い軌跡は落とす（`matches` で弾かれるので実害は
        // 無いが、残しておくと次の判定で「軌跡がある」と誤読しやすい）。
        for mask in masks where tracks[mask.id] == nil {
            if objectTracks[mask.id] != nil { objectTracks[mask.id] = nil; changed = true }
        }
        publishTrackingProgress()
        guard changed else { return }
        renderPreview()
        previewController?.invalidate()
    }

    private func updateTrackingProgress(clipID: UUID, value: Double) {
        guard objectTrackingTasks[clipID] != nil else { return }
        objectTrackingProgressByClip[clipID] = value
        publishTrackingProgress()
    }

    private func publishTrackingProgress() {
        let values = objectTrackingProgressByClip.values
        // 走り始めてまだ進捗が来ていないクリップも「追跡中」に含める（0 として数える）。
        let running = objectTrackingTasks.count
        guard running > 0 else {
            objectTrackingProgress = nil
            return
        }
        objectTrackingProgress = values.reduce(0, +) / Double(running)
    }
}
