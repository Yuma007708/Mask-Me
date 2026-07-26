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
                $0.appending(clip: clip, source: TimelineSource(id: sourceID, kind: .photo))
            }
        } catch {
            errorMessage = "写真の追加に失敗しました"
        }
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
        detectedFaces += faces.map { lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: normalizedImage),
                       isSelected: true, sourceID: sourceID)
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
        seedVideoDetection(asset: asset, sourceID: sourceID)
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: rawSeconds)
        applyTimelineEdit {
            $0.appending(clip: clip, source: TimelineSource(id: sourceID, kind: .video))
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
    private func seedVideoDetection(asset: AVAsset, sourceID: UUID) {
        guard let firstFrame = MosaicEditorModel.firstFrame(of: asset) else { return }
        let scan = scanSeedFaces(of: asset, firstFrame: firstFrame)
        guard !scan.faces.isEmpty else { return }
        // 実際に顔が写っていた素材時刻のバケットへ入れる（load と同じ理由。
        // seedTime>0 の結果を t=0 に入れると、顔がまだ無い冒頭フレームの体や背景に
        // モザイクが乗る）。空結果を記録しないのも load と同じ
        // （t=0 に顔が無い事実はライブ検出が空エントリとして記録する）。
        cacheStore.store(scan.faces, sourceID: sourceID, time: scan.time)
        detectedFaces += scan.faces.map { lm in
            FaceTarget(id: UUID(), landmarks: lm,
                       thumbnail: generateThumbnail(for: lm, from: scan.frame),
                       isSelected: true, sourceID: sourceID)
        }
    }
}

#endif
