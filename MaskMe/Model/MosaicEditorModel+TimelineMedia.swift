import AVFoundation
import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// `MosaicEditorModel` の「素材をタイムライン末尾へ追加する」経路（写真 S6 / 動画 S10a）。
///
/// 骨格は写真・動画で共通（`sources` 登録 → 検出シード → `TimelineState.appending` →
/// 世代トークン付き rebuild → `commitEdit`）で、クリップ編集そのもの
/// （`MosaicEditorModel+Timeline.swift`）とは変更理由が別なのでファイルを分けてある。
extension MosaicEditorModel {
    // MARK: - 写真クリップ（S6）

    /// 写真を静止 mp4 へエンコードし、タイムライン末尾へクリップとして追加する。
    ///
    /// `PhotoClipEncoder`（15fps・上限 60s クランプ・長辺 1920px・EXIF 正規化済み）で
    /// 事前エンコードした mp4 を既存の「動画素材を追加」経路へ無分岐で合流させる:
    /// `sources` 登録 → `TimelineState.appending`（kind = .photo の素材メタ付き）→
    /// 世代トークン付き rebuild → `commitEdit`。下書き保存（`draftSources`）と
    /// undo/redo（EditSnapshot の timeline）は既存機構がそのまま追随する。
    ///
    /// **S8 で解像度・向きの混在を正式解禁した**ため、追加前の照合
    /// （旧 `photoFormatMatchesTimeline`）は廃止した。混在するタイムラインは
    /// `AVVideoComposition` が renderSize へアスペクトフィットで揃えて合成し、
    /// 顔座標も同じ配置計算（`TimelineRenderLayout`）で合成フレーム基準へ写される。
    ///
    /// 検出は写真の全フレームが同一なので素材時刻 t=0 に 1 回だけ seed する。
    /// 以後の lookup・ライブ検出は `resolveSourceTime` の clamp（写真素材 → 素材時刻 0）
    /// でこの seed にヒットし、写真区間で 2 回目以降の実検出・重複 submit は走らない。
    ///
    /// **素材は既定尺より長く（`PhotoClipEncoder.clipCapacitySeconds`）エンコードし、
    /// クリップの `sourceEnd` だけを既定尺にする。** トリムは `sourceEnd` を素材尺までしか
    /// 伸ばせないので、素材を既定尺ちょうどで作ると「追加後に 3 秒より長くできない」
    /// 制約になるため。長 GOP により素材尺を伸ばしてもファイルサイズはほぼ増えない
    /// （`PhotoClipEncoder.clipCapacitySeconds` の doc 参照）。
    ///
    /// - Parameter seconds: 追加直後のクリップの尺（秒）。既定は
    ///   `PhotoClipEncoder.defaultClipSeconds`（UI に尺の選択肢は無く、追加後に
    ///   クリップ端のトリムで capacity まで伸ばせる）。素材尺を超える指定は
    ///   素材尺へクランプされる。
    public func appendPhotoClip(image: UIImage,
                                seconds: Double = PhotoClipEncoder.defaultClipSeconds) async {
        // クリップ未構築（動画ロード完了前・写真モード）では追加先のタイムラインが無い。
        // 書き出しと同じく、ユーザーが結果を待つ操作なので黙って no-op にしない。
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してから写真を追加してください"
            return
        }
        do {
            let encoded = try await PhotoClipEncoder()
                .encode(image: image, seconds: PhotoClipEncoder.clipCapacitySeconds)
            // load / 復元経路と同じく AVURLAsset として登録する（draftSources が
            // URL を取り出して下書きへコピーできる形）。
            let photoAsset = AVAsset(url: encoded.url)
            let sourceID = UUID()
            sources[sourceID] = photoAsset
            seedPhotoDetection(encoded.normalizedImage, sourceID: sourceID)
            // 壊れた指定（NaN・0 以下）は既定尺に落とす。min(NaN, _) は NaN を返すので
            // そのまま渡すと `appending` が使用範囲の検査で弾き、無言の no-op になる。
            let requested = seconds.isFinite && seconds > 0 ? seconds : PhotoClipEncoder.defaultClipSeconds
            let clip = TimelineClip(sourceID: sourceID, sourceStart: 0,
                                    sourceEnd: min(requested, encoded.duration))
            applyTimelineEdit {
                $0.appending(clip: clip, source: TimelineSource(id: sourceID, kind: .photo),
                             // **モザイクを使っている編集にだけ区間を足す。**
                             // 区間 0 本 = まだ何も掛けていない編集なので、素材を足した
                             // だけでレイヤーが生えては「新規ではレイヤーを出さない」を
                             // 素材追加で破ることになる（しかも足した素材にだけ掛かる）。
                             coveringWithApplyRange: !$0.applyRanges.isEmpty)
            }
        } catch {
            errorMessage = "写真の追加に失敗しました"
        }
    }

    // MARK: - シードした顔の人物同定

    /// 初期スキャンでシードした顔の人物 ID を決める（`faces` と同じ順・同じ件数）。
    ///
    /// **なぜシードの時点で測るのか**: ライブ検出は 0.5 秒間隔でしか署名を測らないので、
    /// 素材を開いた直後は人物 ID が 1 つも付いていない。下書きの顔選択は人物 ID で
    /// 結び直す（`DraftSelectionResolver`）ため、開いた瞬間に人物が分かっていないと
    /// 復元が位置照合まで落ち、外れれば安全側の全選択——つまり
    /// **「この人だけ隠す」という選択が再開のたびに失われる**。
    ///
    /// **`detectedFaces` へ載せる「前」に呼ぶこと。** 載せてから付け直す形にすると、
    /// `detectedFaces` の didSet が走る時点では人物 ID がまだ nil で、保留していた
    /// 下書きの目印（`applyPendingFaceSelectionAnchorsIfNeeded`）が人物照合を使えずに
    /// 位置照合だけで確定してしまう。その後に人物 ID を付けても、判定をやり直す機会は
    /// 二度と来ない。
    ///
    /// - Parameters:
    ///   - faces: シードした顔。
    ///   - image: `faces` の正規化座標が乗っているフレーム。
    ///   - sourceID: 素材ID。nil（写真モード）では署名を置き場へ入れず、人物 ID だけ決める。
    ///   - time: `cacheStore.store` に使ったのと**同じ素材時刻**。食い違うと顔は引けるのに
    ///     署名だけ引けない（`FaceSignatureCache` の doc）。
    @MainActor
    func seedPersonIDs(for faces: [FaceLandmarkSet], in image: UIImage,
                       sourceID: UUID?, time: Double) -> [UUID?] {
        guard !faces.isEmpty, FaceSignatureProvider.shared.isAvailable else {
            return [UUID?](repeating: nil, count: faces.count)
        }
        let signatures = FaceSignatureProvider.shared.signatures(for: faces, in: image)
        if let sourceID {
            signatureCache.store(signatures, for: faces, sourceID: sourceID, time: time)
            // 直後のライブ検出が同じ顔をもう一度測らないよう、間引きの時計も進めておく。
            lastSignatureSourceTime[sourceID] = time
        }
        // 新しいターゲットなので `register` に判断させる（既存人物と `match` 以上で
        // 似ていればその ID＝下書きから復元した人物 ID が返る）。判断保留の帯では
        // nil のままで、判定は位置追跡と安全側へ委ねられる。
        return signatures.map { $0.flatMap { personRegistry.register($0) } }
    }

    // MARK: - 人物署名（ライブ検出から遅れて届く分）

    /// 「この合成時刻のフレームで署名を計算してよいか」を判定し、可ならスロットを消費する。
    ///
    /// 間引きは**素材時刻**で見る（合成時刻で見ると rate≠1 のとき素材上の間隔が変わり、
    /// 0.1x では同じ顔の署名ばかり、10x では滅多に取れないという偏りが出る）。
    /// 消費は判定と同時に行う（判定だけして後で消費すると、in-flight の間に
    /// 次のフレームも通ってしまう）。
    func beginSignatureIntervalIfDue(atComposition timeSec: Double) -> Bool {
        guard FaceSignatureProvider.shared.isAvailable else { return false }
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: timeSec)
        if let last = lastSignatureSourceTime[sourceID],
           abs(sourceTime - last) < signatureIntervalSec {
            return false
        }
        lastSignatureSourceTime[sourceID] = sourceTime
        return true
    }

    /// 検出より**遅れて届いた**署名を、その検出と同じ素材キーへ書く（`liveSignatureQueue`）。
    ///
    /// 検出本体と別の呼び出しになっても取り違えが起きないのは、`FaceSignatureCache` が
    /// 顔と署名を**重心の位置**で結ぶため（添字ではない）。`faces` は署名を計算したときの
    /// 検出結果そのものを渡すこと——別のフレームの顔列を渡すと、位置照合が近い顔に
    /// 引っかかって**別人の署名で判定する**。
    ///
    /// 世代が変わっていたら捨てる（旧タイムラインの合成時刻を新しい写像で解釈すると
    /// 誤った素材キーに落ちる。`storeLiveDetection(_:at:source:signatures:generation:)` と同じ理由）。
    /// **`liveDetectionInFlight` は触らない**——検出側が既に下ろしており、ここで
    /// もう一度触ると進行中の別フレームの検出ガードを誤って解除する。
    ///
    /// - Parameter frame: 検出に使ったフレーム（`signatureSource` の原寸ではない）。
    ///   途中から現れた人物を自動追加する経路（`admitEmergingPersons`）が、
    ///   確定した顔のサムネイルをこのフレームから作るために使う。
    @MainActor
    func storeLiveSignatures(_ signatures: [FaceSignature?], for faces: [FaceLandmarkSet],
                             at t: Double, frame: UIImage, generation: Int) {
        guard generation == timelineGeneration else { return }
        let (sourceID, sourceTime) = resolveSourceTime(atComposition: t)
        signatureCache.store(signatures, for: faces, sourceID: sourceID, time: sourceTime)
        admitEmergingPersons(faces: faces, signatures: signatures,
                             sourceID: sourceID, sourceTime: sourceTime, frame: frame)
    }

    /// 写真クリップの検出 seed（素材時刻 t=0 の 1 回だけ）。
    ///
    /// ライブ検出・初期スキャンと同じ縮小幅（`downscaleForDetection`）で検出する。
    /// 空結果も記録する: 「スキャン済みで顔なし」の事実が
    /// `shouldDetectPreviewFrame` の再検出とホールドフォールバックの貼り付きを止める
    /// （ライブ検出の空エントリと同じ意味論）。
    private func seedPhotoDetection(_ normalizedImage: UIImage, sourceID: UUID) {
        let scanner = makeFaceLandmarker(forVideo: false, settings: detectionSettings)
        let faces = scanner.allLandmarks(in: Self.downscaleForDetection(normalizedImage))
        cacheStore.store(faces, sourceID: sourceID, time: 0)
        guard !faces.isEmpty else { return }
        // 写真を追加する意図は「この顔にモザイクを掛けたい」なので即選択する
        // （detectInRegion と同じ理由。未選択のままだと写真区間だけモザイクが乗らない）。
        let personIDs = seedPersonIDs(for: faces, in: normalizedImage, sourceID: sourceID, time: 0)
        detectedFaces += faces.enumerated().map { idx, lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalizedImage),
                       isSelected: true, sourceID: sourceID, personID: personIDs[idx])
        }
    }

    // MARK: - 動画クリップ（S10a）

    /// 動画をタイムライン末尾へクリップとして追加する（複数素材の結合の入口）。
    ///
    /// `appendPhotoClip(image:seconds:)` と対になる公開 API で、骨格は同じ:
    /// `sources` 登録 → 検出シード → `TimelineState.appending`（kind = .video）→
    /// 世代トークン付き rebuild → `commitEdit`。下書き保存（`draftSources`）と
    /// undo/redo（EditSnapshot の timeline）は既存機構がそのまま追随する。
    ///
    /// **解像度・向きの混在は S8 で正式解禁済み**なので、追加前に元素材と照合しない。
    /// 混在するタイムラインは `AVVideoComposition` が renderSize へアスペクトフィットで
    /// 揃えて合成し、顔座標も同じ配置計算（`TimelineRenderLayout`）で写される。
    public func appendVideoClip(url: URL) async {
        // クリップ未構築（動画ロード完了前・写真モード）では追加先のタイムラインが無い。
        // 書き出しと同じく、ユーザーが結果を待つ操作なので黙って no-op にしない。
        guard mode == .video, !timeline.clips.isEmpty else {
            errorMessage = "動画の読み込みが完了してから動画を追加してください"
            return
        }
        // load / 復元経路と同じく AVURLAsset として登録する（draftSources が
        // URL を取り出して下書きへコピーできる形）。
        let asset = AVAsset(url: url)
        let rawSeconds = (try? await asset.load(.duration))?.seconds ?? .nan
        guard rawSeconds.isFinite, rawSeconds > 0 else {
            errorMessage = "動画の追加に失敗しました"
            return
        }
        let sourceID = UUID()
        sources[sourceID] = asset
        await seedVideoDetection(asset: asset, sourceID: sourceID)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: rawSeconds)
        applyTimelineEdit {
            // 区間を足すのは「既にモザイクを使っている編集」のときだけ
            // （`appendPhotoClip` と同じ理由。あちらの doc 参照）。
            $0.appending(clip: clip, source: TimelineSource(id: sourceID, kind: .video),
                         coveringWithApplyRange: !$0.applyRanges.isEmpty)
        }
    }

    /// 追加した動画クリップの検出シード（`load(videoURL:)` の初期スキャンと同じ流儀）。
    ///
    /// 検出条件（IMAGE モード・480px 縮小・顔が写るまでの probe）は `scanSeedFaces`
    /// を共有するので load 経路と一致する。結果は**素材基準キー**で `detectionCache`
    /// （`cacheStore`）へ入れる。オプティカルフロー由来ではない実検出なので
    /// `liveFlowCache` とは混ぜない。
    ///
    /// `detectedFaces` は**置き換えず追記**する（追加であって読み込みではない。
    /// 置き換えると既存クリップの顔選択が丸ごと消え、そちらのモザイクが外れる）。
    ///
    /// **自動選択は「検出した顔すべて」**（`seedPhotoDetection` と同じ）。
    /// `load` 側は「顔が 1 つのときだけ自動選択」だが、あれは編集セッションの開始時
    /// ＝ユーザーの意図がまだ無く、サムネで選ばせる余地がある状況の規則である。
    /// 追加素材は事情が違う: 顔の照合は素材スコープ
    /// （`selecting(_:sourceID:targets:)` は当該素材に属する選択顔だけを見る）なので、
    /// 新素材の顔が 1 つも選択されていないと**その追加クリップの区間だけモザイクが
    /// 乗らない**。写真追加が即選択している理由がそのまま当てはまるため、同じ扱いにする
    /// （掛けたくない顔はサムネのタップで外せる。逆は「気づかず素顔が残る」になる）。
    private func seedVideoDetection(asset: AVAsset, sourceID: UUID) async {
        guard let firstFrame = MosaicEditorModel.firstFrame(of: asset) else { return }
        let scan = await scanSeedFaces(of: asset, firstFrame: firstFrame)
        guard !scan.faces.isEmpty else { return }
        // 実際に顔が写っていた素材時刻のバケットへ入れる（load と同じ理由。
        // seedTime>0 の結果を t=0 に入れると、顔がまだ無い冒頭フレームの体や背景に
        // モザイクが乗る）。空結果を記録しないのも load と同じ
        // （t=0 に顔が無い事実はライブ検出が空エントリとして記録する）。
        cacheStore.store(scan.faces, sourceID: sourceID, time: scan.time)
        let personIDs = seedPersonIDs(for: scan.faces, in: scan.frame,
                                      sourceID: sourceID, time: scan.time)
        detectedFaces += scan.faces.enumerated().map { idx, lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: scan.frame),
                       isSelected: true, sourceID: sourceID, personID: personIDs[idx])
        }
    }
}

#endif
