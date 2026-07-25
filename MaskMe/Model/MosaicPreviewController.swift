import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import MosaicCore

#if canImport(Metal)
import Metal

/// 動画のリアルタイムモザイクプレビューを駆動する。
/// AVPlayer + AVPlayerItemVideoOutput + CADisplayLink を組み合わせ、
/// フレームごとに Metal レンダリングして model.previewImage を更新する。
@MainActor
final class MosaicPreviewController {
    private let renderer: MosaicRenderer
    private weak var model: MosaicEditorModel?

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var displayLink: CADisplayLink?
    private let ciContext: CIContext
    #if canImport(Vision)
    private let segmenter = PersonSegmenter(quality: .balanced)
    #endif
    /// 背景マスクのキャッシュ。Vision は重いので毎フレームではなく一定間隔で更新する。
    private var cachedBackgroundMask: MaskBuffer?
    private var framesUntilResegment = 0
    /// 背景マスクの再セグメント間隔（フレーム数）。30fps で約 5fps 相当。
    private let backgroundSegmentInterval = 6
    /// 描画直前のランドマーク EMA（フレーム間の微小ちらつき吸収）。検出キャッシュには
    /// 適用しない。シーク時は状態を捨てる。
    private let landmarkSmoother = LandmarkSmoother()
    /// 直前に描画したフレームが属するクリップ。境界跨ぎの時系列リセット判定に使う
    /// （`resetTimeSeriesStateIfClipChanged` 参照）。シーク・item 差し替えで nil に戻す。
    private var lastRenderedClipID: UUID?
    /// 直前のフレームがトランジションの重なり区間だったか（S8）。
    /// 重なり中は EMA を素通しにし、抜けた最初のフレームで状態を捨てる。
    private var wasInTransition = false
    /// 再生アイテムに装着する映像合成 / 音声ミックス（S8）。item を作り直しても
    /// 落ちないよう、asset と組で保持して `makePlayerItem` が毎回付け直す。
    private var videoComposition: AVVideoComposition?
    private var audioMix: AVAudioMix?

    private(set) var duration: Double = 0
    /// DEBUG 診断用: copyPixelBuffer が nil を返した累計（間引きログの分母）。
    private var pixelBufferMissCount = 0

    /// - Parameters:
    ///   - asset: 合成済みの `AVMutableComposition` を受け取る。
    ///     URL ではなく AVAsset を受けることで、クリップ編集の結果をそのまま再生できる。
    ///   - videoComposition: トランジション・rate≠1・フォーマット混在のときだけ非 nil（S8）。
    ///   - audioMix: 音声クロスフェード・音量調整があるときだけ非 nil（S8）。
    init(renderer: MosaicRenderer, asset: AVAsset, model: MosaicEditorModel,
         videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil) {
        self.renderer = renderer
        self.model = model
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.ciContext = CIContext(mtlDevice: renderer.device, options: [.useSoftwareRenderer: false])

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &cache)
        self.textureCache = cache

        setupPlayer(asset)
    }

    private static let outputPixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    /// asset から再生用の AVPlayerItem を作り、フレーム出力と再生終了監視を結線する。
    /// `videoOutput` は item と 1:1 なので毎回作り直して差し替える。
    ///
    /// ピッチ保持（S7）と映像合成 / 音声ミックスの装着（S8）もここで設定する。
    /// いずれも item 単位のプロパティなので、タイムライン編集のたびに composition を
    /// 差し替えても設定が落ちないよう「item を作る 1 箇所」に置くこと
    /// （`setupPlayer` と `replaceAsset` の共通経路）。
    private func makePlayerItem(for asset: AVAsset) -> AVPlayerItem {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.outputPixelBufferAttributes)
        self.videoOutput = output

        let item = AVPlayerItem(asset: asset)
        // rate≠1 クリップ（scaleTimeRange 済みの scaled audio edit）を音程を変えずに
        // 再生する。iOS 15 以降の既定は timeDomain（音声向けの中品質）なので明示する。
        // `.spectral` は 1/32〜32 倍に対応し、`TimelineClip.rateRange`（0.1〜10）を
        // 完全に含む。書き出し側（AVAssetReaderAudioMixOutput）と同じ設定に揃えることで、
        // プレビューと書き出しで音程が食い違わない。
        item.audioTimePitchAlgorithm = .spectral
        // トランジション合成・レターボックス（S8）。無変換構成では nil のままで、
        // 従来どおり素の composition をそのまま再生する。
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.add(output)

        // 再生終了を監視（item 単位。差し替え時は旧 item の監視を外して付け替える）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        return item
    }

    private func setupPlayer(_ asset: AVAsset) {
        let item = makePlayerItem(for: asset)
        self.player = AVPlayer(playerItem: item)

        // 尺を非同期で取得
        Task {
            let d = try? await item.asset.load(.duration)
            self.duration = d?.seconds ?? 0
        }
    }

    /// タイムライン編集後の再構築で、再生中の asset（Composition）を差し替える。
    ///
    /// - DidPlayToEnd オブザーバは item 単位の登録なので、旧 item から外して
    ///   新 item へ付け替える（付け替えないと旧 item の終了通知を拾い損ね、
    ///   新 item の終了で `isPlaying` が戻らなくなる）。
    /// - 旧タイムラインの時系列状態（EMA・背景マスク・クリップ追跡・ライブ追跡）は
    ///   すべて無効になるため破棄する。
    /// - 再生位置の復元は呼び出し側（`MosaicEditorModel.rebuildComposition`）が
    ///   新しい合成尺へのクランプ込みで行う。
    func replaceAsset(_ asset: AVAsset,
                      videoComposition: AVVideoComposition? = nil,
                      audioMix: AVAudioMix? = nil) async {
        // item 差し替えは新しい composition のデコードを開始させる。サムネイル生成と
        // 重ねないよう占有を宣言する（`MosaicEditorModel.isPreviewDecodeBusy`）。
        // 早期 return でも必ず下がるよう defer で対にする。
        model?.beginPreviewDecode()
        defer { model?.endPreviewDecode() }
        guard let player else { return }
        if let oldItem = player.currentItem {
            NotificationCenter.default.removeObserver(
                self, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        }
        // asset と装着物は必ず組で差し替える（旧 composition に新 instruction を
        // 掛ける不整合を作らない）。
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        let item = makePlayerItem(for: asset)
        player.replaceCurrentItem(with: item)

        cachedBackgroundMask = nil
        framesUntilResegment = 0
        landmarkSmoother.reset()
        lastRenderedClipID = nil
        wasInTransition = false
        model?.notifyLiveSeek()

        // seek が新しい尺で計算できるよう、差し替え完了までに尺を取り直す。
        let d = try? await item.asset.load(.duration)
        self.duration = d?.seconds ?? 0
    }

    // MARK: - 再生制御

    func play() {
        player?.play()
        startDisplayLink()
    }

    func pause() {
        player?.pause()
        stopDisplayLink()
    }

    func seek(to position: Double) async {
        // zero-tolerance seek は直近キーフレームからのデコードを強制する。
        // サムネイル生成と重ねないよう占有を宣言する（早期 return でも defer で下がる）。
        model?.beginPreviewDecode()
        defer { model?.endPreviewDecode() }
        guard let player, duration > 0 else { return }
        let sec = position * duration
        let time = CMTime(seconds: sec, preferredTimescale: 600)
        // シーク先では古い背景マスクを使わない
        cachedBackgroundMask = nil
        framesUntilResegment = 0
        // シーク先では前位置の EMA 状態も意味を持たない
        landmarkSmoother.reset()
        // クリップ追跡もシークで別時系列になる（次フレームで記録し直す）
        lastRenderedClipID = nil
        wasInTransition = false
        // ライブ検出の追跡状態（ROI track / フロー）もシーク先では別時系列になる
        model?.notifyLiveSeek()
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        renderCurrentFrame()
    }

    /// タイムライン・スクラブ用: 直前の未完了シークをキャンセルして最新要求のみ処理する。
    /// ドラッグ中に大量に発火する `seek(to:)` を直列化するとキューが詰まって
    /// プレビュー画像の反応が遅れるため、常に最新1件のみに絞る。
    private var pendingSeekTask: Task<Void, Never>?

    func seekLatest(to position: Double) {
        pendingSeekTask?.cancel()
        pendingSeekTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.seek(to: position)
        }
    }

    /// コントロール（blockSize など）が変化したときに現在フレームを再描画する。
    func invalidate() {
        renderCurrentFrame()
    }

    /// フレームが 1 枚も出ないまま諦めるまでのリトライ回数（約 30ms 間隔）。
    /// デコーダが最初のフレームを吐くまでの猶予であり、これを超えるのは
    /// 読み込み失敗と同義（暫定表示のまま残す）。
    private static let initialFrameRetryCount = 20

    /// ロード直後・下書き復元直後に、**現在の再生位置のフレームを必ず 1 枚描く**。
    ///
    /// 一般的な動画編集アプリと同じく「プロジェクトを開いた時点で、いまの編集状態どおりの
    /// 絵が出ている」状態にするための入口である。これが無いと、`MosaicEditorModel` の
    /// 同期 `renderPreview()`（素材の生フレームに対する暫定表示。合成もモザイク適用区間も
    /// 反映されない）が画面に残り続ける: displayLink は `play()` でしか回らないので、
    /// ユーザーが再生かシークをするまで一切描き直されない
    /// （実測: 下書き復元後 2 秒放置で `renderCurrentFrame` の実行回数 0、
    /// previewImage の中央画素は区間外なのに [127,127,127]＝モザイクのまま）。
    ///
    /// 尺のロードを待つのは `seek(to:)` が `duration > 0` を前提にするため
    /// （`setupPlayer` の尺取得は別 Task なので、ここへ来た時点では未完了のことがある）。
    /// シーク完了直後でも `AVPlayerItemVideoOutput` がまだフレームを持たないことがあるため、
    /// 1 枚描けるまで短い間隔で数回だけ再試行する。
    @discardableResult
    func renderInitialFrame(at position: Double) async -> Bool {
        if duration <= 0, let asset = player?.currentItem?.asset {
            duration = ((try? await asset.load(.duration))?.seconds) ?? 0
        }
        // zero-tolerance シークで「その位置のフレーム」を確定させてから描く
        // （再生・シーク経路とまったく同じ描画関数を通すので、初期表示だけ規則が
        // 違うということが起こらない）。
        await seek(to: position)
        if renderCurrentFrame() { return true }
        for _ in 0..<Self.initialFrameRetryCount {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if renderCurrentFrame() { return true }
        }
        return false
    }

    // MARK: - DisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        renderCurrentFrame()
    }

    @objc private func playerDidFinish() {
        model?.isPlaying = false
        stopDisplayLink()
    }

    // MARK: - レンダリング

    /// 現在フレームを 1 枚描いて `model.previewImage` を更新する。
    /// - Returns: 実際に `previewImage` を更新できたか（フレームが取れない・
    ///   Metal の途中経路が失敗した場合は false）。`renderInitialFrame(at:)` が
    ///   「暫定表示を上書きできたか」の判定に使う。
    @discardableResult
    private func renderCurrentFrame() -> Bool {
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

        // 720px 幅に縮小してから Metal 処理（GPU→CPU 転送量を削減）
        let maxWidth = 720
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
            model.submitPreviewFrameForDetection(detImage, at: timeSec)
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
        if duration > 0 {
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

    deinit {
        displayLink?.invalidate()
    }
}
#endif
