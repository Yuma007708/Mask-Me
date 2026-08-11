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
    let renderer: MosaicRenderer
    weak var model: MosaicEditorModel?
    /// テキストのラスタライズ結果キャッシュ（E3-2）。`renderer.device` に紐づく。
    let textOverlayCache: TextOverlayCache

    var player: AVPlayer?
    var videoOutput: AVPlayerItemVideoOutput?
    var textureCache: CVMetalTextureCache?
    private var displayLink: CADisplayLink?
    let ciContext: CIContext
    #if canImport(Vision)
    let segmenter = PersonSegmenter(quality: .balanced)
    #endif
    /// 背景マスクのキャッシュ。Vision は重いので毎フレームではなく一定間隔で更新する。
    var cachedBackgroundMask: MaskBuffer?
    var framesUntilResegment = 0
    /// 背景マスクの再セグメント間隔（フレーム数）。30fps で約 5fps 相当。
    let backgroundSegmentInterval = 6
    /// 描画直前のランドマーク EMA（フレーム間の微小ちらつき吸収）。検出キャッシュには
    /// 適用しない。シーク時は状態を捨てる。
    let landmarkSmoother = LandmarkSmoother()
    /// 直前に描画したフレームが属するクリップ。境界跨ぎの時系列リセット判定に使う
    /// （`resetTimeSeriesStateIfClipChanged` 参照）。シーク・item 差し替えで nil に戻す。
    var lastRenderedClipID: UUID?
    /// 直前のフレームがトランジションの重なり区間だったか（S8）。
    /// 重なり中は EMA を素通しにし、抜けた最初のフレームで状態を捨てる。
    var wasInTransition = false
    /// 再生アイテムに装着する映像合成 / 音声ミックス（S8）。item を作り直しても
    /// 落ちないよう、asset と組で保持して `makePlayerItem` が毎回付け直す。
    private var videoComposition: AVVideoComposition?
    private var audioMix: AVAudioMix?
    /// 末尾まで再生し切ったか。AVPlayer は currentTime == duration のまま play() を呼んでも再生を
    /// 始めない（`actionAtItemEnd` の既定は `.pause`）ため、立っていたら `play()` が先頭へ戻す。
    private var hasReachedEnd = false

    private(set) var duration: Double = 0
    /// DEBUG 診断用: copyPixelBuffer が nil を返した累計（間引きログの分母）。
    var pixelBufferMissCount = 0

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
        self.textOverlayCache = TextOverlayCache(device: renderer.device)
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
        // 再生する。値は書き出しと共有の定数から引く（`AudioMixFactory.timePitchAlgorithm`
        // の doc に理由がある。ここへ直値を書き戻すと、片方だけ直したときに
        // プレビューと書き出しで音程が食い違う）。
        AudioMixFactory.applyTimePitch(to: item)
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

        resetPlaybackContinuityState()

        // seek が新しい尺で計算できるよう、差し替え完了までに尺を取り直す。
        let d = try? await item.asset.load(.duration)
        self.duration = d?.seconds ?? 0
    }

    // MARK: - 再生制御

    /// 末尾で押されたら先頭から再生し直す（一般的な動画編集アプリと同じ挙動）。末尾判定は
    /// 浮動小数の比較なので 1 フレーム分の許容を入れ、終了通知を取りこぼしても拾えるようにする。
    /// 先頭シークは完了を待たずに play() してよい（実測: AVPlayer が要求を直列化して rate=1 になる）。
    func play() {
        let atEnd = duration > 0 && (player?.currentTime().seconds ?? 0) >= duration - 1.0 / 30.0
        if hasReachedEnd || atEnd {
            pendingSeekTask?.cancel()  // 未完了のスクラブ要求が後から末尾へ引き戻すのを防ぐ
            resetPlaybackContinuityState()  // hasReachedEnd もここで下りる
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
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
        resetPlaybackContinuityState()
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
        hasReachedEnd = true
        stopDisplayLink()
    }

    /// 再生位置が不連続に変わるとき（シーク・composition 差し替え・末尾からの再生し直し）に捨てる
    /// 状態をまとめて落とす。EMA・背景マスク・クリップ追跡・ライブ追跡（ROI track / フロー）は
    /// 直前フレームの続きが前提で、「末尾に居る」主張の `hasReachedEnd` も同時に無効になる。
    private func resetPlaybackContinuityState() {
        cachedBackgroundMask = nil
        framesUntilResegment = 0
        landmarkSmoother.reset()
        lastRenderedClipID = nil
        wasInTransition = false
        hasReachedEnd = false
        model?.notifyLiveSeek()
    }

    deinit {
        displayLink?.invalidate()
    }
}
#endif
