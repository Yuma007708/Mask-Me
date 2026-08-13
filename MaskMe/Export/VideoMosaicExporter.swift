import AVFoundation
import CoreImage
import UIKit
import MosaicCore

/// 加工の速度／品質バランス。検出は 1 フレームあたり複数のニューラル推論を伴い
/// 尺に比例して支配的コストになるため、検出頻度（何フレームおきに検出するか）と
/// 検出入力解像度で速度を段階制御する。検出しないフレームは直前の検出結果を保持し、
/// キャッシュ（`detectionCache`）にヒットするフレームは検出をスキップする。
/// UI／モデルから参照するため Metal ガード外に置く（純粋な値型で Metal 非依存）。
public enum ExportSpeed: Sendable, CaseIterable {
    /// 最大品質。従来挙動（2フレーム毎・800px）。精度計画の基準。
    case maxQuality
    /// 既定。検出を約1/1.5に間引き、検出解像度を落として体感品質を保ちつつ高速化。
    case balanced
    /// 最速。検出を大幅に間引く。速い動きでは追従がややラフになる。
    case fast

    /// 何フレームおきに検出するか（値が大きいほど検出回数が減る＝速い）。
    var detectionInterval: Int {
        switch self {
        case .maxQuality: return 2
        case .balanced:   return 3
        case .fast:       return 5
        }
    }

    /// 検出に渡す画像の最大幅（px）。小さいほど推論が速い（小顔検出はやや不利）。
    var detectionMaxWidth: Double {
        switch self {
        case .maxQuality: return 800
        case .balanced:   return 640
        case .fast:       return 512
        }
    }

    /// UI 表示用の短いラベル。
    public var displayName: String {
        switch self {
        case .maxQuality: return "高品質"
        case .balanced:   return "標準（推奨）"
        case .fast:       return "最速"
        }
    }
}

/// 音声トラックの実データから求めた、再エンコードが要るかどうかの判定材料。
/// `AudioExportPipeline.decide` の入力を 1 つにまとめ、
/// 「合成結果の音声トラックを見て決める」という規則を型で表す。
struct AudioTrackConditions: Equatable {
    /// 音声トラックに empty edit（無音区間）がある。
    var hasEmptySegments = false
    /// 音声トラックにスケール編集（rate≠1）のセグメントがある。
    var hasScaledSegments = false
    /// 音声トラックのフォーマット記述が複数種類ある（48k/44.1k 混在など）。
    var hasMixedFormats = false
    /// 合成結果に音声トラックが 2 本以上ある（トランジションの A/B 交互配置）。
    ///
    /// パススルー経路は `AVAssetReaderTrackOutput` 1 本 = **トラックを 1 本しか読めない**
    /// ため、2 本ある構成でパススルーへ落ちると B 側（奇数インデックスのクリップ）の
    /// 音声が出力に一切入らない。デコード読み（`AVAssetReaderAudioMixOutput`）は
    /// 複数トラックをまとめてミックスできるので、複数本あるときは必ず再エンコードへ倒す。
    ///
    /// **現行の `TimelineCompositionBuilder` 経路では、この条件が判定を左右することは無い**:
    /// 2 トラックになるのは重なりがあるとき（`usesTwoTracks = !overlaps.isEmpty`）だけで、
    /// そのとき `AudioMixFactory.make` は必ず非 nil を返すため `hasAudioMix` で
    /// すでに `.reencode` が確定している。この条件が効くのは、公開 API
    /// `export(asset:…)` へ builder 以外が組んだ合成物（audioMix 無しで音声 2 本）が
    /// 渡された場合の防御。
    var hasMultipleTracks = false
}

/// 音声書き出しの経路。分岐判定をこの決定関数 1 箇所に閉じ込める。
///
/// - `passthrough`: 元パケットを無変換コピー（フェーズ1 の bit 同一忠実度を温存）。
/// - `reencode`: PCM デコード読み → AAC 再エンコード。圧縮パススルーの読みは
///   `copyNextSampleBuffer` がセグメント単位の巨大バッチ（実測 1s 超）で届き、
///   マルチセグメント composition では reader.timeRange / 自前ゲートのどちらも
///   トリム位置で正しく切れない（-16364 失敗や音声全損の実測あり）。
///   デコード済み PCM なら timeRange がサンプル精度で機能する。
enum AudioExportPipeline: Equatable {
    case passthrough
    case reencode

    /// 判定基準（1 つでも真なら `.reencode`。すべて偽のときだけ `.passthrough`）:
    /// - `isTrimming`: トリムはサンプル精度の切り出しが要るため再エンコード。
    /// - `hasEmptyAudioSegments`: 音声トラックに empty edit がある
    ///   （= 写真クリップ等、音声なし素材を含むタイムライン）。圧縮パススルー読み
    ///   （`AVAssetReaderTrackOutput`）は empty edit を尊重せず実データを詰めて
    ///   返すため、後続クリップの音声が empty 区間ぶん前ズレして末尾が無音になる
    ///   （動画+写真+動画で実測。プレビューの AVPlayer は正しく再生するので
    ///   書き出しだけ食い違う）。デコード読み（`AVAssetReaderAudioMixOutput`）は
    ///   empty edit を無音として尊重する。
    /// - `hasScaledAudioSegments`: rate≠1 のクリップがある（S7）。
    ///   `scaleTimeRange` は edit（`AVAssetTrackSegment.timeMapping` の source と
    ///   target で長さが違う状態）としてしか表現されないため、圧縮パススルーで
    ///   元パケットをコピーすると**スケールが一切反映されない**
    ///   （映像だけ倍速・音声は等速のまま尺超過）。デコード読みなら
    ///   `audioTimePitchAlgorithm`（`.spectral`）付きで時間スケールが適用される。
    /// - `hasMixedAudioFormats`: 音声トラックに複数フォーマット（48kHz 素材と
    ///   44.1kHz 素材の連結など）が混在する。パススルーの writer 入力は
    ///   `sourceFormatHint` を 1 つしか持てず、別フォーマットのパケットが来た時点で
    ///   破綻する。再エンコードなら共通の PCM へ揃えてから 1 つの AAC に書ける。
    ///
    /// 判定材料はすべて composition の音声トラックの実データ
    /// （`AVAssetTrack.segments` / `.formatDescriptions`）から求める
    /// （`AudioTrackConditions.from(tracks:)`。**全トラック分**を渡すこと）。
    ///
    /// - `hasAudioMix`: `AVAudioMix` が付いている（S8）。トランジションの音声
    ///   クロスフェード、または `TimelineClip.originalAudioVolume` の音量調整がある構成。
    ///   パススルーは元パケットをそのままコピーするため**音量・フェードが一切反映されない**
    ///   （映像だけクロスフェードして音は途中でぶつ切り、になる）。デコード読み
    ///   （`AVAssetReaderAudioMixOutput.audioMix`）なら反映される。
    ///
    /// - `hasMultipleTracks`: 合成結果の音声トラックが 2 本以上（S8 のトランジションで
    ///   A/B へ交互配置された構成）。パススルー読みは 1 トラック分しか出力に載せられず、
    ///   B 側のクリップの音声が丸ごと落ちる（プレビューの AVPlayer は composition 全体を
    ///   鳴らすので書き出しだけ食い違う）。ただし `TimelineCompositionBuilder` が組んだ
    ///   合成物では、2 トラック = 重なりあり = audioMix ありなので `hasAudioMix` で
    ///   すでに再エンコードが確定している（この条件は builder 以外の合成物に対する防御）。
    ///
    /// - `hasBackgroundAudio`: BGM（E2）が 1 曲でも載っている。
    ///
    ///   **他の条件では拾えない穴がある。** 元動画に音声トラックが無い構成
    ///   （無音動画・写真だけのタイムライン）では、builder が空の音声トラックを
    ///   除去するため合成物の音声トラックは **BGM 1 本だけ**になる。このとき
    ///   `hasMultipleTracks` は false、BGM の音量が既定なら `hasAudioMix` も false、
    ///   BGM が 0 秒から全体を覆えば `hasEmptySegments` も false で、
    ///   **3 条件すべてをすり抜けて `.passthrough` へ落ちる**。
    ///
    ///   **実害は「BGM の音量が一切効かなくなる」こと**（守りを外して実測した。
    ///   `MultiClipExportTests.test_backgroundAudioVolume_isAppliedToOutput`）。
    ///   音そのものは鳴る（元パケットがそのままコピーされるため）ので、
    ///   「BGM が無音になる」形では現れず、**音量スライダーだけが黙って効かない**
    ///   という気づきにくい壊れ方をする。
    ///   BGM がある時点でパススルーは選ばない、と明示的に決める。
    ///
    /// 入口はこの 1 つだけにしてある（条件を個別 Bool で受ける素の入口は置かない）。
    /// 呼び出し側が条件の導出（`AudioTrackConditions.from`）をバイパスできると、
    /// 条件が増えたときに渡し忘れが静かに `.passthrough` へ落ちるため。
    /// `hasAudioMix` / `hasBackgroundAudio` に既定値を与えないのも同じ理由
    /// （渡し忘れはコンパイルエラーになる）。
    static func decide(isTrimming: Bool,
                       hasAudioMix: Bool,
                       hasBackgroundAudio: Bool,
                       conditions: AudioTrackConditions) -> AudioExportPipeline {
        let needsReencode = isTrimming
            || hasAudioMix
            || hasBackgroundAudio
            || conditions.hasEmptySegments
            || conditions.hasScaledSegments
            || conditions.hasMixedFormats
            || conditions.hasMultipleTracks
        return needsReencode ? .reencode : .passthrough
    }
}

/// 音声トラック 1 本ぶんの判定材料（合成結果から読んだ実データ）。
///
/// `AudioTrackConditions.from(tracks:)` の入力を「トラックの配列」に固定するための型。
/// セグメント列とフォーマット記述を平坦化した配列＋本数、という渡し方にすると
/// 「1 本ぶんのデータに本数 2 を添えて渡す」ような不整合が型で防げないため。
struct AudioTrackData {
    let segments: [AVAssetTrackSegment]
    let formatDescriptions: [CMFormatDescription]

    /// 合成結果の音声トラック列から判定材料を読み出す（並びはトラック列のまま）。
    static func load(from tracks: [AVAssetTrack]) async -> [AudioTrackData] {
        var result: [AudioTrackData] = []
        for track in tracks {
            result.append(AudioTrackData(
                segments: (try? await track.load(.segments)) ?? [],
                formatDescriptions: (try? await track.load(.formatDescriptions)) ?? []))
        }
        return result
    }
}

extension AudioTrackConditions {
    /// 合成結果の音声トラック**全部**の実データから判定材料を求める。
    ///
    /// トラック 1 本だけを見て決めると、A/B 交互配置（S8）では B 側の empty edit・
    /// スケール編集・別フォーマットを取りこぼし、「2 本ある」こと自体
    /// （`hasMultipleTracks`）も見落とす。
    ///
    /// なお現行の `TimelineCompositionBuilder` 経路では、これらの取りこぼしが
    /// `.passthrough` への転落を招くことは無い（2 トラック構成は必ず audioMix 付き
    /// ＝ `hasAudioMix` で再エンコード確定）。B 側の音声が実際に消えるのを止めているのは
    /// 再エンコード読みへ**全トラックを渡している**こと
    /// （`AVAssetReaderAudioMixOutput(audioTracks:)`）である。全部を渡すのは、
    /// builder 以外が組んだ合成物が公開 API `export(asset:…)` に来た場合の防御。
    static func from(tracks: [AudioTrackData]) -> AudioTrackConditions {
        let segments = tracks.flatMap(\.segments)
        let formats = tracks.flatMap(\.formatDescriptions)
        return AudioTrackConditions(
            hasEmptySegments: segments.contains { $0.isEmpty },
            hasScaledSegments: segments.contains { isScaled($0) },
            hasMixedFormats: hasMixedFormats(formats),
            hasMultipleTracks: tracks.count > 1)
    }

    /// スケール判定の許容差 = 1/1200 秒。**絶対値であってクリップ長に比例させない。**
    ///
    /// 根拠は `TimelineCompositionBuilder` が timescale 600 で挿入すること
    /// （目盛は 1/600s、1 量あたりの丸め誤差の上限はその半分）。誤差の源が丸めなので、
    /// 尺に比例する相対許容差にすると長いクリップほど鈍くなり、微小 rate が
    /// 「スケールなし」に化けて `.passthrough` へ落ちる
    /// （= 映像だけ速度変更・音声は等速のまま、という S7 が塞いだ穴の再発）。
    ///
    /// 半目盛にしてあるのは、600 グリッド上では **source と target の差も 1/600 の
    /// 整数倍にしかならない**ため。実測でも等速タイムラインの差は例外なく厳密に 0 で、
    /// 最小のスケールは差 1 目盛（= 1/600s）として現れる。半目盛なら
    /// 「差 0 は等速・差 1 目盛以上はスケール」を素直に分けられ、なおかつ
    /// 別 timescale の素材が混じったときの端数（数十 µs 規模）は吸収できる。
    /// これより細かい rate 差は composition 上に差として存在しない
    /// （= 反映すべきスケールが無い）ので、取りこぼしにはならない。
    static let scaleTolerance = CMTime(value: 1, timescale: 1200)

    /// スケール編集（rate≠1）のセグメントか。`timeMapping` の source と target の
    /// 長さが違えばスケール（Apple の Time pitch algorithm settings の定義と同じ）。
    ///
    /// `TimelineClip.rateRange` は 0.1...10 の**連続値**（`TimelineEditOperations.setRate`
    /// は任意の Double を受ける）なので、「rate 変更は必ず 1 割以上動く」とは仮定できない。
    /// 一方 rate=1 のときは builder が `scaleTimeRange` を呼ばない
    /// （`TimelineCompositionBuilder`）ため source と target は同一値になる。
    /// よって固定許容差（`scaleTolerance`）で十分で、誤検知の余地もほぼ無い。
    /// CMTime のまま比較して Double 変換の丸めを挟まない。
    static func isScaled(_ segment: AVAssetTrackSegment) -> Bool {
        guard !segment.isEmpty else { return false }
        let mapping = segment.timeMapping
        let source = mapping.source.duration
        let target = mapping.target.duration
        guard source.isNumeric, target.isNumeric,
              source > .zero, target > .zero else { return false }
        let diff = CMTimeAbsoluteValue(CMTimeSubtract(source, target))
        return diff > scaleTolerance
    }

    /// フォーマット記述が複数種類あるか（コーデック・サンプルレート・チャンネル数で比較）。
    ///
    /// - 記述が 1 つ以下なら「混在なし」（比較対象が無い＝連結による混在は起こりえない）。
    /// - 安全側（混在あり）に倒すのは **ASBD が取れなかったとき**だけ。
    ///   フォーマットが読めない相手を「同じ」と見なしてパススルーすると、
    ///   writer 入力の `sourceFormatHint` と実パケットの食い違いで破綻するため。
    /// - 比較するのは formatID / sampleRate / channels の 3 項目のみ。
    ///   esds（AAC プロファイル・ビットレート）の違いは「混在なし」＝パススルーになる。
    ///   ビットレート差だけなら同一コンテナへパケットを並べても実害が出ないことは
    ///   確認済み。将来 HE-AAC 等のプロファイル差で問題が出たら esds 比較を足すこと。
    static func hasMixedFormats(_ formats: [CMFormatDescription]) -> Bool {
        guard formats.count > 1 else { return false }
        guard let first = CMAudioFormatDescriptionGetStreamBasicDescription(formats[0])?.pointee
        else { return true }
        return formats.dropFirst().contains { format in
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { return true }
            return asbd.mFormatID != first.mFormatID
                || asbd.mSampleRate != first.mSampleRate
                || asbd.mChannelsPerFrame != first.mChannelsPerFrame
        }
    }
}

#if canImport(Metal)
import Metal

// フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
// swiftlint:disable file_length type_body_length

/// 動画をフレームごとに処理してモザイクを適用し、新しい .mp4 ファイルを生成する。
/// 音声は**無変換構成**（トリム無し・empty edit 無し・rate≠1 無し・単一フォーマット・
/// 単一トラック・audioMix 無し）なら元トラックをそのまま（再エンコードせず）保持し、それ以外は
/// AAC 再エンコードする（判定は `AudioExportPipeline.decide` の 1 箇所）。
public final class VideoMosaicExporter: @unchecked Sendable {
    public enum ExportError: Error {
        case noVideoTrack
        case readerSetupFailed
        case writerSetupFailed
        case pixelBufferPoolUnavailable
        case textureConversionFailed
    }

    private let renderer: MosaicRenderer
    private let landmarker: FaceLandmarking
    private let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    /// テキストのラスタライズ結果キャッシュ（E3-2）。フレーム処理は単一の
    /// videoQueue 上で直列に走るため（`perfDetectSec` 等と同じ前提）ロック不要。
    private let textOverlayCache: TextOverlayCache

    // MARK: - 中断（ユーザー操作によるキャンセル）
    //
    // `cancel()` は UI（メインアクター）から、フラグの読み出しは映像／音声の
    // pump キュー（別スレッド）から起きるためロックで守る。
    //
    // **`AVAssetReader.status` で中断を判定してはいけない。** `startAudioPump` は
    // 末尾クランプという**正常系**でも `cancelReading()` を呼ぶため、
    // reader の状態は「ユーザーが止めた」ことの証拠にならない。必ずこの自前フラグを見る。
    private let cancelLock = NSLock()
    private var cancelRequested = false
    /// 進行中の reader（映像主リーダー＋音声専用リーダー）。`cancel()` から
    /// `cancelReading()` を呼んでブロック中の `copyNextSampleBuffer()` を戻す。
    private var activeReaders: [AVAssetReader] = []

    /// 進行中の書き出しを中断する（`export` は `CancellationError` を throw する）。
    ///
    /// フラグと `cancelReading()` の**両方**が要る:
    /// - フラグだけでは `copyNextSampleBuffer()` がブロックしたまま戻らない。
    /// - `cancelReading()` だけでは `group.notify` が `.cancelled` を `.failed` と
    ///   区別できず、打ち切られた**部分ファイルが「成功」として返る**。
    public func cancel() {
        cancelLock.lock()
        cancelRequested = true
        let readers = activeReaders
        cancelLock.unlock()
        readers.forEach { $0.cancelReading() }
    }

    /// 中断要求が出ているか（pump の中断点から読む）。
    private var isCancelRequested: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    /// 中断状態を初期化する（同一インスタンスの再利用に備える。
    /// `landmarkSmoother.reset()` と同じ思想で export の冒頭に 1 回だけ呼ぶ）。
    private func resetCancelState() {
        cancelLock.lock()
        cancelRequested = false
        activeReaders = []
        cancelLock.unlock()
    }

    /// 中断対象のリーダーを登録する（`startReading()` 成功直後に呼ぶ）。
    private func registerActiveReader(_ reader: AVAssetReader) {
        cancelLock.lock()
        activeReaders.append(reader)
        cancelLock.unlock()
    }
    /// 描画直前のランドマーク EMA（フレーム間の微小ちらつき吸収）。検出キャッシュには
    /// 適用しない（計測系と描画系の分離）。export ごとに reset して使う。
    private let landmarkSmoother = LandmarkSmoother()
    #if canImport(Vision)
    private let backgroundSegmenter = PersonSegmenter(quality: .balanced)
    #endif

    // MARK: - 速度計測（数値のみ・フレーム画像は一切扱わない）
    // 単一の videoQueue 上で直列に更新されるためロック不要。export ごとに reset する。
    private var perfDetectSec = 0.0
    private var perfRenderSec = 0.0
    private var perfSegSec = 0.0
    private var perfDecodeSec = 0.0
    private var perfDetectCalls = 0
    private var perfFrames = 0
    private var perfWallStart: CFAbsoluteTime = 0

    /// 検出入力の最大幅（速度段で決まる）。pump 開始時に設定し detectAll が参照する。
    private var detectMaxWidth: Double = 800

    /// 写真素材（静止 mp4）の素材ID集合（S6）。export 開始時に設定する。
    /// 写像で得た素材時刻をこの素材だけ 0 に clamp し、t=0 の検出 seed へ全フレームを
    /// ヒットさせる（`TimelineState.clampedSourceTime` と同じ規則。写真は全フレーム
    /// 同一なので、区間内で実検出を繰り返さない）。
    private var photoSourceIDs: Set<UUID> = []

    /// モザイク適用区間（素材時刻アンカー。S10）。export 開始時に
    /// `MosaicApplyGate.effectiveRanges(_:mapping:)` を通してから設定する
    /// （孤児区間を残すと全区間 OFF になる。プロパティ doc は同関数を参照）。
    ///
    /// **空なら適用なし（全区間 OFF）**。S11 で意味が反転した（旧: 空 = 全区間適用）。
    /// 区間外のフレームは顔・手動矩形・背景モザイクのすべてを止めて**入力フレームを
    /// そのまま**書き出す（フレームを落とさない・pts を変えないので出力尺は不変）。
    /// 判定は `MosaicApplyGate` の純関数だけを通し、プレビュー経路
    /// （`MosaicEditorModel.isMosaicActive(atComposition:)`）と同じ規則を共有する。
    private var applyRanges: [MosaicApplyRange] = []

    /// 素材フレーム基準の顔座標 → 合成フレーム基準の写像（S8）。export 開始時に設定する。
    /// 解像度混在タイムラインではクリップがレターボックスで配置されるため、
    /// 検出キャッシュ由来の顔だけこの写像を通す（その場検出は合成済みフレームに
    /// 対して走るので既に合成フレーム基準＝写像不要）。無変換構成では恒等。
    private var renderLayout: TimelineRenderLayout = .identity

    /// レターボックス（余白）の埋め方。export 開始時に設定する。
    ///
    /// **プレビューと同じ値を渡すこと。** 片方だけ変わると、画面では色が付いているのに
    /// 書き出すと黒帯、という書き出すまで気づけない食い違いになる。
    private var letterbox: TimelineBackground = .default

    /// 余白を塗るのに使う「素材が置かれている範囲」（合成フレーム基準・正規化）。
    /// export 開始時に `TimelineRenderLayout.contentBounds`（全クリップの配置矩形の和）で求める。
    ///
    /// **時刻ごとではなく全体の和にしてある。** 時刻ごとに違う矩形を使うと、
    /// クリップの切り替わりで余白の形が飛ぶ（黒帯が出たり消えたりする）。
    /// 和を使えば「どのクリップも描かない場所」だけが塗られるので、
    /// **素材の上に塗ってしまう事故が構造的に起きない**——これは
    /// 「モザイクの上に余白を塗って顔を出す」形の事故を防ぐ意味でも重要。
    private var letterboxContentRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 物体マスクの自動追跡（O2）の軌跡。export 開始時に設定する。
    ///
    /// **プレビューと同じ軌跡を渡すこと。** 追跡はオプティカルフローの逐次処理なので、
    /// 書き出し側で改めて走らせるとプレビューと違う結果になる。事前に計算した軌跡を
    /// 両者が読むだけ、という規約は `ObjectTrack` の doc を参照
    /// （`MosaicEditorModel.exportVideo` は書き出し前に追跡の完走を待つ）。
    private var objectTracks: [UUID: ObjectTrack] = [:]

    /// 画面に置く文字（E3）。export 開始時に `timeline.textItems` をそのまま設定する。
    /// クリップ・トリムに追従しないアンカーなので、素材位置の写像は要らない
    /// （`TextItem` の doc 参照）。
    private var textItems: [TextItem] = []
    /// `TextItem.clipped(toTotalDuration:)` / `visibleTextItems` に渡す合成尺。
    /// **プレビューと同じ `mapping.totalDuration` を使うこと**（`trimRange` の
    /// PTS シフトとは無関係。トリムは書き出し側の出力尺の話で、テキストの
    /// アンカーは常にトリム前の合成タイムライン上にある）。
    private var textTotalDuration: Double = 0

    /// クリップごとの色調補正（P4）。`MosaicEditorModel` は
    /// `timeline.clips` から `[id: colorGrade]` を射影して渡す。`TimelineState` を
    /// まるごと保持しない（`mapping`/`applyRanges`/`textItems` と同じ、必要な射影だけを
    /// 保持する既存の流儀）。合成時刻での重なりブレンドは `colorGrade(at:)` が
    /// `mapping.sourceLocations(at:)` と `ColorGrade.blend` を直接使って行う
    /// （`TimelineState.colorGrade(atComposition:)` と同じ手順。あちらへ委譲しないのは
    /// このクラスが `TimelineState` を持たず `TimelineMapping` だけを持つため）。
    private var colorGrades: [UUID: ColorGrade] = [:]

    /// 無料プランの透かし（課金 P2）を焼き込むか。export 開始時に設定する。
    ///
    /// **`isPro` を直接見ない。** 判定の根拠は `Built.exportRestriction.needsWatermark`
    /// の 1 箇所に集約し（`ExportRestrictionPolicy.decide` が唯一の判定関数）、
    /// `MosaicEditorModel.runExport` が呼び出し時に渡す。ここで改めて `isPro` を
    /// 見直すと、判定ロジックが 2 箇所に散らばって将来食い違う余地ができる。
    private var needsWatermark = false

    private func resetPerf() {
        perfDetectSec = 0; perfRenderSec = 0; perfSegSec = 0; perfDecodeSec = 0
        perfDetectCalls = 0; perfFrames = 0
        perfWallStart = CFAbsoluteTimeGetCurrent()
    }

    private func logPerfSummary(totalSeconds: Double) {
        let wall = CFAbsoluteTimeGetCurrent() - perfWallStart
        let fps = wall > 0 ? Double(perfFrames) / wall : 0
        // other = wall − 計測済み各段。encode は adaptor.append の裏で writer が非同期実行するため
        // 直接計測できず、isReadyForMoreMediaData の待ち（バックプレッシャー）として other に残る。
        // Simulator は HW エンコーダ非搭載でこの encode 待ちが支配的（実機では HW で縮む）。
        let other = max(0, wall - perfDetectSec - perfRenderSec - perfSegSec - perfDecodeSec)
        // %.1f で百分率を出し、内訳が一目で分かるようにする。
        func pct(_ v: Double) -> String { String(format: "%.0f%%", wall > 0 ? v / wall * 100 : 0) }
        print("""
        [MMEXPORT] frames=\(perfFrames) videoSec=\(String(format: "%.1f", totalSeconds)) \
        wall=\(String(format: "%.1f", wall))s fps=\(String(format: "%.1f", fps))
        [MMEXPORT] detect=\(String(format: "%.1f", perfDetectSec))s(\(pct(perfDetectSec)), calls=\(perfDetectCalls)) \
        render=\(String(format: "%.1f", perfRenderSec))s(\(pct(perfRenderSec))) \
        seg=\(String(format: "%.1f", perfSegSec))s(\(pct(perfSegSec))) \
        decode=\(String(format: "%.1f", perfDecodeSec))s(\(pct(perfDecodeSec))) \
        other/encode=\(String(format: "%.1f", other))s(\(pct(other)))
        """)
    }

    public init(renderer: MosaicRenderer, landmarker: FaceLandmarking) {
        self.renderer = renderer
        self.landmarker = landmarker
        self.textOverlayCache = TextOverlayCache(device: renderer.device)
        self.ciContext = CIContext(mtlDevice: renderer.device)
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, renderer.device, nil, &textureCache
        )
    }

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable cyclomatic_complexity function_body_length
    /// 動画をエクスポートして一時 URL を返す。
    /// - Parameters:
    ///   - selectedFaceTargets: モザイク対象として選択された顔。空の場合は全顔に適用。
    ///   - objectMasks: 物体モザイク（矩形マスク）。矩形は**素材フレーム基準**なので、
    ///     フレームの解決済み `location`（clipID・素材時刻）で補間してから
    ///     `renderLayout` で合成フレーム基準へ写す（`ObjectMaskResolver`）。
    ///     プレビューと同じ純関数を通すので、境界フレームでも結果が一致する。
    ///   - detectionCaches: 素材IDごとの検出キャッシュ（キーは素材内時刻）。
    ///     フレーム PTS（合成時刻）を `mapping` で素材位置へ写像してから参照する
    ///     （丸め・近傍補間は必ず写像の後。合成時刻のまま丸めると rate≠1 でずれる）。
    ///   - mapping: 合成時刻→素材位置の写像。`asset`（合成結果）を構築したのと
    ///     同じクリップ列から作ること。クリップ境界の時系列リセット判定にも使う。
    ///     空の写像ではキャッシュ参照と境界リセットが無効になるだけで、
    ///     全フレーム自前検出で完走する（素の AVAsset 書き出し・テスト互換）。
    ///   - photoSourceIDs: 写真素材（静止 mp4）の素材ID集合。写像後の素材時刻を
    ///     0 に clamp して t=0 の検出 seed にヒットさせる（`photoSourceIDs` プロパティ
    ///     の doc 参照。`MosaicEditorModel` は `timeline.photoSourceIDs` を渡す）。
    ///   - faceEnabled: 顔モザイクの ON/OFF（false なら顔ランドマークを適用しない）。
    ///   - objectEnabled: 物体マスク（手動矩形）の ON/OFF。**`faceEnabled` とは独立**。
    ///     顔を切っても矩形は残る（逆も同じ）。プレビュー側の `objectMosaicOn` と対。
    ///   - videoComposition: 装着する映像合成（S8）。非 nil のときは
    ///     `AVAssetReaderVideoCompositionOutput` で**合成済みフレーム**を読み、
    ///     writer は `renderSize` + identity transform で書く（`preferredTransform` は
    ///     instruction 側に畳み込み済み。両方で回転を掛けると縦動画が横倒しになる）。
    ///     下流の Metal モザイク焼き込みは無改造で通る（合成順序は
    ///     「トランジション合成 → モザイク焼き込み」＝モザイクが常に最終画面を覆う）。
    ///   - audioMix: 装着する音声ミックス（S8）。非 nil なら音声は必ず再エンコード経路。
    ///   - renderLayout: 素材フレーム基準の顔座標を合成フレーム基準へ写すレイアウト。
    ///     解像度混在（レターボックス）で効く。無変換構成では恒等。
    public func export(
        asset: AVAsset,
        selectedFaceTargets: [FaceTarget] = [],
        selectedPersons: [PersonProfile] = [],
        faceSignatures: FaceSignatureLookup = FaceSignatureLookup(samples: [:]),
        objectMasks: [ObjectMask] = [],
        /// 物体マスクの自動追跡の軌跡（マスク id 引き）。プレビューと**同じもの**を渡す。
        objectTracks: [UUID: ObjectTrack] = [:],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]] = [:],
        mapping: TimelineMapping = TimelineMapping(clips: []),
        photoSourceIDs: Set<UUID> = [],
        /// モザイク適用区間（`clipID` + 素材時刻アンカー）。
        /// ⚠️ **既定の空は「適用なし（全区間 OFF）」**（S11 で意味が反転した）。
        /// クリップが 1 本も無い写像（`mapping` が空 = 素の AVAsset 書き出し）では
        /// ゲートが写像不能でフェイルオープンするため、従来どおり全フレームに適用される。
        /// 「全区間に適用」を明示したい呼び出しは
        /// `MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs:)` を渡すこと。
        /// `MosaicEditorModel` は `timeline.applyRanges` を渡す。
        applyRanges: [MosaicApplyRange] = [],
        /// 画面に置く文字（E3）。`MosaicEditorModel` は `timeline.textItems` を渡す。
        /// 素材アンカーを持たないので `mapping` による写像は不要（合成時刻のまま使う）。
        textItems: [TextItem] = [],
        /// クリップごとの色調補正（P4）。`MosaicEditorModel` は
        /// `Dictionary(uniqueKeysWithValues: timeline.clips.map { ($0.id, $0.colorGrade) })`
        /// を渡す。キーに無いクリップは `.identity` として扱う（`colorGrade(at:)` 参照）。
        colorGrades: [UUID: ColorGrade] = [:],
        /// 無料プランの透かし（課金 P2）を焼き込むか。
        ///
        /// `MosaicEditorModel` は `exportRestriction.needsWatermark` を渡す
        /// （`.exceedsResolution` でも真になる導出プロパティ。`ExportRestriction` の
        /// doc 参照）。既定 `false` はテスト・素の書き出し互換のため。
        needsWatermark: Bool = false,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil,
        /// BGM（E2）が 1 曲でも載っているか。真なら音声は必ず再エンコード経路になる。
        ///
        /// **既定 `false` は「BGM 無しの素の書き出し」を意味する。** 実アプリの経路
        /// （`MosaicEditorModel.exportVideo`）は `hasBackgroundAudio` を必ず渡す。
        /// 渡し忘れても `AudioMixFactory` が BGM のとき必ず mix を返すため
        /// `hasAudioMix` 側で再エンコードに倒れる（**二重の守り**）が、
        /// 判定を mix の有無だけに委ねない（mix を作らない最適化を将来入れた瞬間に
        /// 穴が開く形にしない）。
        hasBackgroundAudio: Bool = false,
        renderLayout: TimelineRenderLayout = .identity,
        letterbox: TimelineBackground = .default,
        faceEnabled: Bool = true,
        objectEnabled: Bool = true,
        backgroundEnabled: Bool = false,
        backgroundBlock: Float = 28,
        speed: ExportSpeed = .balanced,
        /// 動画の書き出し範囲（0...1 正規化）。既定は全長。
        ///
        /// **S9 現在、実アプリの呼び出しは常に既定（全長）である**
        /// （UI からの書き込み経路が無い。`MosaicEditorModel.trimRange` の doc 参照）。
        /// 将来の再導入に備えて PTS シフト経路ごと意図的に残してあり、
        /// 写像との二重適用を起こさないことは `MultiClipExportTests` が固定している。
        ///
        /// 範囲外のフレーム/音声サンプルは reader.timeRange で読まず、writer 側の
        /// 時刻を `trimRange.lowerBound` 分シフトして出力尺を短縮する。
        /// トリム時の音声はパススルーではなく AAC 再エンコードになり、末尾の余剰は
        /// `clampAudioSample` で切る（`AudioExportPipeline` 参照。
        /// トリム無し・無変換構成は従来どおり無変換コピー）。
        trimRange: ClosedRange<Double> = 0...1,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // 同一インスタンスを再利用したとき、前回の中断要求が残っていると
        // 今回の書き出しが即座に打ち切られる。冒頭で必ず捨てる。
        resetCancelState()
        self.photoSourceIDs = photoSourceIDs
        // 人物同定の材料。プレビューと同じ判定関数へ渡すために保持する
        // （引数を 5 層のプライベート関数に通さないための保持であって、状態ではない）。
        self.identityPersons = selectedPersons
        self.identitySignatures = faceSignatures
        self.identityKeptFaceCount = 0
        self.identityFilteredFrameCount = 0
        // 孤児区間（どのクリップの使用範囲とも交差しない適用区間）をここで 1 回だけ落とす。
        // O(クリップ数 × 区間数) を全フレームで回さないためのキャッシュであり、
        // プレビュー側（`MosaicEditorModel.effectiveApplyRanges`）と**同じ純関数**を通す
        // ので、両経路のゲート結果が必ず一致する。
        self.applyRanges = MosaicApplyGate.effectiveRanges(applyRanges, mapping: mapping)
        self.renderLayout = renderLayout
        self.letterbox = letterbox.clamped
        self.letterboxContentRect = renderLayout.contentBounds
        self.objectTracks = objectTracks
        self.textItems = textItems
        self.textTotalDuration = mapping.totalDuration
        self.colorGrades = colorGrades
        self.needsWatermark = needsWatermark
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack
        }
        // 音声トラックは**全部**扱う。トランジションのある構成（S8）では builder が
        // 音声も A/B 2 トラックへ交互配置するため、1 本しか読まないと B 側
        // （奇数インデックスのクリップ）の音声が出力に一切入らない。
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        let duration = try await asset.load(.duration)
        // 映像合成を装着するときは、出力サイズ = renderSize・向きは identity。
        // preferredTransform は instruction 側に畳み込み済みなので、ここでも掛けると
        // 二重回転（縦動画が横倒し／180 度回転）になる。
        let naturalSize: CGSize
        let transform: CGAffineTransform
        if let videoComposition {
            naturalSize = videoComposition.renderSize
            transform = .identity
        } else {
            naturalSize = try await videoTrack.load(.naturalSize)
            transform = try await videoTrack.load(.preferredTransform)
        }
        let estimatedDataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
        // 音声トラックの実データ（フォーマット記述・セグメント列）を 1 度だけ読み、
        // 経路判定（`AudioExportPipeline.decide`）と writer 設定の両方に使う。
        var audioFormat: CMFormatDescription?
        var audioConditions = AudioTrackConditions()
        if !audioTracks.isEmpty {
            let trackData = await AudioTrackData.load(from: audioTracks)
            audioFormat = trackData.flatMap(\.formatDescriptions).first
            audioConditions = AudioTrackConditions.from(tracks: trackData)
        }

        // --- Reader: 映像（BGRA）＋ 音声（パススルー） ---
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = makeVideoOutput(tracks: videoTracks, videoComposition: videoComposition)
        guard reader.canAdd(videoOutput) else { throw ExportError.readerSetupFailed }
        reader.add(videoOutput)

        // トリム範囲の計算（音声リーダーの構成が変わるため、出力の追加より先に行う）。
        let totalDurationSeconds = CMTimeGetSeconds(duration)
        let clampedLower = max(0.0, min(1.0, trimRange.lowerBound))
        let clampedUpper = max(clampedLower, min(1.0, trimRange.upperBound))
        let trimStartSec = clampedLower * totalDurationSeconds
        let trimEndSec = clampedUpper * totalDurationSeconds
        let isTrimming = clampedLower > 0.001 || clampedUpper < 0.999

        // 音声経路の決定（パススルー / 再エンコード。判定は AudioExportPipeline に集約）。
        //
        // 再エンコード時は**別リーダー + AVAssetReaderAudioMixOutput（デコード済み PCM）**
        // で読む。圧縮パススルー読みは copyNextSampleBuffer がセグメント単位の巨大バッチで
        // 届き、①マルチセグメント composition + timeRange で -16364 失敗、②自前ゲートでは
        // トリム範囲と交差するバッチを丸ごと採否してしまい音声全損、③empty edit を
        // 尊重せず後続クリップの音声が前ズレ、をいずれも実測済み。
        // デコード済み PCM なら reader.timeRange がサンプル精度で機能し、empty edit も
        // 無音として尊重される（MultiClipExportTests の trim 系・写真中間配置テストが
        // RMS 解析込みで固定している）。映像は従来どおり主リーダー側の timeRange で制限する。
        let audioPipeline = AudioExportPipeline.decide(
            isTrimming: isTrimming, hasAudioMix: audioMix != nil,
            hasBackgroundAudio: hasBackgroundAudio, conditions: audioConditions)
        var audioOutput: AVAssetReaderOutput?
        var separateAudioReader: AVAssetReader?
        if let audioTrack = audioTracks.first {
            switch audioPipeline {
            case .passthrough:
                // 複数トラックは `hasMultipleTracks` が必ず `.reencode` へ倒すので、
                // ここに来るのは 1 本だけの構成（= `audioTracks.first` で全部）。
                let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                out.alwaysCopiesSampleData = false
                if reader.canAdd(out) {
                    reader.add(out)
                    audioOutput = out
                }
            case .reencode:
                // デコードは AAC 出力と同じサンプルレート・チャンネル数の LinearPCM に
                // 揃える（`reencodeDecodeSettings(matching:)` 参照）。>2ch のダウンミックスも
                // 48k/44.1k 混在素材のレート統一もここで済ませ、writer 側は
                // 単一フォーマットの PCM だけを受け取る。
                // 全トラックを渡してミックスさせる（A/B 交互配置では 2 本）。
                // 重なり区間は audioMix の音量ランプでクロスフェードされ、
                // それ以外の区間は片方だけが鳴っている（他方は empty range）。
                let out = AVAssetReaderAudioMixOutput(
                    audioTracks: audioTracks,
                    audioSettings: Self.reencodeDecodeSettings(matching: audioFormat))
                // rate≠1（scaleTimeRange 済み）のとき音程を保ったまま時間スケールを
                // 適用する。値はプレビューと共有の定数から引く
                // （`AudioMixFactory.timePitchAlgorithm` の doc 参照）。
                AudioMixFactory.applyTimePitch(to: out)
                // トランジションの音声クロスフェード・元音声音量（S8）。
                // パススルー経路には audioMix を適用する手段が無いため、
                // `decide` が audioMix ありを必ず再エンコードへ倒している。
                out.audioMix = audioMix
                out.alwaysCopiesSampleData = false
                let audioReader = try AVAssetReader(asset: asset)
                // timeRange の制限（と pump 側の shiftSample）はトリム時だけ。
                // empty edit 起因の再エンコードは全長を 0 起点のまま読む
                // （decision と shift の適用条件を連動させる）。
                if isTrimming {
                    audioReader.timeRange = CMTimeRange(
                        start: CMTime(seconds: trimStartSec, preferredTimescale: 600),
                        duration: CMTime(seconds: trimEndSec - trimStartSec, preferredTimescale: 600))
                }
                if audioReader.canAdd(out) {
                    audioReader.add(out)
                    audioOutput = out
                    separateAudioReader = audioReader
                }
            }
        }

        // --- Writer: 映像（HEVC優先）＋ 音声（パススルー or AAC 再エンコード） ---
        let outputURL = makeOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let (videoInput, adaptor) = try makeVideoWriterInput(
            size: naturalSize,
            transform: transform,
            estimatedDataRate: estimatedDataRate,
            writer: writer
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let aIn: AVAssetWriterInput
            switch audioPipeline {
            case .passthrough:
                aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: audioFormat
                )
            case .reencode:
                // デコード済み PCM を AAC で書き直す。sourceFormatHint は渡さない
                // （渡すのは元の圧縮フォーマット記述であり、PCM 入力と矛盾するため。
                // 計画書アーキテクチャ決定 5）。
                aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: Self.aacAudioSettings(matching: audioFormat)
                )
            }
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            } else {
                audioOutput = nil
            }
        }

        // トリム時は映像リーダーの読み込み範囲を制限し、書き出し時に PTS を
        // `trimStart` 分シフトして writer タイムラインを 0 起点に保つ
        // （音声側は別リーダーの timeRange で同じ範囲に制限済み。pump 側で同量シフト）。
        let effectiveDuration: CMTime
        if isTrimming {
            let start = CMTime(seconds: trimStartSec, preferredTimescale: 600)
            let dur = CMTime(seconds: trimEndSec - trimStartSec, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)
            effectiveDuration = dur
        } else {
            effectiveDuration = duration
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.readerSetupFailed }
        registerActiveReader(reader)
        if let separateAudioReader {
            guard separateAudioReader.startReading() else {
                reader.cancelReading()
                throw separateAudioReader.error ?? ExportError.readerSetupFailed
            }
            registerActiveReader(separateAudioReader)
        }
        // 準備中に押されたキャンセルをここで拾う（pump に入る前なので
        // writer は開始せず、作成済みの空ファイルだけ片付ければよい）。
        if isCancelRequested {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        renderer.reset()

        guard let cache = textureCache else { throw ExportError.textureConversionFailed }

        return try await pump(
            reader: reader,
            audioReader: separateAudioReader,
            writer: writer,
            outputURL: outputURL,
            videoOutput: videoOutput,
            videoInput: videoInput,
            adaptor: adaptor,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: effectiveDuration,
            videoSize: naturalSize,
            selectedFaceTargets: selectedFaceTargets,
            objectMasks: objectMasks,
            detectionCaches: detectionCaches,
            mapping: mapping,
            faceEnabled: faceEnabled,
            objectEnabled: objectEnabled,
            backgroundEnabled: backgroundEnabled,
            backgroundBlock: backgroundBlock,
            speed: speed,
            trimStartSec: trimStartSec,
            trimEndSec: trimEndSec,
            // 再エンコード経路だけ末尾上限を掛ける（パススルーは bit 同一を保つため
            // 一切触らない）。上限は writer タイムライン上の想定尺 = effectiveDuration。
            audioEndLimitSec: audioPipeline == .reencode
                ? CMTimeGetSeconds(effectiveDuration) : nil,
            cache: cache,
            progress: progress
        )
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Pump（ビジーウェイトなしの読み書き）

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count
    private func pump(
        reader: AVAssetReader,
        /// 再エンコード時のみ非 nil: 音声を PCM デコードで読む専用リーダー
        /// （トリム時はトリム範囲に制限。export の doc 参照）。
        audioReader: AVAssetReader?,
        writer: AVAssetWriter,
        outputURL: URL,
        /// 無装着は `AVAssetReaderTrackOutput`、videoComposition 装着時は
        /// `AVAssetReaderVideoCompositionOutput`（共通の基底型で受ける）。
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        /// パススルーは AVAssetReaderTrackOutput、再エンコードは
        /// AVAssetReaderAudioMixOutput（共通の基底型で受ける）。
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?,
        duration: CMTime,
        videoSize: CGSize,
        selectedFaceTargets: [FaceTarget],
        objectMasks: [ObjectMask],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]],
        mapping: TimelineMapping,
        faceEnabled: Bool,
        objectEnabled: Bool,
        backgroundEnabled: Bool,
        backgroundBlock: Float,
        speed: ExportSpeed,
        trimStartSec: Double,
        trimEndSec: Double,
        /// 再エンコード時のみ非 nil: writer タイムライン上で音声を打ち切る上限秒
        /// （= 出力の想定尺）。`clampAudioSample` の doc 参照。
        audioEndLimitSec: Double?,
        cache: CVMetalTextureCache,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let detectionInterval = speed.detectionInterval
        detectMaxWidth = speed.detectionMaxWidth
        // 同一 exporter インスタンスの再利用に備え、前回 export の EMA 状態と
        // 選択顔トラッカー（前回の追従位置）を捨てる。
        landmarkSmoother.reset()
        selectedTracker = nil
        resetPerf()

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()

            // 映像：必要になったタイミングでだけコールバックが呼ばれる（Thread.sleep 不要）。
            var loop = FrameLoopState()
            let videoQueue = DispatchQueue(label: "mask-me.export.video")
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                while videoInput.isReadyForMoreMediaData {
                    // 中断点①: 次のサンプルを読む**前**に見る。ここで抜けても
                    // markAsFinished → group.notify → cancelWriting の順は保たれる
                    // （cancelWriting 後に markAsFinished を呼ぶと例外で落ちる）。
                    if isCancelRequested {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let decodeStart = CFAbsoluteTimeGetCurrent()
                    let nextSample = videoOutput.copyNextSampleBuffer()
                    perfDecodeSec += CFAbsoluteTimeGetCurrent() - decodeStart
                    guard reader.status == .reading, let sample = nextSample else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    // フレーム毎の一時オブジェクトを都度解放し、長尺でのジェットサムを防ぐ。
                    autoreleasepool {
                        processVideoSample(
                            sample,
                            loop: &loop,
                            detectionInterval: detectionInterval,
                            selectedFaceTargets: selectedFaceTargets,
                            objectMasks: objectMasks,
                            detectionCaches: detectionCaches,
                            mapping: mapping,
                            faceEnabled: faceEnabled,
                            objectEnabled: objectEnabled,
                            backgroundEnabled: backgroundEnabled,
                            backgroundBlock: backgroundBlock,
                            videoSize: videoSize,
                            totalSeconds: totalSeconds,
                            trimStartSec: trimStartSec,
                            adaptor: adaptor,
                            input: videoInput,
                            cache: cache,
                            progress: progress
                        )
                    }
                }
            }

            // 音声：パススルー（無変換構成）はサンプルをそのままコピー。
            // 再エンコード（audioReader 非 nil）はデコード済み PCM を受け取って
            // AAC 入力へ渡す。トリム時は timeRange で切られた PCM の PTS を
            // trimStart 分シフトして writer タイムラインを 0 起点に揃える（トリム精度は
            // PCM サンプル単位。映像側 shiftSample と同じ 0 起点に一致する）。
            if let audioInput, let audioOutput {
                group.enter()
                startAudioPump(
                    sourceReader: audioReader ?? reader,
                    cancelableReader: audioReader,
                    output: audioOutput,
                    input: audioInput,
                    trimStartSec: trimStartSec,
                    audioEndLimitSec: audioEndLimitSec,
                    onFinish: { group.leave() })
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                self.logPerfSummary(totalSeconds: totalSeconds)
                self.finish(
                    writer: writer,
                    readerError: Self.readerFailure(reader: reader, audioReader: audioReader),
                    outputURL: outputURL, progress: progress, continuation: continuation)
            }
        }
    }

    /// 読み書きが両方終わったあとの決着（`pump` の `group.notify` から 1 回だけ呼ぶ）。
    ///
    /// 判定順を守ること:
    /// 1. **自前の中断フラグ**（`AVAssetReader.status` は `.cancelled` を `.failed` と
    ///    区別せず、`startAudioPump` は正常系でも `cancelReading()` を呼ぶため
    ///    状態からは中断を判定できない）
    /// 2. reader の失敗
    /// 3. writer の完了／失敗
    ///
    /// 失敗・中断のどの経路でも、途中まで書いた `mosaic-*.mp4` を tmp に残さない。
    private func finish(
        writer: AVAssetWriter,
        /// 読み出し側の失敗（無ければ nil）。`readerFailure(reader:audioReader:)` で求める。
        readerError: Error?,
        outputURL: URL,
        progress: @Sendable @escaping (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        // 両入力とも markAsFinished 済みなのでここで cancelWriting しても安全
        // （逆順に呼ぶと markAsFinished が例外で落ちる）。
        if isCancelRequested {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: CancellationError())
            return
        }
        if let readerError {
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: readerError)
            return
        }
        writer.finishWriting {
            if writer.status == .completed {
                progress(1.0)
                continuation.resume(returning: outputURL)
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(throwing: writer.error ?? ExportError.writerSetupFailed)
            }
        }
    }

    /// 読み出し側が失敗していればその原因（していなければ nil）。
    ///
    /// **`.cancelled` は失敗として扱わない**（`startAudioPump` は末尾クランプという
    /// 正常系でも `cancelReading()` を呼ぶ。中断の判定は自前フラグの仕事）。
    private static func readerFailure(reader: AVAssetReader,
                                      audioReader: AVAssetReader?) -> Error? {
        guard reader.status == .failed || audioReader?.status == .failed else { return nil }
        return reader.error ?? audioReader?.error ?? ExportError.readerSetupFailed
    }

    // 引数が多いのは読み書きの相手（リーダー/出力/入力）と時間軸の補正値を
    // 1 つのループに集約しているため。まとめる型を増やすより素直に渡す。
    // swiftlint:disable function_parameter_count
    /// 音声の読み書きループを writer 入力へ結線する（`pump` から 1 回だけ呼ぶ）。
    ///
    /// - Parameters:
    ///   - sourceReader: 読み出し元。再エンコード時は音声専用リーダー、
    ///     パススルー時は主リーダー。状態監視にだけ使う。
    ///   - cancelableReader: 途中で止めてよいリーダー（音声専用のときだけ非 nil）。
    ///     主リーダーと同一のときに止めると映像を巻き添えにするため分けて受け取る。
    ///   - trimStartSec: >0.001 のとき PTS をこの秒数ぶん負方向へシフトし、
    ///     writer タイムラインを 0 起点に揃える。
    ///   - audioEndLimitSec: 再エンコード時のみ非 nil。writer タイムライン上の末尾上限。
    ///     シフトの有無とは独立に適用する（トリムしない rate≠1 でも余剰は出る）。
    ///   - onFinish: 音声の書き込みが終わったとき 1 回だけ呼ぶ。
    private func startAudioPump(
        sourceReader: AVAssetReader,
        cancelableReader: AVAssetReader?,
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        trimStartSec: Double,
        audioEndLimitSec: Double?,
        onFinish: @escaping () -> Void
    ) {
        let audioQueue = DispatchQueue(label: "mask-me.export.audio")
        input.requestMediaDataWhenReady(on: audioQueue) { [self] in
            while input.isReadyForMoreMediaData {
                // 中断点②: 映像側と同じく、読み出しの前に自前フラグで見る。
                if isCancelRequested {
                    input.markAsFinished()
                    onFinish()
                    return
                }
                guard sourceReader.status == .reading,
                      let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    onFinish()
                    return
                }
                // セグメント境界で samples=0・pts 不定のマーカーバッファが
                // 届くことがある（マルチクリップ composition の実測）。
                // writer に渡すと失敗するため読み飛ばす。
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                // シフト失敗（タイミング情報が取れない異常バッファ）は落とす。
                // 未シフトのまま書くと出力タイムラインが壊れる。
                let placed = trimStartSec > 0.001
                    ? Self.shiftSample(sample, byMinusSeconds: trimStartSec)
                    : sample
                guard let placed else { continue }
                guard let limit = audioEndLimitSec else {
                    input.append(placed)
                    continue
                }
                switch Self.clampAudioSample(placed, toEndSeconds: limit) {
                case .append(let clamped):
                    input.append(clamped)
                case .finished(let ptsSec):
                    print(String(format: "[MMEXPORT] audio tail clamp: limit=%.3fs "
                                 + "firstDroppedPts=%.3fs", limit, ptsSec))
                    input.markAsFinished()
                    // 残りは全部範囲外なのでデコードを続ける意味がない。
                    cancelableReader?.cancelReading()
                    onFinish()
                    return
                }
            }
        }
    }

    // swiftlint:enable function_parameter_count

    /// 映像ループがフレーム間で持ち越す状態。`pump` がローカルに 1 つ持ち、
    /// `processVideoSample` が毎フレーム更新する（export ごとに作り直す）。
    ///
    /// 「直前フレームとの差分で判断する」項目だけを集めてある。個別の inout 引数で
    /// 渡していたものを 1 つにまとめたのは、S10 でゲート状態が増えて
    /// `processVideoSample` の引数が 20 を超えたため（挙動は不変）。
    private struct FrameLoopState {
        var frameIndex = 0
        /// 直前フレームが属していたクリップ（境界跨ぎの時系列リセット判定用）。
        var previousClipID: UUID?
        var cachedLandmarkSets: [FaceLandmarkSet] = []
        var cachedBackgroundMask: MaskBuffer?
        /// 直前フレームのモザイク適用区間ゲートの状態（S10）。nil = まだ 1 枚も
        /// 処理していない。区間へ再入した最初のフレームで、検出間引きに関係なく
        /// 検出をやり直すために持つ（さもないと再入直後の数フレームが空のまま出る）。
        ///
        /// **真偽値ではなく「適用対象の素材ID集合」で持つ**理由: トランジションの重なり
        /// 区間では 2 素材が同時に映り、片方だけが区間から外れることがある。真偽値
        /// （どれか 1 つでも ON）だけを見ていると、片側が ON→OFF になったフレームで
        /// 変化が観測できず強制再検出が走らないため、**両素材ぶんの古い union**が
        /// そのまま使われ続けて区間外の素材にモザイクが焼き込まれる。
        var previousActiveSourceIDs: Set<UUID>?
    }

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count
    private func processVideoSample(
        _ sample: CMSampleBuffer,
        loop: inout FrameLoopState,
        detectionInterval: Int,
        selectedFaceTargets: [FaceTarget],
        objectMasks: [ObjectMask],
        detectionCaches: [UUID: [Double: [FaceLandmarkSet]]],
        mapping: TimelineMapping,
        faceEnabled: Bool,
        objectEnabled: Bool,
        backgroundEnabled: Bool,
        backgroundBlock: Float,
        videoSize: CGSize,
        totalSeconds: Double,
        trimStartSec: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        cache: CVMetalTextureCache,
        progress: (Double) -> Void
    ) {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let rawPts = CMSampleBufferGetPresentationTimeStamp(sample)
        // トリム時は writer の 0 起点に揃えるため PTS をシフトする。
        // 検出（timestampMs）と写像・キャッシュ検索は合成時刻（rawPts）のままで
        // 一貫させる（シフト済み pts を写像に通すと「シフト＋写像」の二重適用になる。
        // シフトは writer タイムライン専用）。
        let pts: CMTime
        if trimStartSec > 0.001 {
            let shifted = CMTimeGetSeconds(rawPts) - trimStartSec
            pts = CMTime(seconds: max(0, shifted), preferredTimescale: 600)
        } else {
            pts = rawPts
        }
        let timeSec = CMTimeGetSeconds(rawPts)
        let timestampMs = Int(timeSec * 1000)

        // 合成時刻 → 素材位置（クリップ・素材ID・素材内時刻）。
        let location = resolveLocation(mapping, at: timeSec)
        // クリップ境界を跨いだフレームは時系列状態をリセットし、
        // 検出間引きに関係なく検出し直す（前クリップの顔位置を持ち越さない）。
        let crossedClipBoundary = resetAtClipBoundary(
            location: location, previousClipID: &loop.previousClipID,
            cachedLandmarkSets: &loop.cachedLandmarkSets,
            cachedBackgroundMask: &loop.cachedBackgroundMask)

        // モザイク適用区間ゲート（S10）。判定時刻は**このフレームの合成時刻**
        // （writer 用にシフトする前の timeSec）で、写像・キャッシュ検索に使うのと同じ値。
        // プレビュー（`MosaicEditorModel.isMosaicActive(atComposition:)`）と同一の純関数を
        // 通すので、「合成時刻 → 素材ID/素材時刻 → isActive」の順序と時刻の意味が両経路で揃う。
        let gate = MosaicApplyGate.gateState(ranges: applyRanges, mapping: mapping,
                                             compositionTime: timeSec,
                                             photoSourceIDs: photoSourceIDs)
        let mosaicActive = gate.isActive
        // 区間へ再入した最初のフレームは、間引きに関係なく検出し直す
        // （区間外で捨てた顔・マスクが空のまま数フレーム出力されるのを防ぐ）。
        // 判定は真偽値ではなく**適用対象の素材集合**の変化で行う。重なり区間で
        // 片方の素材だけが ON→OFF になったフレームは、真偽値では変化が見えないのに
        // 顔の union の中身は変わっている（`FrameLoopState.previousActiveSourceIDs` の doc）。
        let gateChanged = loop.previousActiveSourceIDs != gate.activeSourceIDs
        loop.previousActiveSourceIDs = gate.activeSourceIDs

        if !mosaicActive {
            // 区間外は素の映像。顔・手動矩形・背景モザイクのすべてを止める
            // （顔だけ止めて背景が乗り続けるのは要件違反）。保持中の顔位置と
            // 背景マスクは区間へ戻ったときには別時刻のものなので、ここで捨てる。
            // 検出そのものを走らせないぶん、区間外が長いほど書き出しが速くなる。
            loop.cachedLandmarkSets = []
            loop.cachedBackgroundMask = nil
            landmarkSmoother.reset()
        } else if loop.frameIndex % detectionInterval == 0 || crossedClipBoundary || gateChanged {
            refreshDetection(
                DetectionFrame(sourceBuffer: sourceBuffer, timeSec: timeSec,
                               timestampMs: timestampMs, location: location, mapping: mapping,
                               detectionCaches: detectionCaches,
                               selectedFaceTargets: selectedFaceTargets,
                               faceEnabled: faceEnabled, backgroundEnabled: backgroundEnabled),
                cachedLandmarkSets: &loop.cachedLandmarkSets,
                cachedBackgroundMask: &loop.cachedBackgroundMask)
        }

        // 物体マスクは顔とは独立（`objectEnabled`）。プレビューと同じ判定にすること。
        let additionalPaths = objectEnabled
            ? objectMaskPlacements(objectMasks, mapping: mapping, at: timeSec, location: location)
                .map { FaceMaskBuilder.RegionPath(
                    path: FaceMaskBuilder.rectPath(from: $0.rect, angle: $0.angle, in: videoSize),
                    value: 0.4) }
            : []

        // テキスト（E3-2）はモザイク適用区間ゲートとは独立。「どれが出ているか」は
        // `visibleTextItems`（プレビューと共有する配列拡張）だけが決める。判定時刻は
        // 検出・ゲートと同じ timeSec（写像・トリムシフト前の合成時刻）。
        let visibleText = textItems.isEmpty
            ? []
            : textItems.visibleTextItems(atComposition: timeSec, totalDuration: textTotalDuration)

        // 色調補正（P4）。判定時刻はテキスト・検出ゲートと同じ timeSec
        // （写像・トリムシフト前の合成時刻）。`mapping` が空（素の AVAsset 書き出し・
        // クリップ未構築）なら `sourceLocations` が空を返し `.identity` に落ちる
        // （`colorGrade(mapping:at:)` の doc 参照）。
        let grade = colorGrade(mapping: mapping, at: timeSec)

        let r0 = CFAbsoluteTimeGetCurrent()
        try? mosaicFrame(
            sourceBuffer: sourceBuffer,
            pts: pts,
            landmarkSets: loop.cachedLandmarkSets,
            additionalPaths: additionalPaths,
            backgroundMask: loop.cachedBackgroundMask,
            backgroundBlock: backgroundBlock,
            textItems: visibleText,
            textCompositionTime: timeSec,
            colorGrade: grade,
            adaptor: adaptor,
            input: input,
            cache: cache
        )
        perfRenderSec += CFAbsoluteTimeGetCurrent() - r0
        perfFrames += 1

        // Metal テクスチャキャッシュに溜まった参照を解放。
        CVMetalTextureCacheFlush(cache, 0)

        loop.frameIndex += 1
        // トリム時は「トリム範囲内の進捗」で 0..1 化して表示する。
        let progressSec = max(0, timeSec - trimStartSec)
        progress(min(progressSec / totalSeconds, 1.0))
    }

    /// 検出更新 1 回ぶんの入力（`processVideoSample` から `refreshDetection` へ渡す組）。
    private struct DetectionFrame {
        let sourceBuffer: CVPixelBuffer
        /// 合成時刻（写像・キャッシュ検索用。writer のシフト前）。
        let timeSec: Double
        let timestampMs: Int
        /// 写像で解決した素材位置（重なり区間では incoming 側）。
        let location: TimelineMapping.SourceLocation?
        let mapping: TimelineMapping
        let detectionCaches: [UUID: [Double: [FaceLandmarkSet]]]
        let selectedFaceTargets: [FaceTarget]
        let faceEnabled: Bool
        let backgroundEnabled: Bool
    }

    /// 検出間隔ごとに顔ランドマークと背景マスクを更新する。
    ///
    /// 顔は「キャッシュ（重なり区間は両クリップの union）→ 無ければその場検出」の順。
    /// 背景マスクも同じ間隔で更新する（毎フレームは重いため）。
    private func refreshDetection(_ frame: DetectionFrame,
                                  cachedLandmarkSets: inout [FaceLandmarkSet],
                                  cachedBackgroundMask: inout MaskBuffer?) {
        if frame.faceEnabled {
            // 素材スコープのキャッシュから近傍フレームを探す（なければ新規検出）。
            // 参照キーは写像済みの素材内時刻（丸め・近傍補間は写像の後）。
            let fromCache: [FaceLandmarkSet]
            // `fromCache` に対応する署名。用意できない経路では空のまま
            // （＝位置追跡だけの従来判定へ落ちる）。
            var cacheSignatures: [FaceSignature?] = []
            // 写真素材で t=0 の seed が「検出済みで顔なし」（空エントリ）のとき true。
            // 写真は全フレーム同一なので、seed が空でも実検出には落とさない
            // （毎フレーム同じ静止画を再検出する無駄と、seed と食い違う結果の混入を防ぐ）。
            var photoSeededEmpty = false
            if let overlapFaces = transitionFaces(mapping: frame.mapping, at: frame.timeSec,
                                                  detectionCaches: frame.detectionCaches) {
                // トランジションの重なり区間: 両クリップの顔を union（S8）。
                // ここで片側しか見ないと、画面に映っているもう片方の顔が素通しになる。
                fromCache = overlapFaces
            } else if let location = frame.location,
                      let sourceCache = frame.detectionCaches[location.sourceID] {
                // 署名は**素材座標**で引く（サンプルの重心が素材座標なので、
                // レターボックス写像の後で引くと位置が合わず対応が付かなくなる）。
                // `renderLayout.remap` は順序も件数も変えないため、写した後も添字は一致する。
                let inSource = lookupCache(sourceCache, at: location.time)
                cacheSignatures = identitySignatures.signatures(
                    for: inSource, sourceID: location.sourceID, time: location.time)
                fromCache = renderLayout.remap(inSource, clipID: location.clipID)
                photoSeededEmpty = fromCache.isEmpty
                    && photoSourceIDs.contains(location.sourceID)
                    && sourceCache[0] != nil
            } else {
                fromCache = []
            }
            if !fromCache.isEmpty {
                cachedLandmarkSets = filterToSelected(fromCache, targets: frame.selectedFaceTargets,
                                                      signatures: cacheSignatures)
            } else if photoSeededEmpty {
                cachedLandmarkSets = []
            } else {
                // その場検出は**合成済みフレーム**に対して走るので、結果は既に
                // 合成フレーム基準（レターボックス・トランジション適用後）＝写像不要。
                let t0 = CFAbsoluteTimeGetCurrent()
                let detected = detectAll(in: frame.sourceBuffer, timestampMs: frame.timestampMs)
                perfDetectSec += CFAbsoluteTimeGetCurrent() - t0
                perfDetectCalls += 1
                // その場検出には署名が無い（作るには合成済みフレームから埋め込みを
                // 計算する必要があり、書き出し速度に直に効く）。位置追跡だけで判定する。
                cachedLandmarkSets = filterToSelected(detected, targets: frame.selectedFaceTargets,
                                                      signatures: [])
            }
            // 描画直前の EMA。検出更新のタイミング（= 位置が変わりうる瞬間）にだけかける。
            cachedLandmarkSets = landmarkSmoother.smooth(cachedLandmarkSets)
        } else {
            cachedLandmarkSets = []
        }
        // セグメンテーションが一時的に失敗（nil）したら直前のマスクを維持する。
        // nil で上書きすると、その間のフレームで背景が無加工のまま書き出されてしまう。
        if frame.backgroundEnabled {
            let s0 = CFAbsoluteTimeGetCurrent()
            let mask = segmentBackground(frame.sourceBuffer)
            perfSegSec += CFAbsoluteTimeGetCurrent() - s0
            if let mask {
                cachedBackgroundMask = mask
            }
        } else {
            cachedBackgroundMask = nil
        }
    }

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable:next function_parameter_count
    private func mosaicFrame(
        sourceBuffer: CVPixelBuffer,
        pts: CMTime,
        landmarkSets: [FaceLandmarkSet],
        additionalPaths: [FaceMaskBuilder.RegionPath],
        backgroundMask: MaskBuffer?,
        backgroundBlock: Float,
        textItems: [TextItem],
        textCompositionTime: Double,
        colorGrade: ColorGrade,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        cache: CVMetalTextureCache
    ) throws {
        guard let inputTexture = MetalTextureUtilities.texture(from: sourceBuffer, cache: cache) else {
            throw ExportError.textureConversionFailed
        }
        guard let pool = adaptor.pixelBufferPool,
              let outBuffer = makePixelBuffer(from: pool),
              let outputTexture = MetalTextureUtilities.texture(from: outBuffer, cache: cache) else {
            throw ExportError.pixelBufferPoolUnavailable
        }

        // 色調補正（P4）は「モザイクの前」（`ColorGradeCompositor` の doc・規則 1）。
        // 検出（`refreshDetection`）は `frame.sourceBuffer`（この `inputTexture` の
        // 元になった生バッファ）を直接見ており、この合成を経由しないので影響を受けない
        // （規則 3）。`grade.isIdentity` なら `ColorGradeCompositor.apply` が
        // `inputTexture` をそのまま返すので 1 パスも発行されない。
        let gradedTexture = ColorGradeCompositor.apply(grade: colorGrade, renderer: renderer, input: inputTexture)

        // 背景パスがある場合は、顔モザイクを中間テクスチャに描いてから背景を出力に重ねる。
        // どちらの分岐も最終的に `outputTexture` へモザイク済みの絵を書く。
        if let backgroundMask,
           let intermediate = MetalTextureUtilities.makeOutputTexture(like: gradedTexture, device: renderer.device) {
            renderer.render(
                input: gradedTexture, into: intermediate,
                landmarkSets: landmarkSets, additionalPaths: additionalPaths,
                waitForCompletion: true
            )
            renderer.renderBackground(
                input: intermediate, into: outputTexture,
                mask: backgroundMask,
                block: backgroundBlock, waitForCompletion: true
            )
        } else {
            renderer.render(
                input: gradedTexture, into: outputTexture,
                landmarkSets: landmarkSets, additionalPaths: additionalPaths,
                waitForCompletion: true
            )
        }

        // レターボックス（余白）の塗り（S13）。**モザイクの後・テキストの前**に置く。
        //
        // - モザイクの**後**でなければならない: ぼかしはこのテクスチャを読んで作るので、
        //   焼く前を渡すと素顔が余白へ拡大されて出る（`TimelineBackground` の型 doc）。
        // - テキストの**前**でなければならない: 文字・ステッカーは出力枠基準で置かれ、
        //   余白の上にも置ける。後に塗ると、余白に置いた文字が塗り潰される。
        //
        // 塗るのは `letterboxContentRect`（全クリップの配置矩形の和）の**外側だけ**。
        // 中は 1 ピクセルも触らないので、モザイクを塗り潰して顔を出す形の事故は起きない。
        let letterboxedTexture = LetterboxCompositor.apply(
            background: letterbox, contentRect: letterboxContentRect,
            renderer: renderer, input: outputTexture)

        // テキスト（E3-2）は「モザイク → テキスト」の順で常に最後に重ねる。
        // プレビューと同じ `TextOverlayCompositor` を通すことで、位置・サイズの
        // px 換算とアニメーションの数式が両経路で一致する。
        let texturedTexture = textItems.isEmpty
            ? letterboxedTexture
            : TextOverlayCompositor.apply(items: textItems, at: textCompositionTime,
                                          renderer: renderer, cache: textOverlayCache,
                                          input: letterboxedTexture)

        // 無料プランの透かし（課金 P2）を「モザイク → テキスト → 透かし」の順で最後に重ねる。
        // プレビューと同じ `WatermarkCompositor` / `ExportWatermark` を通す
        // （`needsWatermark` の判定根拠は `Built.exportRestriction` の 1 箇所。doc 参照）。
        let finalTexture = needsWatermark
            ? WatermarkCompositor.apply(renderer: renderer, cache: textOverlayCache, input: texturedTexture)
            : texturedTexture

        // テキスト合成が新規テクスチャを作った場合、`outputTexture`（pixelBuffer 由来の
        // texture）へ書き戻してから append する。`outBuffer` の中身を最終結果にするため。
        if finalTexture !== outputTexture {
            renderer.copyTexture(from: finalTexture, into: outputTexture, waitForCompletion: true)
        }

        // 呼び出し側が isReadyForMoreMediaData を確認済みなのでビジーウェイト不要。
        adaptor.append(outBuffer, withPresentationTime: pts)
    }

    /// 動画フレームの背景マスク（人物前景を反転）。Vision 非対応環境では nil。
    private func segmentBackground(_ buffer: CVPixelBuffer) -> MaskBuffer? {
        #if canImport(Vision)
        return backgroundSegmenter.backgroundMask(pixelBuffer: buffer)
        #else
        return nil
        #endif
    }

    // MARK: - Detection helpers

    private func detectAll(in buffer: CVPixelBuffer, timestampMs: Int) -> [FaceLandmarkSet] {
        let ci = CIImage(cvPixelBuffer: buffer)
        let scale = min(detectMaxWidth / ci.extent.width, 1.0)
        let resized = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(resized, from: resized.extent) else { return [] }
        return landmarker.allLandmarks(in: UIImage(cgImage: cg), timestampMs: timestampMs)
    }

    /// 検出キャッシュの両側補間参照。仕様は `DetectionBridge` を参照
    /// （MosaicEditorModel のプレビューおよび精度計測と共通の挙動）。lerp 有効。
    /// `cache` は素材スコープ（キーは素材内時刻）、`time` は写像済みの素材内時刻。
    private func lookupCache(_ cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        DetectionBridge(interpolates: true).faces(in: cache, at: time)
    }

    /// 指定した合成時刻に効く色調補正（P4）。
    ///
    /// 合成時刻に効く色調補正。**手順は `ColorGradeResolver.resolve`（コア層）が唯一の
    /// 実装**で、ここはクリップの引き方（`colorGrades` の辞書引き）を渡すだけ。
    ///
    /// このクラスは `TimelineState` を持たないので
    /// `TimelineState.colorGrade(atComposition:)` はそのまま呼べないが、**だからと
    /// いって同じ手順を書き写さない。** 書き写すと、プレビュー（`TimelineState` 側）と
    /// 書き出し（ここ）で片方だけ変わって黙ってずれる——この案件が繰り返してきた
    /// 事故の形そのものになる。
    private func colorGrade(mapping: TimelineMapping, at compositionTime: Double) -> ColorGrade {
        ColorGradeResolver.resolve(mapping: mapping, at: compositionTime) { [colorGrades] clipID in
            colorGrades[clipID] ?? .identity
        }
    }

    /// 合成時刻を素材位置へ解決する。半開区間の外に出た有限時刻（終端フレームの
    /// PTS 揺らぎ）はタイムライン端へクランプして写像する
    /// （`MosaicEditorModel.resolveSourceTime(atComposition:)` と同じ規則）。
    /// 写真素材（`photoSourceIDs`）は写像の**後**に素材時刻を 0 へ clamp する
    /// （`TimelineState.clampedSourceTime` と同じ規則。clipID はそのまま残すので
    /// クリップ境界の時系列リセット判定には影響しない）。
    /// 写像が空（クリップなし）のときは nil（キャッシュ参照なし・自前検出）。
    ///
    /// **S8 の重なり区間でも単一位置（incoming 側）のままで正しい**ため、この経路は
    /// 残してある。用途が「クリップ境界の時系列リセット判定（`resetAtClipBoundary`）」
    /// と「重なり**外**のキャッシュ参照」の 2 つに限られるからである:
    /// 前者は重なり開始 = incoming への切り替わりで 1 回だけリセットしたい（重なり中に
    /// 毎フレーム 2 クリップぶんリセットしたいわけではない）。後者は重なり中には
    /// 呼ばれない（`transitionFaces` が先に union を返す）。
    private func resolveLocation(
        _ mapping: TimelineMapping, at compositionTime: Double
    ) -> TimelineMapping.SourceLocation? {
        var resolved = mapping.sourceLocation(at: compositionTime)
        if resolved == nil, compositionTime.isFinite, mapping.totalDuration > 0 {
            let clamped = min(max(compositionTime, 0), mapping.totalDuration.nextDown)
            resolved = mapping.sourceLocation(at: clamped)
        }
        guard let location = resolved else { return nil }
        guard photoSourceIDs.contains(location.sourceID) else { return location }
        return TimelineMapping.SourceLocation(
            clipID: location.clipID, sourceID: location.sourceID, time: 0)
    }

    /// トランジションの重なり区間で、両クリップの顔を視覚変換込みで union する（S8）。
    ///
    /// 重なり区間では画面に 2 クリップが同時に映るので、**両方の顔にモザイクが要る**。
    /// `TimelineMapping.sourceLocations(at:)` の 1〜2 要素それぞれについて
    ///
    /// 1. 素材スコープのキャッシュを引き（写真素材は素材時刻 0 へ clamp）、
    /// 2. `TimelineRenderLayout` で合成フレーム基準へ写し、
    /// 3. `TransitionKind.visibleLandmarks` で視覚変換（移動・可視判定）を適用する
    ///
    /// という順で処理する。3 は `AVVideoComposition` の instruction ランプと**同じ純関数**
    /// から生成されるので、顔位置とフレームが必ず一致する。
    ///
    /// **既知の割り切り（S8）**: 重なり区間で「片方のクリップの顔だけを選択」している場合、
    /// union した両側の顔が後段の `SelectedFaceTracker`（重心の閾値 0.5）を両方通り、
    /// 未選択側の顔にもモザイクが乗ることがある（crossfade・D=1.0s の実測で、検出更新 10 回に
    /// 対して残った顔が延べ 19）。重なり中の 1 秒未満だけの過剰適用であり、
    /// **モザイクの過剰適用は安全側・不足は事故**なのでこのまま倒す。
    /// 直すには選択顔の同一性をクリップ単位で持つ必要があり、S8 の範囲を超える。
    ///
    /// **モザイク適用区間のゲートは素材ごとにここで掛ける（S10 レビュー修正）。**
    /// 重なり区間で素材 A だけが適用区間内なら、B の顔は union に入れない。
    /// フレーム単位の合成時刻ゲート（`isActive(ranges:mapping:compositionTime:)`）は
    /// 「どれか 1 つでも区間内なら ON」なので、それだけでは重なり区間で**区間ゼロの素材の
    /// 顔にもモザイクが乗る**（実測: 8px 市松素材の crossfade 0.5s 重なり 15 フレーム中
    /// 12 フレームで、区間外の素材側 MAD が 25.8 → 95.9〜105.7 へ跳ね上がった）。
    /// プレビュー（`MosaicEditorModel.displayFaces(at:matching:)`）は同じ純関数・同じ
    /// 引数で素材別にゲートしているので、ここを揃えないとプレビューと書き出しが食い違い、
    /// ユーザーは書き出すまで気づけない。
    ///
    /// なお union が空になった場合、呼び出し側（`refreshDetection`）は従来どおり
    /// その場検出へ落ちる。「適用区間内の素材にキャッシュが無い」ケースなので
    /// 過剰適用側（安全側）であり、全素材が区間外のケースはそもそも
    /// `mosaicActive == false` で `refreshDetection` 自体が呼ばれない。
    ///
    /// - Returns: 重なり区間なら union（空もあり得る）、重なり外なら nil
    ///   （呼び出し側は従来どおり単一位置の経路へ落ちる）。
    private func transitionFaces(mapping: TimelineMapping,
                                 at compositionTime: Double,
                                 detectionCaches: [UUID: [Double: [FaceLandmarkSet]]])
    -> [FaceLandmarkSet]? {
        let locations = mapping.sourceLocations(at: compositionTime)
        guard locations.count >= 2,
              let overlap = mapping.overlap(at: compositionTime) else { return nil }
        return locations.flatMap { entry -> [FaceLandmarkSet] in
            guard let side = entry.side, let progress = entry.progress,
                  let sourceCache = detectionCaches[entry.location.sourceID] else { return [] }
            // 写真素材の素材時刻は 0 へ clamp（`resolveLocation` と同じ規則）。
            let sourceTime = photoSourceIDs.contains(entry.location.sourceID) ? 0 : entry.location.time
            guard MosaicApplyGate.isActive(ranges: applyRanges,
                                           clipID: entry.location.clipID,
                                           sourceID: entry.location.sourceID,
                                           sourceTime: sourceTime) else { return [] }
            let cached = lookupCache(sourceCache, at: sourceTime)
            let placed = renderLayout.remap(cached, clipID: entry.location.clipID)
            return overlap.kind.visibleLandmarks(placed, progress: progress, side: side)
        }
    }

    /// このフレームに描く物体マスクの矩形（**合成フレーム基準**）。
    ///
    /// プレビュー（`MosaicEditorModel.objectMaskPlacements(atComposition:)`）と同じ順序・
    /// 同じ純関数（`ObjectMaskResolver` / `TransitionKind.visibleRect`）で解く。
    /// 揃えないとプレビューと書き出しが食い違い、ユーザーは書き出すまで気づけない。
    ///
    /// ゲートは合成時刻でまとめた `mosaicActive` ではなく**素材ごとの判定**を使う。
    /// マスクは素材アンカー（clipID + 素材時刻）を持つので、顔と同じく素材別に
    /// ON/OFF できる（重なり区間で片側だけ ON にできる）。
    private func objectMaskPlacements(_ masks: [ObjectMask], mapping: TimelineMapping,
                                      at compositionTime: Double,
                                      location: TimelineMapping.SourceLocation?)
        -> [ObjectMaskPlacement] {
        guard !masks.isEmpty else { return [] }
        let locations = mapping.sourceLocations(at: compositionTime)
        if locations.count >= 2, let overlap = mapping.overlap(at: compositionTime) {
            return locations.flatMap { entry -> [ObjectMaskPlacement] in
                guard let side = entry.side, let progress = entry.progress else { return [] }
                let sourceTime = photoSourceIDs.contains(entry.location.sourceID) ? 0 : entry.location.time
                guard MosaicApplyGate.isActive(ranges: applyRanges, clipID: entry.location.clipID,
                                               sourceID: entry.location.sourceID,
                                               sourceTime: sourceTime) else { return [] }
                return ObjectMaskResolver.placements(masks, tracks: objectTracks,
                                                     clipID: entry.location.clipID,
                                                     sourceTime: sourceTime, layout: renderLayout)
                    // 傾きは切り取りで変わらないので持ち回る（プレビュー側と同じ扱い）。
                    .compactMap { placed in
                        overlap.kind.visibleRect(placed.rect, progress: progress, side: side)
                            .map { ObjectMaskPlacement(rect: $0, angle: placed.angle) }
                    }
            }
        }
        // 写像不能（クリップ無し = 素の AVAsset 書き出し）はゲートがフェイルオープンする
        // 側に倒す（`MosaicApplyGate.isActive` の doc と同じ判断）。
        guard let location else {
            return ObjectMaskResolver.placements(masks, tracks: objectTracks,
                                                 clipID: nil, sourceTime: 0, layout: renderLayout)
        }
        guard MosaicApplyGate.isActive(ranges: applyRanges, clipID: location.clipID,
                                       sourceID: location.sourceID,
                                       sourceTime: location.time) else { return [] }
        return ObjectMaskResolver.placements(masks, tracks: objectTracks,
                                             clipID: location.clipID,
                                             sourceTime: location.time, layout: renderLayout)
    }

    /// クリップ境界を跨いだ最初のフレームで時系列状態をリセットする。
    ///
    /// EMA（landmarkSmoother）・保持中の顔位置・背景マスク・選択顔トラッカーは
    /// すべて「直前フレームと映像内容が連続している」前提の状態なので、別クリップに
    /// 入ったら持ち越さない（境界直後のフレームに前クリップの顔位置・マスクがにじむ）。
    /// 単一クリップ・写像なしでは clipID が変わらないため呼んでも何も起きない。
    /// - Returns: 境界を跨いだかどうか（true のフレームは間引きに関係なく再検出する）。
    private func resetAtClipBoundary(
        location: TimelineMapping.SourceLocation?,
        previousClipID: inout UUID?,
        cachedLandmarkSets: inout [FaceLandmarkSet],
        cachedBackgroundMask: inout MaskBuffer?
    ) -> Bool {
        guard location?.clipID != previousClipID else { return false }
        let crossedBoundary = previousClipID != nil
        previousClipID = location?.clipID
        guard crossedBoundary else { return false }
        landmarkSmoother.reset()
        selectedTracker = nil
        cachedLandmarkSets = []
        cachedBackgroundMask = nil
        return true
    }

    /// 選択顔の時系列トラッカー。旧実装は選択時の静的位置と距離 0.3 で毎フレーム照合
    /// しており、顔が移動しただけで書き出し動画からモザイクが消えていた
    /// （実機報告「フレームアウト→イン／後ろ向き→正面のあと一切掛からない」の
    /// エクスポート側の原因）。SelectedFaceTracker がマッチのたびに位置を追従させる。
    private var selectedTracker: SelectedFaceTracker?

    /// 選択顔だけを残す。**判定はプレビューと同じ純関数**（`FaceIdentityPolicy.hidden`）を
    /// 通す。ここを別々に書くと、画面では隠れているのに保存した動画では素で映る、という
    /// 最悪の食い違いが起きる。位置追跡（`SelectedFaceTracker`）は書き出し側の
    /// 時系列追跡のまま使い、その結果を「位置はどう言っているか」として渡す。
    ///
    /// - Parameter signatures: `faces` と同じ順・同じ件数の署名。用意できない経路
    ///   （その場検出・トランジションの重なり）は空を渡す＝従来どおり位置追跡だけになる。
    private func filterToSelected(_ faces: [FaceLandmarkSet], targets: [FaceTarget],
                                  signatures: [FaceSignature?]) -> [FaceLandmarkSet] {
        if targets.isEmpty { return faces }
        if selectedTracker == nil {
            selectedTracker = SelectedFaceTracker(
                initialCentroids: targets.map { SelectedFaceTracker.centroid(of: $0.landmarks) }
            )
        }
        guard var tracker = selectedTracker else { return faces }
        let spatiallyMatched = tracker.matches(faces)
        selectedTracker = tracker
        let kept = FaceIdentityPolicy.hidden(faces: faces, signatures: signatures,
                                             spatiallyMatched: spatiallyMatched,
                                             selectedPersons: identityPersons)
        identityFilteredFrameCount += 1
        identityKeptFaceCount += kept.count
        return kept
    }

    /// 絞り込みを通過した顔の延べ件数と、絞り込みを行ったフレーム数。
    /// **検証用**（書き出した動画の画素を調べずに「誰を隠したか」を確かめる口）。
    /// 出力には一切影響しない。
    private(set) var identityKeptFaceCount = 0
    private(set) var identityFilteredFrameCount = 0

    /// モザイク対象として選ばれた人物。空なら同定を使わず位置追跡だけで判定する。
    private var identityPersons: [PersonProfile] = []
    /// 署名の引き当て（値型スナップショット）。書き出し中に再生側が書き込んでも影響しない。
    private var identitySignatures = FaceSignatureLookup(samples: [:])

    // MARK: - Setup helpers

    /// 映像リーダー出力。`videoComposition` があるときは合成済みフレームを受け取る
    /// `AVAssetReaderVideoCompositionOutput`、無ければ従来どおり単一トラック直読み。
    ///
    /// どちらも Metal 互換を明示する。明示しないと環境によってはリーダのバッファから
    /// `CVMetalTextureCacheCreateTextureFromImage` が失敗し、モザイク描画が全フレーム
    /// 早期リターン → 出力が無加工/空になる（Simulator で実測確認済みの潜在バグ）。
    private func makeVideoOutput(tracks: [AVAssetTrack],
                                 videoComposition: AVVideoComposition?) -> AVAssetReaderOutput {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        guard let videoComposition else {
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
            output.alwaysCopiesSampleData = false
            return output
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,
                                                         videoSettings: settings)
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        return output
    }

    /// HEVC を優先し、対応していなければ H.264 にフォールバックして映像入力を作る。
    /// 作成した入力は writer に追加済みで返す。
    private func makeVideoWriterInput(
        size: CGSize,
        transform: CGAffineTransform,
        estimatedDataRate: Float,
        writer: AVAssetWriter
    ) throws -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        // 元動画のビットレートを踏襲（取得不可なら解像度から概算: 約0.15bpp×30fps）。
        let bitrate = estimatedDataRate > 0
            ? Int(estimatedDataRate)
            : Int(Double(size.width) * Double(size.height) * 0.15 * 30)

        func makeInput(codec: AVVideoCodecType) -> AVAssetWriterInput {
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            return input
        }

        var input = makeInput(codec: .hevc)
        if !writer.canAdd(input) {
            input = makeInput(codec: .h264)
        }
        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        return (input, adaptor)
    }

    /// 再エンコード経路で PCM デコードと AAC 出力の両方に使う音声フォーマット。
    /// 1 箇所で決めることで「デコード結果と writer 入力設定の食い違い」を構造的に防ぐ。
    struct ReencodeAudioFormat: Equatable {
        /// 元素材のレート（AAC エンコーダ上限の 48kHz 超は 48kHz へ）。既定 44.1kHz。
        let sampleRate: Double
        /// 最大 2（ステレオ）にクランプ。>2ch はダウンミックスする。
        let channels: Int
    }

    /// 元素材のフォーマット記述から再エンコード経路の音声フォーマットを決める。
    ///
    /// 3ch 以上（5.1ch 等）を AVChannelLayoutKey 無しで AAC 出力設定に指定すると
    /// AVAssetWriterInput の init が `NSInvalidArgumentException`（ObjC 例外・
    /// Swift で catch 不能）を投げてプロセスごと落ちる（6ch .mov で実測）。
    /// レイアウトを正しく引き回すより、モザイクアプリの書き出しとして十分な
    /// ステレオへのダウンミックスで固定する。
    ///
    /// **フォーマット混在タイムラインでは先頭クリップに全体が揃う**（呼び出し側が
    /// `formatDescriptions.first` だけを渡すため）。44.1kHz 素材 + 48kHz 素材の連結なら
    /// 出力は全体 44.1kHz になる。意図的な仕様: 再エンコード経路は単一設定の writer 入力
    /// 1 本で書くので、どこか 1 つに揃えるしかない。リサンプルはリーダー
    /// （`AVAssetReaderAudioMixOutput` + `reencodeDecodeSettings`）が行うため
    /// 後続クリップの音が壊れることはない（`MultiClipExportTests` の混在テストが固定）。
    static func reencodeAudioFormat(matching format: CMFormatDescription?) -> ReencodeAudioFormat {
        var sampleRate = 44_100.0
        var channels = 2
        if let format,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = min(asbd.mSampleRate, 48_000) }
            if asbd.mChannelsPerFrame > 0 { channels = min(Int(asbd.mChannelsPerFrame), 2) }
        }
        return ReencodeAudioFormat(sampleRate: sampleRate, channels: channels)
    }

    /// 再エンコード経路のデコード設定（AVAssetReaderAudioMixOutput 用）。
    ///
    /// AAC 出力と同じレート・チャンネル数の 16bit インターリーブ PCM を明示する。
    /// リーダー段で揃えきる理由:
    /// - >2ch（5.1ch 等）を 6ch のままデコードして 2ch AAC の writer 入力へ渡すと、
    ///   writer 側のチャンネル変換が -12780 で失敗する（6ch .mp4 で実測）。
    /// - 48kHz 素材と 44.1kHz 素材が混在するタイムラインでは、デコード結果の
    ///   フォーマット記述が途中で変わる。単一設定の writer 入力に渡せないため、
    ///   ミックス機能を持つリーダー側で 1 つのレートへ統一する。
    static func reencodeDecodeSettings(matching format: CMFormatDescription?) -> [String: Any] {
        let target = reencodeAudioFormat(matching: format)
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: target.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 再エンコード経路の AAC 出力設定。レート・チャンネル数は
    /// `reencodeAudioFormat(matching:)` が決めた値（デコード設定と同一）を使う。
    /// 入力 PCM と完全に一致するので、writer 側での再変換は発生しない。
    static func aacAudioSettings(matching format: CMFormatDescription?) -> [String: Any] {
        let target = reencodeAudioFormat(matching: format)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: target.channels,
            AVEncoderBitRateKey: 96_000 * target.channels
        ]
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-\(UUID().uuidString).mp4")
    }

    /// `clampAudioSample(_:toEndSeconds:)` の結果。
    enum AudioTailClamp {
        /// 範囲内（必要なら末尾サンプルを切り詰め済み）。writer に渡してよい。
        case append(CMSampleBuffer)
        /// 先頭から範囲外。音声は打ち切ってよい（付随値は捨てたバッファの PTS 秒）。
        case finished(Double)
    }

    /// writer タイムライン上の上限 `limit` を超える音声を捨てる（再エンコード時のみ使う）。
    ///
    /// なぜ要るか: スケール編集（rate≠1）の音声は時間伸縮処理（`.spectral`）を通るため、
    /// リーダーは**処理ブロック単位で切り上げた長さ**を返す。2s・44.1kHz モノラルを
    /// rate=2 で読むと、想定の 44,100 フレーム（1.000s）に対し 49,152 フレーム
    /// （= 48 × 1024、1.1146s）が返る＝**約 0.11s の余剰**（実測）。
    /// トリム時も同じで、`AVAssetReader.timeRange` は範囲末尾を跨ぐ処理ブロックまで返す。
    /// 出力尺は映像・音声のうち長い方で決まるので、そのまま書くと
    /// 「映像 1.00s・音声 1.11s」の出力になり、尺全体が伸びる。
    ///
    /// PCM デコード済みバッファはサンプル単位で切れるため、範囲を跨ぐバッファは
    /// 収まるサンプル数だけ切り出す（`CMSampleBufferCopySampleBufferForRange`）。
    /// 切り出しに失敗した異常時は元をそのまま返す（欠落より余剰を選ぶ）が、
    /// **無言では返さない**（余剰が黙って復活する経路を残さないため `[MMEXPORT]` に出す）。
    static func clampAudioSample(_ sample: CMSampleBuffer,
                                 toEndSeconds limit: Double) -> AudioTailClamp {
        let ptsSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard ptsSec.isFinite else { return .append(sample) }
        if ptsSec >= limit { return .finished(ptsSec) }

        let numSamples = CMSampleBufferGetNumSamples(sample)
        let durationSec = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        guard numSamples > 0, durationSec.isFinite, durationSec > 0 else {
            return .append(sample)
        }
        if ptsSec + durationSec <= limit { return .append(sample) }

        let perSampleSec = durationSec / Double(numSamples)
        let fitting = Int(((limit - ptsSec) / perSampleSec).rounded(.down))
        // 1 サンプルも入らないなら、そもそも上の pts 判定で弾けている想定。
        // 念のため下限 1・上限 numSamples にクランプする。
        let keep = min(max(fitting, 1), numSamples)
        guard keep < numSamples else { return .append(sample) }
        var truncated: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleRange: CFRange(location: 0, length: keep),
            sampleBufferOut: &truncated)
        if status == noErr, let truncated { return .append(truncated) }
        // 失敗しても書き出しは続ける（欠落より余剰）が、末尾に余剰が残った事実は残す。
        print(String(format: "[MMEXPORT] audio tail clamp FAILED: err=%d limit=%.3fs "
                     + "pts=%.3fs keep=%d/%d (末尾に余剰が残る)",
                     Int(status), limit, ptsSec, keep, numSamples))
        return .append(sample)
    }

    /// トリム開始時刻ぶんだけ PTS と DTS を負方向にシフトした CMSampleBuffer を返す。
    /// audio でタイムラインを 0 起点に揃えるために使う。
    ///
    /// タイミング情報は必要エントリ数を先に問い合わせる: デコード済み PCM バッファは
    /// 数千サンプルでも均一タイミング（必要エントリ 1 個）のため、サンプル数ぶんの
    /// 配列を確保する必要はない。
    static func shiftSample(_ sample: CMSampleBuffer, byMinusSeconds seconds: Double) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { return nil }
        var neededCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &neededCount)
        guard neededCount > 0 else { return nil }
        let count = neededCount
        var timingInfos = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo.invalid,
            count: count
        )
        var infoCountOut: CMItemCount = 0
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: count,
            arrayToFill: &timingInfos,
            entriesNeededOut: &infoCountOut
        )
        guard status == noErr else { return nil }
        let shift = CMTime(seconds: seconds, preferredTimescale: 600)
        for i in 0..<count {
            if timingInfos[i].presentationTimeStamp.isValid {
                timingInfos[i].presentationTimeStamp =
                    CMTimeSubtract(timingInfos[i].presentationTimeStamp, shift)
            }
            if timingInfos[i].decodeTimeStamp.isValid {
                timingInfos[i].decodeTimeStamp =
                    CMTimeSubtract(timingInfos[i].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfos,
            sampleBufferOut: &out
        )
        return copyStatus == noErr ? out : nil
    }
}
// swiftlint:enable type_body_length
#endif
// swiftlint:enable file_length
