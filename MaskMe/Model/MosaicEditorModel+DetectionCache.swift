import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` の検出キャッシュ参照ロジックと、合成時刻→素材時刻の写像ヘルパ。
///
/// フェーズ2の地ならし（PR B Task B1）でロジックを変更せずにファイル分割したものに、
/// S3 で `TimelineMapping` の配線（合成時刻→素材ID・素材時刻の解決）を追加した。
///
/// **注意（Swift の言語制約）**: `currentSourceID` / `cacheStore` / `clips` /
/// `sources` / `composition` は格納プロパティのため、この extension には
/// 物理的に移動できず `MosaicEditorModel.swift`（本体）に残っている
/// （Swift の extension は格納インスタンスプロパティを持てない）。
/// ここに移したのは、それらを参照する「振る舞い」（メソッド）だけである。
extension MosaicEditorModel {
    // MARK: - 合成時刻 → 素材時刻の写像

    /// 合成（composition）時刻を素材ID＋素材内時刻へ解決する。全キャッシュ経路の入口。
    ///
    /// 写像範囲外の有限時刻（合成尺ちょうどの終端＝半開区間の外・負値。再生終端や
    /// AVPlayer の実測時刻の揺らぎで日常的に発生する）は、タイムラインの端へクランプ
    /// してから写像する。恒等フォールバックに落とすと、分割・並べ替え状態では
    /// 「合成時刻＝同一素材の使用区間内の別バケット」となり、誤フレームの顔が正規の
    /// 検出としてキャッシュを汚染する（エクスポートはキャッシュヒットで検出を
    /// スキップするため書き出し品質まで汚染が届く）。単一クリップではクランプ結果の
    /// バケットが恒等フォールバックと一致するため挙動不変。
    ///
    /// クリップ未構築（動画ロード前・写真モード・テストの直接注入）と非有限時刻
    /// （NaN 等）だけは、従来どおり `currentSourceID` の恒等写像にフォールバックする。
    ///
    /// **丸め順序（最重要）**: 検出キャッシュの 15fps バケット丸めは、必ずこの写像の
    /// **後**に行う（`DetectionCacheKey.init` が丸めを担う）。合成時刻で先に丸めると
    /// rate≠1 のクリップで丸め誤差が rate 倍に拡大され、素材時刻のバケットが
    /// 分裂・ずれを起こす（DetectionCacheSyncTests の丸め順序テスト参照）。
    ///
    /// **写真クリップ（S6）**: 写像で得た素材時刻は最後に
    /// `TimelineState.clampedSourceTime` を通す。写真素材（`TimelineSource.kind == .photo`）
    /// は全フレーム同一なので素材時刻を 0 に clamp し、`appendPhotoClip` が t=0 に
    /// seed した 1 エントリへ全経路（lookup・ライブ検出の書き込み・
    /// `shouldDetectPreviewFrame` の既検出判定）をヒットさせる。これにより写真区間では
    /// 2 回目以降の実検出・重複 submit が発生しない。動画素材では恒等（挙動不変）。
    func resolveSourceTime(atComposition time: Double) -> (sourceID: UUID, time: Double) {
        if let location = mapping.sourceLocation(at: time) {
            return (location.sourceID,
                    timeline.clampedSourceTime(location.time, sourceID: location.sourceID))
        }
        if !clips.isEmpty, time.isFinite, mapping.totalDuration > 0 {
            let clamped = min(max(time, 0), mapping.totalDuration.nextDown)
            if let location = mapping.sourceLocation(at: clamped) {
                return (location.sourceID,
                        timeline.clampedSourceTime(location.time, sourceID: location.sourceID))
            }
        }
        return (currentSourceID, timeline.clampedSourceTime(time, sourceID: currentSourceID))
    }

    // MARK: - 検出キャッシュ参照

    /// 指定した**合成時刻**の顔ランドマークを返す。入口で素材ID・素材時刻へ写像してから
    /// キャッシュを引く（丸めは写像の後。`resolveSourceTime` の doc 参照）。
    /// 補間の仕様は `DetectionBridge` を参照
    /// （プレビュー・エクスポート・精度計測で共通の挙動）。lerp 有効:
    /// ブリッジ区間の顔が before 位置のホールドではなく前後の中間位置になめらかに動く。
    ///
    /// フォールバック: DetectionBridge は "前後両側に検出がある" ことを要求するため、
    /// 再生開始直後・シーク直後の "初期スキャンしかまだ入っていない" 状態や、ライブ検出
    /// が数百ms遅れた状態では空を返しがち。それだと Play を押した瞬間に "モザイクが
    /// 消える → 追従バッジ探索中0%" になり "使い物にならない"。
    /// そこで、bridge が成立しないときは `fallbackWindow` 秒以内の直近検出を一方向で
    /// ホールドする。これは PREVIEW 専用で、エクスポート側は `VideoMosaicExporter` が
    /// 自前の bridge を持つため影響しない。
    func lookupFaces(at time: Double) -> [FaceLandmarkSet] {
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: time)
        let bridged = DetectionBridge(interpolates: true)
            .faces(in: sourceScopedCache(for: sourceID), at: sourceTime)
        if !bridged.isEmpty { return bridged }
        // フロー橋渡し結果: 実検出の両側補間が成立しないバケットを追跡位置で埋める。
        // 実検出ホールド（nearest）より追従位置が新しいので先に引く。窓は±1バケット強
        // だけ（フローは毎バケット供給されるので、それ以上離れたら供給が途絶えた区間）。
        let flow = nearestFlowFaces(sourceID: sourceID, sourceTime: sourceTime)
        if !flow.isEmpty { return flow }
        let nearest = nearestCachedFaces(sourceID: sourceID, sourceTime: sourceTime, window: 0.75)
        if !nearest.isEmpty { return nearest }
        // 最寄りバケットが「スキャン済みで顔なし」でも、瞬き・モーションブラーによる
        // 1〜数バケットだけの検出落ちの可能性がある。再生1周目は未来側の検出がまだ
        // 無く DetectionBridge の両側補間が効かないため、blinkHoldWindow 以内の
        // 非空バケットを片側ホールドして瞬間的なモザイク消失を防ぐ
        // （空エントリを飛ばす `DetectionCacheStore.nearestFaces` をそのまま使う）。
        // 顔が本当に居ない区間では窓内に非空バケットが存在しないので空が返り、
        // 体への貼り付き（nearestCachedFaces doc 参照）は最大 blinkHoldWindow 秒で止まる。
        return cacheStore.nearestFaces(sourceID: sourceID, time: sourceTime, window: blinkHoldWindow)
    }

    /// `detectionCache` のうち素材時刻 `sourceTime` から `window` 秒以内で最も近い
    /// 「スキャン済み」バケットの顔リストを返す。窓の幅は素材時刻基準で解釈する
    /// （キャッシュのバケット自体が素材時刻なので、rate≠1 でも意味が壊れない）。
    ///
    /// 重要: 空エントリ（スキャン済みで顔なし）もバケット選択の対象にする。
    /// 最寄りのスキャン結果が「顔なし」なら空を返す＝ホールドしない。これが無いと
    /// 「2秒前の顔位置を、顔が居ないと判明しているフレームに描き続ける」ことになり、
    /// 動いている人の体の上にモザイクが乗る・位置がずれる誤描画の原因になる。
    /// window は「ライブ検出がまだ追いついていない直近区間」を埋めるためだけの短い値。
    ///
    /// `lookupFaces` からのみ呼ばれ、両者が同一ファイルに同居するため `private` のまま
    /// （アクセスレベル変更なし）。
    private func nearestCachedFaces(sourceID: UUID, sourceTime: Double, window: Double) -> [FaceLandmarkSet] {
        // 空エントリ（スキャン済み顔なし）も選択対象にするため、非空だけを見る
        // `DetectionCacheStore.nearestFaces` は使えない。既存ロジックのまま走査する。
        var best: (dist: Double, faces: [FaceLandmarkSet])?
        for (key, faces) in cacheStore.allEntries where key.sourceID == sourceID {
            let d = abs(key.bucket - sourceTime)
            if d > window { continue }
            if best == nil || d < best!.dist { best = (d, faces) }
        }
        return best?.faces ?? []
    }

    /// 指定素材のエントリを、`DetectionBridge` / `VideoMosaicExporter` が受け取る
    /// 従来の `[素材内時刻: 顔]` 形式へ射影する。
    ///
    /// 旧 `sourceScopedCache()`（引数なし・`currentSourceID` 固定）を、対象素材を
    /// 明示的に受け取る形へ整理した（単一素材時代の名残 API の解消）。呼び出し側は
    /// `resolveSourceTime(atComposition:)` で解決した素材ID、またはエクスポート対象の
    /// 素材IDを渡す。
    ///
    /// 毎フレーム呼ばれるため射影の実体は `DetectionCacheStore` 側でメモ化してある。
    ///
    /// **アクセスレベル**: `exportVideo()`（`MosaicEditorModel.swift` 本体側）からも
    /// 呼ばれるため `internal`（無印）。
    func sourceScopedCache(for sourceID: UUID) -> [Double: [FaceLandmarkSet]] {
        cacheStore.projectedFaces(sourceID: sourceID)
    }
}

#endif
