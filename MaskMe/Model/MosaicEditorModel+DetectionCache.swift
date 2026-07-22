import Foundation
import MosaicCore

#if canImport(Metal)

/// `MosaicEditorModel` の検出キャッシュ参照ロジック。
///
/// フェーズ2の地ならし（PR B Task B1）でロジックを変更せずにファイル分割したもの。
///
/// **注意（Swift の言語制約）**: `currentSourceID` / `cacheStore` / `clips` /
/// `sources` / `composition` は格納プロパティのため、この extension には
/// 物理的に移動できず `MosaicEditorModel.swift`（本体）に残っている
/// （Swift の extension は格納インスタンスプロパティを持てない）。
/// ここに移したのは、それらを参照する「振る舞い」（メソッド）だけである。
extension MosaicEditorModel {
    // MARK: - 検出キャッシュ参照

    /// 指定時刻の顔ランドマークを返す。補間の仕様は `DetectionBridge` を参照
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
        let bridged = DetectionBridge(interpolates: true).faces(in: sourceScopedCache(), at: time)
        if !bridged.isEmpty { return bridged }
        // フロー橋渡し結果: 実検出の両側補間が成立しないバケットを追跡位置で埋める。
        // 実検出ホールド（nearest）より追従位置が新しいので先に引く。窓は±1バケット強
        // だけ（フローは毎バケット供給されるので、それ以上離れたら供給が途絶えた区間）。
        let flow = nearestFlowFaces(at: time)
        if !flow.isEmpty { return flow }
        let nearest = nearestCachedFaces(at: time, window: 0.75)
        if !nearest.isEmpty { return nearest }
        // 最寄りバケットが「スキャン済みで顔なし」でも、瞬き・モーションブラーによる
        // 1〜数バケットだけの検出落ちの可能性がある。再生1周目は未来側の検出がまだ
        // 無く DetectionBridge の両側補間が効かないため、blinkHoldWindow 以内の
        // 非空バケットを片側ホールドして瞬間的なモザイク消失を防ぐ。
        // 顔が本当に居ない区間では窓内に非空バケットが存在しないので空が返り、
        // 体への貼り付き（nearestCachedFaces doc 参照）は最大 blinkHoldWindow 秒で止まる。
        return nearestNonEmptyCachedFaces(at: time, window: blinkHoldWindow)
    }

    /// `nearestCachedFaces` と異なり空エントリ（スキャン済み顔なし）を飛ばして、
    /// `window` 秒以内で最も近い「顔あり」バケットを返す。瞬きブリッジ専用。
    ///
    /// `lookupFaces` からのみ呼ばれ、両者が同一ファイルに同居するため `private` のまま
    /// （アクセスレベル変更なし）。
    private func nearestNonEmptyCachedFaces(at time: Double, window: Double) -> [FaceLandmarkSet] {
        cacheStore.nearestFaces(sourceID: currentSourceID, time: time, window: window)
    }

    /// `detectionCache` のうち時刻 `time` から `window` 秒以内で最も近い
    /// 「スキャン済み」バケットの顔リストを返す。
    ///
    /// 重要: 空エントリ（スキャン済みで顔なし）もバケット選択の対象にする。
    /// 最寄りのスキャン結果が「顔なし」なら空を返す＝ホールドしない。これが無いと
    /// 「2秒前の顔位置を、顔が居ないと判明しているフレームに描き続ける」ことになり、
    /// 動いている人の体の上にモザイクが乗る・位置がずれる誤描画の原因になる。
    /// window は「ライブ検出がまだ追いついていない直近区間」を埋めるためだけの短い値。
    ///
    /// `lookupFaces` からのみ呼ばれ、両者が同一ファイルに同居するため `private` のまま
    /// （アクセスレベル変更なし）。
    private func nearestCachedFaces(at time: Double, window: Double) -> [FaceLandmarkSet] {
        // 空エントリ（スキャン済み顔なし）も選択対象にするため、非空だけを見る
        // `DetectionCacheStore.nearestFaces` は使えない。既存ロジックのまま走査する。
        var best: (dist: Double, faces: [FaceLandmarkSet])?
        for (key, faces) in cacheStore.allEntries where key.sourceID == currentSourceID {
            let d = abs(key.bucket - time)
            if d > window { continue }
            if best == nil || d < best!.dist { best = (d, faces) }
        }
        return best?.faces ?? []
    }

    /// 現在の素材のエントリを、`DetectionBridge` / `VideoMosaicExporter` が受け取る
    /// 従来の `[素材内時刻: 顔]` 形式へ射影する。
    ///
    /// フェーズ1では素材が1つしかないため実質全件コピーになる。フェーズ2で
    /// 複数素材になったときに初めてフィルタとして意味を持つ。
    ///
    /// 毎フレーム呼ばれるため射影の実体は `DetectionCacheStore` 側でメモ化してある。
    ///
    /// **アクセスレベル変更**: 元は `private func` だったが、`exportVideo()`
    /// （`MosaicEditorModel.swift` 本体側）からも呼ばれるため `internal`（無印）にした。
    func sourceScopedCache() -> [Double: [FaceLandmarkSet]] {
        cacheStore.projectedFaces(sourceID: currentSourceID)
    }
}

#endif
