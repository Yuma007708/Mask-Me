import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// プレビュー 1 フレームの描画経路（フレーム取り出し → 720px 縮小 → Metal →
/// `model.previewImage` 更新）と、その周辺（背景モザイク・描画用ランドマーク・
/// クリップ境界での時系列状態リセット・ライブ検出用の縮小画像）。
///
/// 再生制御と DisplayLink（`MosaicPreviewController.swift`）とは変更理由が別なので
/// 切り出してある。
extension MosaicPreviewController {
    // MARK: - レンダリング

    /// 現在フレームを 1 枚描いて `model.previewImage` を更新する。
    /// - Returns: 実際に `previewImage` を更新できたか（フレームが取れない・
    ///   Metal の途中経路が失敗した場合は false）。`renderInitialFrame(at:)` が
    ///   「暫定表示を上書きできたか」の判定に使う。
    @discardableResult
    func renderCurrentFrame() -> Bool {
        guard let player,
              let videoOutput,
              let model,
              let cache = textureCache else { return false }
        // フレーム取り出し + Metal 描画の間は GPU / デコーダを占有する。
        // 再生中は 30fps で立ち上げ下げを繰り返すため、通知は @Published ではなく
        // コールバック 1 本（`MosaicEditorModel.onPreviewDecodeBusyChanged`）で受ける。
        model.beginPreviewDecode()
        defer { model.endPreviewDecode() }

        let currentTime = player.currentTime()
        // `copyPixelBuffer(forItemTime:)` は要求時刻に最も近いフレームを返すだけで、
        // 実際に返ってきたフレームの時刻は内部バッファリング次第（1〜3 フレーム遅延しうる）。
        // 第 2 引数で実フレーム時刻を受け取り、landmarks の検索もそれに揃えると一拍遅れが消える。
        var actualItemTime = CMTime()
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: currentTime,
            itemTimeForDisplay: &actualItemTime
        ) else {
            #if DEBUG
            // 実機デバッグ用: 出力がフレームを返さないとプレビュー更新もライブ検出も
            // 止まる（映像フリーズ/モザイク不掲載の一次原因になりうる）。連発するので間引く。
            pixelBufferMissCount += 1
            if pixelBufferMissCount % 30 == 1 {
                print("[MMLIVE] copyPixelBuffer=nil count=\(pixelBufferMissCount) "
                      + "t=\(String(format: "%.2f", currentTime.seconds))")
            }
            #endif
            return false
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)

        // 720px 幅に縮小してから Metal 処理（GPU→CPU 転送量を削減）。
        // この幅は粗さスライダーの基準幅（`MosaicRenderer.referenceFrameWidth`）と
        // **同じ値でなければならない**: 背景モザイク・手動矩形のブロックは
        // 基準幅に対する相対値として解決されるため（`MosaicRenderer.effectiveBlock`）、
        // ここだけ別の値にするとプレビューと書き出しで粗さが食い違う。
        let maxWidth = Int(MosaicRenderer.referenceFrameWidth)
        let scale = min(Double(maxWidth) / Double(bufferWidth), 1.0)

        let inputTex: MTLTexture?
        if scale < 0.99 {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                inputTex = try? MetalTextureUtilities.texture(from: cg, device: renderer.device)
            } else {
                inputTex = nil
            }
        } else {
            inputTex = MetalTextureUtilities.texture(from: pixelBuffer, cache: cache)
        }

        guard let tex = inputTex else { return false }

        // 描画中のフレームの実際の時刻（理想時刻ではなく）で landmarks を引く。
        // これにより「顔の動きにモザイクが一拍遅れる」現象を解消する。
        // timeSec は AVPlayerItem＝Composition の**合成タイムライン時刻**。
        // 素材ID・素材時刻への写像は model 側（resolveSourceTime）が一手に担うため、
        // プレビューは素材時刻を一切仮定せず、合成時刻のまま検出 submit と
        // ランドマーク検索（selectedLandmarks）に渡す。
        let timeSec = actualItemTime.isValid ? actualItemTime.seconds : currentTime.seconds
        // クリップ境界を跨いだフレームでは時系列状態をリセットする（S4）。
        resetTimeSeriesStateIfClipChanged(at: timeSec, model: model)
        // 事前スキャン廃止: 再生・シークで表示中のこのフレームに顔検出を相乗りさせ、
        // detectionCache を埋める。表示スレッドを塞がないよう、検出すべきときだけ
        // 縮小 CGImage を作ってモデルへ渡す（モデル側でバックグラウンド検出）。
        if model.shouldDetectPreviewFrame(at: timeSec),
           let detImage = detectionCGImage(from: pixelBuffer) {
            // 署名（人物同定）だけは原寸から測る。縮小画像から測ると
            // `FaceSignatureQuality.minimumFacePixelWidth` で実素材が軒並み落ちる
            // （submitPreviewFrameForDetection の doc に実測値）。
            // クロージャなので**署名を測るフレームだけ**原寸変換が走る。
            model.submitPreviewFrameForDetection(detImage, at: timeSec) { [weak self] in
                self?.signatureCGImage(from: pixelBuffer)
            }
        }
        // モザイク適用区間ゲート（S10）。素材アンカーを持たない効果——手動矩形と
        // 背景モザイク——は「この合成時刻に映っている素材のどれかが区間内か」で決める
        // （エクスポートと同じ `MosaicApplyGate.isActive(ranges:mapping:compositionTime:)`）。
        // 顔ランドマークはここでは触らない: `displayFaces(at:matching:)` の中で
        // **素材別に**ゲート済みだからである（重なり区間で片方だけ ON にできる）。
        // 判定時刻は landmarks 検索と同じ timeSec（＝実フレームの合成時刻）を使う。
        // 別の時刻を渡すと境界フレームでモザイクの ON/OFF が 1 フレームずれる。
        let mosaicActive = model.isMosaicActive(atComposition: timeSec)
        let landmarks = landmarksForRendering(at: timeSec, model: model)
        // 手動矩形は顔検出の補助なので顔タブ（faceMosaicOn）の状態に従う。
        // 解像度は（縮小後の）実テクスチャに合わせる（フルサイズだと 720px 縮小時に位置がずれる）。
        let additionalPaths = model.faceMosaicOn && mosaicActive
            ? model.manualRegionPaths(for: CGSize(width: tex.width, height: tex.height))
            : []

        guard let result = renderer.renderToNewTexture(
            input: tex,
            landmarkSets: landmarks,
            additionalPaths: additionalPaths
        ) else { return false }

        let finalTexture = backgroundMosaicApplied(to: result.texture, pixelBuffer: pixelBuffer,
                                                   model: model, mosaicActive: mosaicActive)

        guard let cgImage = MetalTextureUtilities.cgImage(from: finalTexture) else { return false }
        let uiImage = UIImage(cgImage: cgImage)

        model.previewImage = uiImage
        // 再生位置の書き戻しは**タイムラインを指で操作していないときだけ**。
        //
        // `timeSec` は要求した時刻ではなく**実際に描けたフレームの時刻**なので、
        // フレーム格子へ量子化され 1〜3 コマ遅れることもある（上の doc 参照）。
        // スクラブ中に書き戻すと、タイムラインが「中央 = 再生位置」へ寄せ直す →
        // `scrollTo` の着地誤差ぶんシークが走る → また丸められる、が閉じずに回り続け、
        // クリップが左右に動いて止まらなくなる（ユーザー報告）。
        // 操作中の所有者はタイムライン側（`MosaicEditorModel.isTimelineScrubbing`）。
        if duration > 0, !model.isTimelineScrubbing {
            model.playbackPosition = max(0, min(timeSec / duration, 1))
        }
        return true
    }

    /// 背景モザイク（平面）を重ねたテクスチャを返す。掛からない場合は入力をそのまま返す。
    ///
    /// 人物前景を反転したマスクで背景だけを処理する。Vision は重いため毎フレームではなく
    /// `backgroundSegmentInterval` ごとに再計算し、間のフレームはキャッシュ済みマスクを
    /// 再利用する。
    ///
    /// **適用区間外（`mosaicActive == false`）では背景モザイクも掛けない**（S10）。
    /// 「区間外は素の映像」が要件なので、顔だけ止めて背景が残るのは誤り。
    /// セグメンテーション自体も走らないので、区間外での無駄な重い処理も無い。
    private func backgroundMosaicApplied(to texture: MTLTexture,
                                         pixelBuffer: CVPixelBuffer,
                                         model: MosaicEditorModel,
                                         mosaicActive: Bool) -> MTLTexture {
        guard mosaicActive else {
            // 区間外の間に持ち越したマスクは、区間へ戻ったときには別時刻・別クリップの
            // ものになっている。クリップ境界跨ぎ（resetTimeSeriesStateIfClipChanged）と
            // 同じ理由で捨て、再入した最初のフレームで必ず引き直す。
            cachedBackgroundMask = nil
            framesUntilResegment = 0
            return texture
        }
        guard model.backgroundMosaicOn else { return texture }
        #if canImport(Vision)
        if framesUntilResegment <= 0 || cachedBackgroundMask == nil {
            cachedBackgroundMask = segmenter.backgroundMask(pixelBuffer: pixelBuffer)
            framesUntilResegment = backgroundSegmentInterval
        } else {
            framesUntilResegment -= 1
        }
        guard let mask = cachedBackgroundMask,
              let out = renderer.renderBackgroundToNewTexture(
                  input: texture, mask: mask, block: model.backgroundBlockSize
              ) else { return texture }
        return out
        #else
        return texture
        #endif
    }

    /// 描画に使う顔ランドマーク（合成フレーム基準）を返す。
    ///
    /// 顔タブが OFF のときは顔ランドマークを使わない。
    /// 検出キャッシュ欠落時の freeze はしない。`lookupFaces` 側で両側マッチング補間が
    /// 連続する顔だけ返すようにしているため、ここで freeze するとアウト→イン時に
    /// 「アウト位置にモザイクが固定」され、かつエクスポートと挙動が食い違う。
    /// 描画直前の EMA でフレーム間の微小ちらつきを吸収する（速い動きはスナップ）。
    ///
    /// **トランジションの重なり中（S8）は EMA を素通しにする**: 2 クリップぶんの顔が
    /// 並ぶうえ、スライドでは全点が高速に移動するため、時系列平滑をかけると位置が
    /// 遅れてモザイクがずれる。重なりを抜けた最初のフレームで状態を捨ててから
    /// 通常運転に戻す。
    private func landmarksForRendering(at timeSec: Double,
                                       model: MosaicEditorModel) -> [FaceLandmarkSet] {
        let inTransition = model.mapping.sourceLocations(at: timeSec).count >= 2
        if wasInTransition, !inTransition { landmarkSmoother.reset() }
        wasInTransition = inTransition
        guard model.faceMosaicOn else { return [] }
        let selected = model.selectedLandmarks(at: timeSec)
        return inTransition ? selected : landmarkSmoother.smooth(selected)
    }

    /// 直前フレームと異なるクリップに入っていたら、時系列前提の状態をすべて捨てる。
    ///
    /// 合成タイムライン上は連続した時刻でも、クリップ境界では映像内容が不連続になる
    /// （別素材・同一素材の離れた区間・並べ替え）。前クリップの EMA・背景マスク・
    /// ライブ追跡（ROI track / フロー）を持ち越すと、境界直後のフレームに前クリップの
    /// 顔位置・マスクがにじむ。単一クリップでは clipID が変わらないため無影響。
    ///
    /// **重なり区間でも `sourceLocation(at:)`（incoming 側の単一位置）でよい**（S8）:
    /// 重なりの開始 = incoming への切り替わりでちょうど 1 回リセットされ、重なり中は
    /// clipID が変わらないので毎フレームの無駄なリセットにならない。重なり中に
    /// 両クリップの顔が要るのは描画側だけで、そちらは `selectedLandmarks` が
    /// `sourceLocations(at:)` で union している。
    private func resetTimeSeriesStateIfClipChanged(at timeSec: Double, model: MosaicEditorModel) {
        let clipID = model.mapping.sourceLocation(at: timeSec)?.clipID
        guard clipID != lastRenderedClipID else { return }
        let crossedBoundary = lastRenderedClipID != nil
        lastRenderedClipID = clipID
        guard crossedBoundary else { return }
        landmarkSmoother.reset()
        cachedBackgroundMask = nil
        framesUntilResegment = 0
        model.notifyLiveSeek()
    }

    /// ライブ検出用に pixelBuffer を最大 `MosaicEditorModel.liveDetectionTargetWidth` px
    /// 幅へ縮小した CGImage を作る。フル解像度より MediaPipe が速く回る。
    /// throttle 済みのフレーム（同時1枚）だけ変換されるので表示スレッドへの負荷は小さい。
    private func detectionCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let targetWidth = MosaicEditorModel.liveDetectionTargetWidth
        let scale = min(targetWidth / Double(width), 1.0)
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// 人物署名の切り出し元となる**原寸**フレーム。
    ///
    /// 検出用（`detectionCGImage`）と分けてあるのは、検出は速さのために縮小したいが
    /// 署名は解像度が要るため。`signatureIntervalSec`(0.5) で間引かれたフレームでしか
    /// 呼ばれないので、原寸変換のコストは 0.5 秒に 1 回に収まる。
    /// 呼び出しは `MosaicEditorModel.liveSignatureQueue` 上（描画スレッドでも検出キューでも
    /// ない。検出キューに乗せると検出スループットが落ちる）。`CIContext` はスレッド安全。
    ///
    /// buffer を非同期の先まで握れるのは、これが `copyPixelBuffer(forItemTime:)` の
    /// **所有権ごと渡された** buffer だから。キャプチャセッションのフレーム
    /// （`CameraMosaicPipeline`）はプールへ返す必要があるので同じことはしない。
    func signatureCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}
#endif
