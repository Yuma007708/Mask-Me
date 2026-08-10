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
/// 合成時刻を解決した結果（クリップ・素材・素材内時刻）。
///
/// タプルではなく型にしてあるのは要素が 3 つあるためで、意味は
/// `MosaicEditorModel.resolveSourceLocation(atComposition:)` の doc を参照。
struct ResolvedSourceLocation {
    /// 解決できたクリップの id。**nil = 写像不能**（クリップ未構築・写真モード・
    /// テスト直注入）で、適用区間ゲートはここでフェイルオープンする。
    let clipID: UUID?
    let sourceID: UUID
    /// 素材内時刻（写真素材は 0 へ clamp 済み）。
    let time: Double
}

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
        let resolved = resolveSourceLocation(atComposition: time)
        return (resolved.sourceID, resolved.time)
    }

    /// `resolveSourceTime(atComposition:)` の実体。**クリップ id も返す。**
    ///
    /// 適用区間ゲート（S11）は `clipID` アンカーなので、素材ID・素材時刻だけでは
    /// 判定できない。`clipID` が nil = 写像不能（クリップ未構築・写真モード・
    /// テスト直注入）であり、ゲートはそこでフェイルオープンする。
    ///
    /// **クランプ規則をここ以外に書き写さないこと。** 終端フレーム（合成尺ちょうどの
    /// PTS）で `mapping.sourceLocation(at:)` は nil を返すため、未クランプの clipID を
    /// ゲートに渡すとプレビューだけがフェイルオープンし、クランプ済みで判定する
    /// エクスポート（`VideoMosaicExporter.resolveLocation(_:at:)`）と食い違う。
    /// 既存呼び出し 10 箇所のタプル分解を壊さないため、`resolveSourceTime` は
    /// この関数の薄いラッパとして残してある。
    func resolveSourceLocation(atComposition time: Double) -> ResolvedSourceLocation {
        if let location = mapping.sourceLocation(at: time) {
            return resolved(location)
        }
        if !clips.isEmpty, time.isFinite, mapping.totalDuration > 0 {
            let clamped = min(max(time, 0), mapping.totalDuration.nextDown)
            if let location = mapping.sourceLocation(at: clamped) { return resolved(location) }
        }
        return ResolvedSourceLocation(clipID: nil, sourceID: currentSourceID,
                                      time: timeline.clampedSourceTime(time, sourceID: currentSourceID))
    }

    private func resolved(_ location: TimelineMapping.SourceLocation) -> ResolvedSourceLocation {
        ResolvedSourceLocation(
            clipID: location.clipID, sourceID: location.sourceID,
            time: timeline.clampedSourceTime(location.time, sourceID: location.sourceID))
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
        return lookupFaces(sourceID: sourceID, sourceTime: sourceTime)
    }

    /// 素材ID・素材時刻を直接指定して検出キャッシュを引く（写像済みの入口）。
    ///
    /// `lookupFaces(at:)` の本体。トランジションの重なり区間では合成時刻 1 つに対して
    /// 素材位置が 2 つあるため（`TimelineMapping.sourceLocations(at:)`）、
    /// `displayFaces(at:)` が片側ずつこちらを呼ぶ。
    func lookupFaces(sourceID: UUID, sourceTime: Double) -> [FaceLandmarkSet] {
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

    /// **画面に映っている顔**（合成フレーム基準の正規化座標）を返す描画用の唯一の入口。
    ///
    /// 重なり区間（`sourceLocations(at:)` が 2 要素）では 2 クリップが同時に映るので、
    /// 両方の顔にモザイクが要る。各要素について
    ///
    /// 1. 素材スコープのキャッシュを引き（写真素材は素材時刻 0 へ clamp）、
    /// 2. `renderLayout` で合成フレーム基準へ写し（解像度混在のレターボックス）、
    /// 3. `TransitionKind.visibleLandmarks` で視覚変換（移動・可視判定）を適用する
    ///
    /// という順で処理して union する。3 は `AVVideoComposition` の instruction ランプと
    /// **同じ純関数**から生成されるため、顔位置とフレームが必ず一致する。
    /// 重なり外は従来どおり単一位置（レイアウト写像のみ）。
    func displayFaces(at time: Double) -> [FaceLandmarkSet] {
        displayFaces(at: time, matching: nil)
    }

    /// `displayFaces(at:)` に「選択顔だけへ絞る」段を足したもの。
    ///
    /// **絞り込みは素材フレーム基準のまま、写像より前に行う**（`selecting(_:sourceID:targets:)`）。
    /// `FaceTarget.landmarks` は検出時のままの素材座標なので、合成フレーム基準へ写した後の
    /// 顔と重心を比べると座標系が混在する（レターボックスの実測ずれは最大 0.175。
    /// 閾値 0.5 に対し単独顔では落ちないが、顔が 2 人以上で互いに 0.35 以内に居ると誤マッチしうる）。
    /// 逆に「両方を合成座標へ揃える」と、レターボックスで顔同士の間隔が縮むぶん
    /// 閾値 0.5 が緩くなり未選択の顔まで通る。閾値は素材座標で調整されてきた値なので、
    /// **素材座標で照合して、それから写す**のが座標系・閾値の意味を両方保つ唯一の順序である。
    ///
    /// **モザイク適用区間のゲート（S10）はこの関数の中、素材ごとに置く。**
    /// 区間外の素材の顔は空になり、その素材の映像は素のまま残る。重なり区間で
    /// 片方の素材だけが区間内なら、**区間内の素材の顔にだけ**モザイクが乗る
    /// （両者をまとめて ON/OFF してはならない）。判定に渡す素材時刻は、その素材
    /// ブランチが `lookupFaces` に使ったのと**同じ値**である（合成時刻ではない。
    /// rate ≠ 1 のクリップで区間の位置がずれるため）。
    /// ゲートを `lookupFaces` 側に入れないこと: 区間外でもライブ検出は継続して
    /// 検出キャッシュを埋める（後から区間を広げたときに再検出させないため）。
    ///
    /// - Parameter targets: nil なら絞り込みなし（＝`displayFaces(at:)`）。
    func displayFaces(at time: Double, matching targets: [FaceTarget]?) -> [FaceLandmarkSet] {
        let locations = mapping.sourceLocations(at: time)
        guard locations.count >= 2, let overlap = mapping.overlap(at: time) else {
            // 重なり外なので素材位置は高々 1 つ。`resolveSourceLocation` は写像範囲外
            // （locations が空）でも lookupFaces(at:) と同じクランプ付き解決へ落ちるため、
            // クリップID・素材ID・素材時刻をここで一度だけ解決し、ゲート・lookup・
            // レイアウト写像の 3 つに使い回す（別々に解決すると境界フレームで食い違う）。
            // **未クランプの `mapping.sourceLocation(at:)?.clipID` を使わないこと**:
            // 終端フレームだけプレビューがフェイルオープンし、クランプ済みで判定する
            // エクスポートと食い違う。
            let resolved = resolveSourceLocation(atComposition: time)
            guard isMosaicActive(clipID: resolved.clipID, sourceID: resolved.sourceID,
                                 sourceTime: resolved.time) else { return [] }
            let faces = selecting(lookupFaces(sourceID: resolved.sourceID, sourceTime: resolved.time),
                                  sourceID: resolved.sourceID, sourceTime: resolved.time,
                                  targets: targets)
            return renderLayout.remap(faces, clipID: resolved.clipID)
        }
        return locations.flatMap { entry -> [FaceLandmarkSet] in
            guard let side = entry.side, let progress = entry.progress else { return [] }
            let sourceTime = timeline.clampedSourceTime(entry.location.time,
                                                        sourceID: entry.location.sourceID)
            guard isMosaicActive(clipID: entry.location.clipID,
                                 sourceID: entry.location.sourceID,
                                 sourceTime: sourceTime) else { return [] }
            let faces = selecting(lookupFaces(sourceID: entry.location.sourceID, sourceTime: sourceTime),
                                  sourceID: entry.location.sourceID, sourceTime: sourceTime,
                                  targets: targets)
            let placed = renderLayout.remap(faces, clipID: entry.location.clipID)
            return overlap.kind.visibleLandmarks(placed, progress: progress, side: side)
        }
    }

    /// **素材フレーム基準**のキャッシュ顔を、選択顔（`FaceTarget`）に対応するものだけへ絞る。
    ///
    /// 判定は 2 段。**署名は確信があるときだけ位置判断を覆す**
    /// （規則の表は `FaceIdentityPolicy.hidden` の doc）。位置だけで見ていた頃は
    ///
    /// - 選んだ人がフレームアウトして別位置から戻ると、重心が 0.5 以上離れて外れる
    /// - 選んでいない人が選んだ人の隣（0.5 以内）に来ると巻き添えで隠れる
    ///
    /// の両方が起きていた。署名が「別人と言い切れる」ときにだけ素のまま残し、
    /// 迷ったら隠す（プライバシーアプリなので露出の方が取り返しがつかない）。
    ///
    /// 位置の当たり判定は従来どおり**素材座標での重心 0.5**（この閾値は素材座標で
    /// 調整されてきた値なので、写像より前に評価する。呼び出し側の doc 参照）。
    /// 照合対象はこの素材に属する選択顔だけ（別素材の「似た位置の顔」との誤マッチ防止）。
    /// `sourceID` が nil の顔（写真モード・素材ID導入前の経路・テスト直注入）は
    /// 従来どおり素材不問で照合する。この素材の選択顔が 1 つも無ければ空
    /// （＝その素材の顔にはモザイクを掛けない）。
    ///
    /// `sourceTime` は署名を引くために要る。**`faces` を引いたのと同じ素材時刻**を渡すこと
    /// （別の時刻で引くと、顔と署名が別フレームのものになり添字がずれる）。
    private func selecting(_ faces: [FaceLandmarkSet],
                           sourceID: UUID?, sourceTime: Double,
                           targets: [FaceTarget]?) -> [FaceLandmarkSet] {
        guard let targets else { return faces }
        let scoped = targets.filter { target in
            guard let targetSource = target.sourceID, let sourceID else { return true }
            return targetSource == sourceID
        }
        guard !scoped.isEmpty else { return [] }
        let centroids = scoped.map { normalizedCentroid(of: $0.landmarks) }
        // 閾値と重心の式は `FaceCentroidMatching` に 1 本化してある
        // （プレビュー上のタップ選択が同じ判定を使う。別々に持つと
        // 「枠が出ているのにタップしても選べない顔」が生まれる）。
        // 「許容内に 1 つでもあるか」は最近傍が許容内かと同値。
        let spatiallyMatched = faces.map {
            FaceCentroidMatching.nearestIndex(for: $0, in: centroids) != nil
        }
        let signatures = sourceID.map {
            signatureCache.signatures(for: faces, sourceID: $0, time: sourceTime)
        } ?? [FaceSignature?](repeating: nil, count: faces.count)
        return FaceIdentityPolicy.hidden(
            faces: faces,
            signatures: signatures,
            spatiallyMatched: spatiallyMatched,
            selectedPersons: selectedPersonProfiles(of: scoped))
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

    // MARK: - 矩形サーチ結果のマージ書き込み

    /// 矩形サーチ（`detectInRegion` / `resolveRegion`）が見つけた顔を検出キャッシュへ
    /// **追記**する。
    ///
    /// **`cacheStore.store` を素で呼んではいけない。** `store` はそのバケットを
    /// 丸ごと置き換える（上書き）。矩形サーチはユーザーが描いた範囲の中だけを見ており、
    /// そのバケットには既にライブ検出・初期スキャンが見つけた**別人**の顔が入っている
    /// ことがある。`store` で置き換えると、その別人の顔がキャッシュから消え、
    /// 「隠したかった人はモザイクが掛かるが、たまたま同じバケットにいた別の人の
    /// モザイクが消える」という、プライバシーアプリとしては最悪の方向（露出が増える）
    /// に逆流する。既存を読んでから合成し直す＝「マージ」でなければならない。
    ///
    /// - Parameter sourceID: nil（写真モード・素材ID解決不能）なら何もしない。
    ///   写真モードは `detectedFaces` 側の絞り込みだけで完結し、検出キャッシュの
    ///   概念自体が無い（`FaceTarget.sourceID` の doc 参照）。
    /// - Parameter sourceTime: **素材内時刻**（合成時刻ではない）。呼び出し側で
    ///   丸めないこと——バケットへの丸めは `DetectionCacheKey.init` に一本化してある
    ///   （呼び出し側がバラバラに丸めるとプリスキャン/ライブ検出でキーが分裂した
    ///   過去の回帰と同じ事故になる。`storePreScanResult` の doc 参照）。
    ///   ここでは丸めの**前**の処理として `TimelineState.clampedSourceTime` だけを通す
    ///   （写真クリップの素材時刻を 0 へ畳む。動画では実質恒等）。
    func mergeDetection(_ faces: [FaceLandmarkSet], sourceID: UUID?, sourceTime: Double) {
        guard let sourceID else { return }
        let clampedTime = timeline.clampedSourceTime(sourceTime, sourceID: sourceID)
        let existing = cacheStore.faces(sourceID: sourceID, time: clampedTime) ?? []
        // 重複判定は「別人と言い切れるか」の逆（＝同一人物とみなせるか）を
        // bbox IoU で見る既存ロジック（`DetectionBridge` が時系列補間の対応判定に
        // 使っているのと同じ `FaceLandmarkSet.hasCounterpart`、閾値 0.3）をそのまま
        // 再利用する。式を二重管理しない（このプロジェクトの規約）。
        let newOnes = faces.filter { !$0.hasCounterpart(in: existing) }
        guard !newOnes.isEmpty else { return }
        cacheStore.store(existing + newOnes, sourceID: sourceID, time: clampedTime)
    }
}

#endif
