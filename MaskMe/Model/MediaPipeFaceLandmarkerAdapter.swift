//  MediaPipeFaceLandmarkerAdapter.swift
//
//  App-target glue between MediaPipe and the MediaPipe-free `MosaicCore`.
//  MediaPipe ships only as a CocoaPods pod / binary xcframework, so it is
//  linked here in the app target — never in `MosaicCore`, which stays pure so
//  CI can `swift build` it.
//
//  Everything that touches MediaPipe is gated on `canImport(MediaPipeTasksVision)`
//  so the package keeps compiling anywhere the pod is absent.

import UIKit
import MosaicCore

/// Returns the best available landmarker: the MediaPipe-backed one when the pod
/// and model are present, otherwise a ``NullFaceLandmarker``.
public func makeFaceLandmarker(
    forVideo: Bool = false,
    settings: DetectionSettings = DetectionSettings(),
    modelName: String = "face_landmarker"
) -> FaceLandmarking {
    #if canImport(MediaPipeTasksVision)
    if let path = Bundle.main.path(forResource: modelName, ofType: "task"),
       let adapter = try? MediaPipeFaceLandmarkerAdapter(
           modelPath: path,
           runningMode: forVideo ? .video : .image,
           settings: settings
       ) {
        return adapter
    }
    #endif
    return NullFaceLandmarker()
}

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
import CoreImage.CIFilterBuiltins

/// フレームの顔をどの検出経路が最初に拾ったか。精度計測（DValid）で
/// 「どのレバーが何フレーム救ったか」を1ランで帰属するための統計に使う。
public enum FaceDetectionSource: String {
    case mp          // MediaPipe FaceLandmarker 本検出（enhance なし）
    case enhance = "enh"  // enhance（moderate/aggressive/backlight）後に検出
    case bbox        // 補助検出器 bbox → ROI 再検出のみが拾った
    case roi         // テンポラル ROI 再検出（前フレーム bbox）
    case lowConf = "low"  // 低 confidence 最終フォールバック
    case tiled = "tile"   // タイル分割再検出（track なしの長期ロスト用）
    case flow        // オプティカルフロー・ブリッジ（検出ではなく追跡による補完）
    case none = ""   // 未検出
}

/// 検出ソース別の「そのソースが最初の顔を提供したフレーム数」。
public struct FaceDetectionSourceStats {
    public var mpFrames = 0
    public var enhanceFrames = 0
    public var bboxFrames = 0
    public var roiFrames = 0
    public var lowConfFrames = 0
    public var tiledFrames = 0
    public var flowFrames = 0
}

/// Thin wrapper around MediaPipe's `FaceLandmarker` that produces the
/// framework-agnostic `FaceLandmarkSet` consumed by `MosaicRenderer`.
public final class MediaPipeFaceLandmarkerAdapter: FaceLandmarking {
    private let landmarker: FaceLandmarker
    /// VID モードのとき、bbox を ROI として食わせる専用の IMG モード landmarker。
    /// VID は1ストリームに専用なので別インスタンスが要る。用途は2つ:
    /// (1) 補助検出器が見つけた新規 bbox の再検出、(2) テンポラル ROI 再検出
    /// （前フレームで検出した顔の周辺の再走査）。runningMode == .video なら常時生成。
    private let landmarkerForCrop: FaceLandmarker?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let plausibilityMinSpan: CGFloat
    private let plausibilityEyeRatioRange: ClosedRange<CGFloat>
    /// 補助 bbox 検出器（Vision / Core ML / 並走など）。nil なら MP 単独。
    private let bboxDetector: FaceBBoxDetecting?

    // MARK: - テンポラル追跡（video モード専用）
    //
    // 全画面パイプライン（MP → enhance → 補助検出器）が全滅したフレームで、
    // 「前フレームで顔があった場所の周辺」だけを切り出して IMG モードで再走査する。
    // 顔は 1/15 秒で大きく動かないので、全画面では小さすぎ/暗すぎて拾えない顔も
    // 拡大された ROI 内でなら検出できることが多い。
    //
    // invariant: video モードの adapter インスタンスは「単一動画ストリームを時刻順に
    // 直列処理する」用途専用（DValid テストはメソッドごとに独立インスタンス、
    // アプリはプリスキャン Task / export キューが直列に使う）。並行呼び出しは想定しない。
    private struct TrackedFace {
        var box: CGRect
        var missCount: Int
        /// 位置・寸法の等速度 Kalman。前フレーム観測から次フレーム位置を予測し、
        /// ROI を「速度連動」で先回りさせる。速い頭部運動・パン中でも ROI が顔から
        /// 外れず、tiled 全滅リカバリ（10-45f 遅延）を短縮する。
        var kalman: KalmanBoxTracker
    }
    private var trackedFaces: [TrackedFace] = []
    private var lastVideoTimestampMs: Int = .min

    /// 検出した bbox 列から TrackedFace を再構築する。実検出があった時点で
    /// Kalman を初期化して次フレーム以降の予測に備える。
    private func rebuildTracks(from boxes: [CGRect]) {
        trackedFaces = boxes.map { box in
            TrackedFace(box: box, missCount: 0, kalman: KalmanBoxTracker(initialBox: box))
        }
    }

    // MARK: - オプティカルフロー・ブリッジ（video モード専用）
    //
    // 検出パイプライン全段（MP → enhance → bbox → ROI → lowConf → タイル → 顔検証）が
    // 全滅したフレームを、OpenCV 疎 LK の「画素の動き」でブリッジする。検出器は
    // 「顔らしい見た目」が消えたフレーム（横顔・後ろ向き・強ブレ・極暗）で原理的に
    // 全滅するが、フローは顔かどうかを見ないため位置の供給を続けられる。
    //
    // 出力は src=flow でタグ付けし、rate（生検出率）には算入しない（DValid 側で区別）。
    // フローは顔の存在を証明しないため、trackedFaces の missCount には触らない。
    private struct FlowState {
        let tracker: OpticalFlowTracker
        var lastLandmarks: FaceLandmarkSet
    }
    private var flowStates: [FlowState] = []
    /// 連続フロー供給の上限フレーム数（15fps サンプリングで 30 ≒ 2 秒）。
    /// ドリフト（ズレの蓄積）で実顔から外れたまま供給し続けるのを防ぐ。
    private let maxFlowFrames = 30
    /// フローブリッジを許可するトラックbboxの正規化面積上限。
    /// 実測: 真顔の面積は s1/s2/s5 全てで ≤0.06、s5の体誤検出は 0.11〜0.17（DVALFRAME分析、2026-07-04）。
    /// これを超えるトラックはブリッジせずミス扱い（baseline挙動に戻るだけの安全な劣化）。
    private let maxFlowBridgeArea: CGFloat = 0.08
    /// フローブリッジを許可するトラックbbox中心の正規化Y座標上限（画面下半分はブリッジしない）。
    /// 実測: s5_Bでflowが延命したlowCy 33件は全てcy0.49〜0.69の弱ソース(enh/low/tile)検出、
    /// 一方s4/s1のflow利得239フレーム中cy>0.5は1件のみ（CI run 28710148201のDVALFRAME分析、2026-07-04）。
    /// これを超えるトラックはブリッジせずミス扱い（baseline挙動に戻るだけの安全な劣化）。
    private let maxFlowBridgeCenterY: CGFloat = 0.5
    private let maxFlowTracks = 3
    private var consecutiveFlowFrames = 0
    /// ROI は前フレーム bbox を中心固定で何倍に広げるか（基本値）。ミスが続くほど顔が
    /// 元位置から離れている可能性が上がるため、missCount に応じて漸増させ上限で頭打ち。
    private let roiExpansion: CGFloat = 2.0
    private let roiExpansionPerMiss: CGFloat = 0.1
    private let roiExpansionMax: CGFloat = 3.0
    /// 何フレーム連続で ROI 再検出に失敗したら track を破棄するか
    /// （15fps サンプリングで 20 フレーム ≒ 1.3 秒）。誤検出 track の自己増殖を防ぐ上限。
    /// 継続性ガード（IoU・面積比）と漸増 ROI がある前提で、実績のある ROI 強調リトライを
    /// なるべく長く生かす。
    private let maxTrackMisses = 20
    /// track が生きていても、全 track がこのフレーム数連続ミスしたらタイル分割再走査を
    /// 併走させる（track 死亡まで待つとギャップが伸びる。実測: 同位置の小顔の再取得に
    /// 10 フレーム以上かかるケースの短縮が狙い）。
    private let tileKickInMisses = 5

    #if DEBUG
    /// テスト専用シーム。true の間は検出パイプライン全段（MP/enhance/bbox/ROI/
    /// lowConf/タイル/顔検証）を丸ごとスキップし、そのフレームを「検出全滅」として
    /// 扱う。フロー・ブリッジ状態機械（src=flow・連続上限30・再seed等）をユニット
    /// テストで決定論的に駆動するためのフラグ。false（デフォルト）のときはプロダ
    /// クション経路に一切影響しない。DEBUG ビルド専用（Release には含まれない）。
    public var simulateDetectionFailureForTesting = false
    #endif

    /// 通常パイプライン + テンポラル ROI が全滅したフレーム専用の最終フォールバック。
    /// confidence を極端に下げた IMG モード landmarker で全画面をもう一度だけ走査する。
    /// 拾いすぎた誤検出は isPlausibleFace が排除する前提。使うときだけ遅延生成。
    private lazy var landmarkerLowConf: FaceLandmarker? = {
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .image
        options.numFaces = max(numFaces, 1)
        options.minFaceDetectionConfidence = 0.05
        options.minFacePresenceConfidence  = 0.05
        options.minTrackingConfidence      = 0.05
        return try? FaceLandmarker(options: options)
    }()
    private let modelPath: String
    private let numFaces: Int

    /// 直近フレームで最初の顔を提供した検出ソース（未検出なら `.none`）。
    /// インスタンスは単一ストリーム直列使用が前提（テスト・アプリとも直列）。
    public private(set) var lastSource: FaceDetectionSource = .none
    /// ソース別の累計フレーム数。精度計測でのレバー帰属用。
    public private(set) var sourceStats = FaceDetectionSourceStats()

    private func recordSource(_ source: FaceDetectionSource) {
        lastSource = source
        switch source {
        case .mp:       sourceStats.mpFrames += 1
        case .enhance:  sourceStats.enhanceFrames += 1
        case .bbox:     sourceStats.bboxFrames += 1
        case .roi:      sourceStats.roiFrames += 1
        case .lowConf:  sourceStats.lowConfFrames += 1
        case .tiled:    sourceStats.tiledFrames += 1
        case .flow:     sourceStats.flowFrames += 1
        case .none:     break
        }
    }

    /// - Parameter modelPath: path to the bundled `face_landmarker.task` model.
    public init(modelPath: String, runningMode: RunningMode = .video,
                settings: DetectionSettings = DetectionSettings()) throws {
        // confidence は (0, 1] が有効。0 や永続化された不正値を渡すと MediaPipe の
        // 初期化が失敗し、呼び出し側が NullFaceLandmarker（無検出）に落ちてしまうため、
        // 安全範囲にクランプして「設定値が原因で一切検出されない」回帰を防ぐ。
        func clampConfidence(_ value: Float) -> Float { min(max(value, 0.01), 1.0) }

        self.modelPath = modelPath
        self.numFaces = settings.numFaces

        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numFaces = max(settings.numFaces, 1)
        options.minFaceDetectionConfidence = clampConfidence(settings.minFaceDetectionConfidence)
        options.minFacePresenceConfidence  = clampConfidence(settings.minFacePresenceConfidence)
        options.minTrackingConfidence      = clampConfidence(settings.minTrackingConfidence)
        self.plausibilityMinSpan = CGFloat(settings.minSpan)
        // 目の間隔／顔幅の比。下限 0.40 は、補助検出器が体（胸・首・手）を bbox 化して
        // MP IMG モードで再検出させたときの誤フィットを弾くため。実測では乳首は 0.25〜0.31、
        // 正当な横顔は 0.41、正面顔は 0.55+。0.40 は 0.35→0.40 引き上げで「体の一部に顔メッシュ
        // をフィットしたが 0.35 を僅かに上回って通過」していたケースを排除する。
        self.plausibilityEyeRatioRange = 0.40...1.0
        self.landmarker = try FaceLandmarker(options: options)
        // useFaceDetector / useYunet の組み合わせから補助検出器を構築する。
        self.bboxDetector = Self.makeBBoxDetector(
            useFaceDetector: settings.useFaceDetector,
            useYunet: settings.useYunet
        )
        // VID モードなら ROI 再検出用に IMG モードの landmarker を常時持つ
        // （補助検出器の新規 bbox 再検出と、テンポラル ROI 再検出の両方で使う。
        // 補助検出器なしの構成でもテンポラル追跡は動かしたい）。
        // IMG モード本体では同じ landmarker をそのまま使えるので追加不要。
        if runningMode == .video {
            let imgOptions = FaceLandmarkerOptions()
            imgOptions.baseOptions.modelAssetPath = modelPath
            imgOptions.runningMode = .image
            imgOptions.numFaces = 1  // ROI 内には基本 1 顔
            imgOptions.minFaceDetectionConfidence = clampConfidence(settings.minFaceDetectionConfidence)
            imgOptions.minFacePresenceConfidence  = clampConfidence(settings.minFacePresenceConfidence)
            imgOptions.minTrackingConfidence      = clampConfidence(settings.minTrackingConfidence)
            self.landmarkerForCrop = try? FaceLandmarker(options: imgOptions)
        } else {
            self.landmarkerForCrop = nil
        }
    }

    private static func makeBBoxDetector(
        useFaceDetector: Bool,
        useYunet: Bool
    ) -> FaceBBoxDetecting? {
        // Apple Vision は削除済み: 実機で torso・首・肩を顔 bbox として拾い体モザイクの
        // 原因になった上、Simulator では 0 検出でシミュレータ検証が不可能だった。
        var detectors: [FaceBBoxDetecting] = []
        if useFaceDetector   { detectors.append(MediaPipeFaceBBoxDetector()) }
        if useYunet          { detectors.append(YuNetFaceDetector()) }
        switch detectors.count {
        case 0:  return nil
        case 1:  return detectors[0]
        default: return CompositeBBoxDetector(detectors)
        }
    }

    // MARK: - Single-face API（後方互換）

    public func landmarks(in image: UIImage) -> FaceLandmarkSet? {
        allLandmarks(in: image).first
    }

    public func landmarks(in image: UIImage, timestampMs: Int) -> FaceLandmarkSet? {
        allLandmarks(in: image, timestampMs: timestampMs).first
    }

    // MARK: - Multi-face API

    public func allLandmarks(in image: UIImage) -> [FaceLandmarkSet] {
        let (mp, mpSource) = mpDetectImageWithEnhance(image)
        guard bboxDetector != nil else {
            // MP が生検出しても妥当性フィルタで全棄却されると空になるため、
            // 「最初の顔を提供した」ソースは空でないときだけ記録する。
            recordSource(mp.isEmpty ? .none : mpSource)
            return mp
        }
        let result = augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: true)
        recordSource(mp.isEmpty ? (result.isEmpty ? .none : .bbox) : mpSource)
        return result
    }

    public func allLandmarks(in image: UIImage, timestampMs: Int) -> [FaceLandmarkSet] {
        resetTracksIfNeeded(timestampMs: timestampMs)
        var result: [FaceLandmarkSet]
        var source: FaceDetectionSource
        #if DEBUG
        let skipDetectionForTesting = simulateDetectionFailureForTesting
        #else
        let skipDetectionForTesting = false
        #endif
        if skipDetectionForTesting {
            // テスト専用シーム発火中: 検出パイプライン全段を丸ごとスキップし、
            // このフレームを「検出全滅」として扱う（flowブリッジ状態機械の検証用）。
            result = []
            source = .none
        } else {
            let (mp, mpSource) = mpDetectVideoWithEnhance(image, timestampMs: timestampMs)
            if bboxDetector != nil {
                result = augmentWithBBoxDetector(image: image, mpResults: mp, useImageMode: false)
                source = mp.isEmpty ? (result.isEmpty ? .none : .bbox) : mpSource
            } else {
                result = mp
                source = mp.isEmpty ? .none : mpSource
            }
            if result.isEmpty {
                // 全画面パイプライン全滅 → 前フレームの顔位置周辺だけを再走査する。
                result = redetectFromTrackedBoxes(image: image)
                source = result.isEmpty ? .none : .roi
            } else {
                rebuildTracks(from: result.map { $0.boundingBox })
            }
            if result.isEmpty {
                // それでもゼロなら、低 confidence の全画面走査を最後にもう一度だけ。
                // 妥当性フィルタ通過分のみ採用し、次フレームからの ROI 追跡の種にもする。
                result = lowConfDetect(image)
                source = result.isEmpty ? .none : .lowConf
                if !result.isEmpty {
                    rebuildTracks(from: result.map { $0.boundingBox })
                }
            }
            if result.isEmpty, trackedFaces.allSatisfy({ $0.missCount >= tileKickInMisses }) {
                // track 無し（allSatisfy は空配列で true）、または全 track が連続ミス中の
                // 長期ロスト時のみ、フレームをタイル分割して再走査する。
                // 全画面検出はモデル入力への縮小で小顔が潰れるため、タイル crop で
                // 顔の相対サイズを稼ぐ（実測: フレーム比 10% 台の顔は全画面 + enhance
                // 全滅でもタイル内なら検出できる）。成功したら track を再シードして
                // 以降のフレームは安価な ROI 追跡に引き継ぐ。
                result = tiledDetect(image)
                source = result.isEmpty ? .none : .tiled
                if !result.isEmpty {
                    rebuildTracks(from: result.map { $0.boundingBox })
                }
            }
            if !result.isEmpty {
                let verified = verifySuspiciousFaces(result, in: image)
                if verified.count != result.count {
                    let droppedBoxes = result.map(\.boundingBox).filter { box in
                        !verified.contains { $0.boundingBox == box }
                    }
                    // 棄却した候補の track だけを外科的に殺す（ROI 延命が体 track を
                    // 引きずるのを防ぐ）。他 track の missCount 状態は保持する。
                    trackedFaces.removeAll { tf in droppedBoxes.contains { iou(tf.box, $0) > 0.5 } }
                    result = verified
                    if result.isEmpty { source = .none }
                }
            }
        }
        if result.isEmpty, !flowStates.isEmpty, consecutiveFlowFrames < maxFlowFrames {
            // 検出全滅 → フローで前回ランドマークを前進させてブリッジする。
            // 顔検証パス（タイト crop 再検出）は「検出器で見える顔」しか通せないため、
            // フロー出力には適用しない（検出器が全滅したからこそフローに来ている）。
            // 誤検出の延命は品質ゲート・上限フレーム・lowCy 番犬の3重で抑える。
            let imageSize = pixelSize(of: image)
            var flowFaces: [FaceLandmarkSet] = []
            var survivors: [FlowState] = []
            // 同一フレーム内で他の FlowState が既に割り当てた trackedFaces の index は
            // 除外する（グローバル再探索のみだと、複数顔が近接している場合に最良 IoU の
            // index が重複してしまい、誤 track の bbox を上書きしうるため）。
            var claimedTrackedIndices: Set<Int> = []
            for var state in flowStates {
                // 面積ゲート: 真顔として妥当な大きさのトラックのみブリッジ対象にする
                // （s5の体誤検出のような大型bboxはここで seed/advance をスキップして
                // 従来の「全段失敗」＝ミス扱いに落とす）。
                guard isFlowBridgeEligible(state.lastLandmarks.boundingBox) else { continue }
                guard let match = state.tracker.advance(with: image),
                      let transform = SimilarityTransform.estimate(
                          from: match.previousPoints.map(\.cgPointValue),
                          to: match.currentPoints.map(\.cgPointValue)),
                      (0.7...1.4).contains(transform.scale) else { continue }
                let moved = transform.apply(to: state.lastLandmarks, imageSize: imageSize)
                state.lastLandmarks = moved
                flowFaces.append(moved)
                survivors.append(state)
                // 対応する track の bbox も前進させ、次フレームの ROI 再検出が
                // フロー予測位置を走査できるようにする（実顔再取得の早期化）。
                let movedBox = moved.boundingBox
                if let ti = trackedFaces.indices
                    .filter({ !claimedTrackedIndices.contains($0) })
                    .max(by: {
                        iou(trackedFaces[$0].box, movedBox) < iou(trackedFaces[$1].box, movedBox)
                    }), iou(trackedFaces[ti].box, movedBox) > 0.1 {
                    trackedFaces[ti].box = movedBox
                    claimedTrackedIndices.insert(ti)
                }
            }
            flowStates = survivors
            if !flowFaces.isEmpty {
                result = flowFaces
                source = .flow
                consecutiveFlowFrames += 1
            }
        } else if result.isEmpty {
            flowStates = []
        }
        if !result.isEmpty, source != .flow {
            // 実検出(どのソースでも)に成功したらフローを再シードする。
            // seed は縮小 ROI の特徴点抽出のみで軽量（〜1ms）なので毎フレーム行う。
            consecutiveFlowFrames = 0
            flowStates = result.prefix(maxFlowTracks).compactMap { face in
                let tracker = OpticalFlowTracker()
                guard tracker.seed(with: image, faceBox: face.boundingBox) else { return nil }
                return FlowState(tracker: tracker, lastLandmarks: face)
            }
        }
        recordSource(source)
        return result
    }

    /// トラックの正規化bboxが、フローブリッジしてよい「顔として妥当な」範囲か。
    /// 面積 ≤ `maxFlowBridgeArea`（体誤検出の延命防止）**かつ**
    /// 中心 midY ≤ `maxFlowBridgeCenterY`（弱ソース低位置検出の延命防止）の AND 条件。
    /// `@testable` からユニットテストで直接境界を検証できるよう internal にしている。
    func isFlowBridgeEligible(_ normalizedBox: CGRect) -> Bool {
        normalizedBox.width * normalizedBox.height <= maxFlowBridgeArea
            && normalizedBox.midY <= maxFlowBridgeCenterY
    }

    /// 低 confidence 最終フォールバックの全画面走査（video パス専用）。
    /// conf 0.05 まで下げると体（胸・股・手）への誤フィットが本経路経由で急増する
    /// （s5 実測: 本経路ヒットの 44% が画面下半分 = 体疑い）ため、eyeRatio 下限を
    /// 本体の 0.40 より厳しい 0.45 にする。正面顔は 0.55+ なので通り、横顔（0.41）は
    /// 弾かれるが、最終手段の一走査としては誤モザイク防止を優先する。
    private func lowConfDetect(_ image: UIImage) -> [FaceLandmarkSet] {
        guard let lm = landmarkerLowConf,
              let mpImage = try? MPImage(uiImage: image),
              let result = try? lm.detect(image: mpImage),
              !result.faceLandmarks.isEmpty else { return [] }
        return result.faceLandmarks.compactMap { face in
            let pts = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            return makeLandmarkSet(points: pts, eyeRatioRange: 0.45...1.0)
        }
    }

    // MARK: - タイル分割再検出

    /// 4 隅 0.65×0.65 + 中央 0.5×0.5 の重なり付き 5 タイル。重なり 0.3 以上を確保し、
    /// フレーム比 3 割までの顔ならどこにいても必ずいずれかのタイルに丸ごと収まる。
    private static let detectionTiles: [CGRect] = [
        CGRect(x: 0, y: 0, width: 0.65, height: 0.65),
        CGRect(x: 0.35, y: 0, width: 0.65, height: 0.65),
        CGRect(x: 0, y: 0.35, width: 0.65, height: 0.65),
        CGRect(x: 0.35, y: 0.35, width: 0.65, height: 0.65),
        CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    ]

    /// 長期ロスト専用の最終フォールバック。各タイル crop を IMG モードで
    /// 再走査し（素 → aggressive → backlight 強調フレームの同タイル）、タイル座標から
    /// 元画像座標へ逆変換して返す。lowConf と同じ理由で eyeRatio 下限は 0.45 に厳格化し、
    /// 重なりタイルが同じ顔を二重に拾った分は IoU で間引く。
    private func tiledDetect(_ image: UIImage) -> [FaceLandmarkSet] {
        guard let cropLandmarker = landmarkerForCrop else { return [] }
        let enhanced = enhance(image, level: .aggressive)
        let backlit = enhance(image, level: .backlight)
        var found: [FaceLandmarkSet] = []
        for tile in Self.detectionTiles {
            var candidate: FaceLandmarkSet?
            for variant in [image, enhanced, backlit].compactMap({ $0 }) {
                guard let cropped = cropImage(variant, normalizedRect: tile),
                      let mpImage = try? MPImage(uiImage: cropped),
                      let result = try? cropLandmarker.detect(image: mpImage),
                      let first = result.faceLandmarks.first else { continue }
                let points = first.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
                // remapped 後の座標系で妥当性を評価する必要があるので、makeLandmarkSet は
                // 一時 tile 座標では geom を過小評価するため remap 後に判定する。
                let raw = FaceLandmarkSet(
                    points: points,
                    confidence: Float(min(1.0, Double(points.count) / Double(FaceLandmarkSet.fullMeshCount)))
                ).remapped(into: tile)
                if let vetted = makeLandmarkSet(points: raw.points, eyeRatioRange: 0.45...1.0) {
                    candidate = vetted
                    break
                }
            }
            guard let remapped = candidate else { continue }
            guard !found.contains(where: { iou($0.boundingBox, remapped.boundingBox) > 0.3 })
            else { continue }
            found.append(remapped)
        }
        return found
    }

    // MARK: - テンポラル ROI 再検出

    /// タイムスタンプが巻き戻った（新ストリーム/リスタート）か 1 秒を超えて飛んだ
    /// （シーク）場合は、前フレームの顔位置がもう意味を持たないので track を捨てる。
    /// 画面下寄りの採用候補に対する体誤フィット検証パス。s5 実測で誤モザイク（lowCy）の
    /// 大半が画面下半分（胸・股への顔メッシュフィット)に集中し、mp/enhance 経路にも
    /// baseline から存在するため、最終採用の直前に「疑わしい位置」の候補だけを再確認する:
    /// bbox の 1.3 倍 crop を IMG モードで再検出し、eyeRatio ≥ 0.45（lowConf/タイルと同じ
    /// 厳格値）+ 位置一致（IoU>0.3）を満たさなければ棄却。体フィットは文脈（video モードの
    /// 追跡状態）が切れたタイト crop では再現しにくく、実顔は再検出できるという非対称を使う。
    /// 上半分の候補には一切触れないので、正位置の検出率への影響はない。
    private let verifySuspectCy: CGFloat = 0.55
    private let verifyCropExpansion: CGFloat = 1.3

    private func verifySuspiciousFaces(_ faces: [FaceLandmarkSet], in image: UIImage) -> [FaceLandmarkSet] {
        guard let cropLandmarker = landmarkerForCrop else { return faces }
        return faces.filter { face in
            let box = face.boundingBox
            guard box.midY > verifySuspectCy else { return true }
            guard face.isPlausibleFace(minSpan: plausibilityMinSpan, eyeRatioRange: 0.45...1.0) else {
                return false
            }
            let roi = expandedClamped(box, factor: verifyCropExpansion)
            guard roi.width > 0, roi.height > 0,
                  let cropped = cropImage(image, normalizedRect: roi),
                  let mpImage = try? MPImage(uiImage: upscaledIfSmall(cropped)),
                  let result = try? cropLandmarker.detect(image: mpImage),
                  let first = result.faceLandmarks.first else { return false }
            let points = first.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            let meshFraction = Float(min(1.0, Double(points.count) / Double(FaceLandmarkSet.fullMeshCount)))
            let redetected = FaceLandmarkSet(points: points, confidence: meshFraction)
                .remapped(into: roi)
            return iou(redetected.boundingBox, box) > 0.3
        }
    }

    private func resetTracksIfNeeded(timestampMs: Int) {
        if lastVideoTimestampMs != .min,
           timestampMs <= lastVideoTimestampMs || timestampMs - lastVideoTimestampMs > 1000 {
            trackedFaces.removeAll()
            flowStates = []
            consecutiveFlowFrames = 0
        }
        lastVideoTimestampMs = timestampMs
    }

    /// 前フレームで検出した顔の bbox を広げた ROI を IMG モードで再走査する。
    /// 採用条件は「妥当な顔であること」に加えて「前フレームと同じ顔とみなせる連続性」
    /// （IoU > 0.1 かつ面積比 0.3〜3.0）。誤検出が track を乗っ取って居座るのを防ぐ。
    /// canonical 正面顔メッシュ（468点、frontalUV）を bbox にアフィンで貼り付ける。
    /// 補助検出器が bbox は拾えたが MP がメッシュ取得に失敗したフレームで、
    /// 「近似メッシュ + 低 confidence」で残す最終フォールバック。
    /// TrackingEvaluator の lockThreshold=0.5 は越えないので tracking 状態は
    /// 生成しないが、`LandmarkSmoother` は保持できるので次フレームまでの
    /// ちらつき軽減に効く。
    private func canonicalMeshFitted(to normalizedBox: CGRect,
                                     confidence: Float = 0.4) -> FaceLandmarkSet {
        let uv = FaceMeshTopology.frontalUV
        let count = FaceMeshTopology.vertexCount
        var pts: [FaceLandmark] = []
        pts.reserveCapacity(count)
        let bx = Float(normalizedBox.minX), by = Float(normalizedBox.minY)
        let bw = Float(normalizedBox.width), bh = Float(normalizedBox.height)
        for i in 0..<count {
            let u = uv[i * 2]
            let v = uv[i * 2 + 1]
            pts.append(FaceLandmark(x: bx + u * bw, y: by + v * bh, z: 0))
        }
        return FaceLandmarkSet(points: pts, confidence: confidence)
    }

    private func redetectFromTrackedBoxes(image: UIImage) -> [FaceLandmarkSet] {
        guard let cropLandmarker = landmarkerForCrop, !trackedFaces.isEmpty else { return [] }
        var results: [FaceLandmarkSet] = []
        for index in trackedFaces.indices {
            let oldBox = trackedFaces[index].box
            // A-1: Kalman を1ステップ進めた予測位置を ROI 中心にする。速い頭部運動でも
            // ROI が顔から外れないので、tiled 全滅リカバリの 10-45f 遅延が短縮される。
            trackedFaces[index].kalman.predict(dt: 1.0)
            let predictedBox = trackedFaces[index].kalman.predictedBox
            let speed = trackedFaces[index].kalman.speedMagnitude
            // 速度連動の ROI 拡大: speed=0 で基本値、速度が上がるほど拡大して先取り。
            // 検出ミスが続いた場合の従来の漸増も併用（速度がない状態で顔だけ動く場合の保険）。
            let missBoost = roiExpansionPerMiss * CGFloat(trackedFaces[index].missCount)
            let speedBoost = min(1.5, speed * 15.0)  // speed 0.1（画面10%/f）で +1.5
            let factor = min(roiExpansion + missBoost + speedBoost, roiExpansionMax)
            let roi = expandedClamped(predictedBox, factor: factor)
            guard roi.width > 0, roi.height > 0,
                  let cropped = cropImage(image, normalizedRect: roi) else {
                trackedFaces[index].missCount += 1
                continue
            }
            // 素の crop で失敗したら強調（暗所 → 逆光の順）をかけて再試行する。
            // 全画面の enhance ではモデル入力への縮小で潰れる小顔も、crop + 強調なら
            // 拾えることがある。crop は小さいので追加コストは僅少。
            let upscaled = upscaledIfSmall(cropped)
            var detectedFace: [FaceLandmark]?
            for variant in [upscaled,
                            enhance(upscaled, level: .aggressive),
                            enhance(upscaled, level: .backlight)].compactMap({ $0 }) {
                guard let mpImage = try? MPImage(uiImage: variant),
                      let result = try? cropLandmarker.detect(image: mpImage),
                      let first = result.faceLandmarks.first else { continue }
                detectedFace = first.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
                break
            }
            guard let points = detectedFace else {
                trackedFaces[index].missCount += 1
                continue
            }
            let meshFraction = Float(min(1.0, Double(points.count) / Double(FaceLandmarkSet.fullMeshCount)))
            let raw = FaceLandmarkSet(points: points, confidence: meshFraction).remapped(into: roi)
            guard let remapped = makeLandmarkSet(points: raw.points,
                                                 eyeRatioRange: plausibilityEyeRatioRange) else {
                trackedFaces[index].missCount += 1
                continue
            }
            let newBox = remapped.boundingBox
            let areaRatio = oldBox.width * oldBox.height > 0
                ? (newBox.width * newBox.height) / (oldBox.width * oldBox.height)
                : 0
            guard iou(newBox, oldBox) > 0.1,
                  (0.3...3.0).contains(areaRatio) else {
                trackedFaces[index].missCount += 1
                continue
            }
            trackedFaces[index].box = newBox
            trackedFaces[index].missCount = 0
            trackedFaces[index].kalman.update(observation: newBox)
            results.append(remapped)
        }
        trackedFaces.removeAll { $0.missCount >= maxTrackMisses }
        return results
    }

    /// `rect` を中心固定で `factor` 倍に広げ、[0, 1] にクランプした矩形を返す。
    /// クランプ後の矩形を crop と remap の両方に使うことで座標系のズレを避ける。
    private func expandedClamped(_ rect: CGRect, factor: CGFloat) -> CGRect {
        let cx = rect.midX, cy = rect.midY
        let w = rect.width * factor, h = rect.height * factor
        let x0 = max(0, cx - w / 2), y0 = max(0, cy - h / 2)
        let x1 = min(1, cx + w / 2), y1 = min(1, cy + h / 2)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 小さい ROI crop は MediaPipe の検出下限を割りやすいので、短辺が `minSide` px
    /// 未満なら拡大してから検出させる（小顔対策）。
    private func upscaledIfSmall(_ image: UIImage, minSide: CGFloat = 256) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(w, h)
        guard side > 0, side < minSide else { return image }
        let scale = minSide / side
        let newSize = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - MediaPipe (既存ロジックを切り出し)

    private func mpDetectImageWithEnhance(_ image: UIImage) -> ([FaceLandmarkSet], FaceDetectionSource) {
        if let result = detectAllImage(image) { return (result, .mp) }
        if let e1 = enhance(image, level: .moderate), let result = detectAllImage(e1) { return (result, .enhance) }
        if let e2 = enhance(image, level: .aggressive), let result = detectAllImage(e2) { return (result, .enhance) }
        if let e3 = enhance(image, level: .backlight), let result = detectAllImage(e3) { return (result, .enhance) }
        return ([], .none)
    }

    private func mpDetectVideoWithEnhance(_ image: UIImage, timestampMs: Int) -> ([FaceLandmarkSet], FaceDetectionSource) {
        if let result = detectAllVideoFrame(image, timestampMs: timestampMs) { return (result, .mp) }
        // enhance の各パスは +1ms ずつ進める（video モードは単調増加が必須）
        if let e1 = enhance(image, level: .moderate),
           let result = detectAllVideoFrame(e1, timestampMs: timestampMs + 1) { return (result, .enhance) }
        if let e2 = enhance(image, level: .aggressive),
           let result = detectAllVideoFrame(e2, timestampMs: timestampMs + 2) { return (result, .enhance) }
        if let e3 = enhance(image, level: .backlight),
           let result = detectAllVideoFrame(e3, timestampMs: timestampMs + 3) { return (result, .enhance) }
        return ([], .none)
    }

    // MARK: - 補助 bbox 検出器による補完

    /// MP の検出結果に対し、補助検出器（BlazeFace / YuNet / 並走）で見つかった bbox のうち
    /// MP と重ならないものを ROI として MP IMG モードに再検出させ、得られた 478 ランドマークを
    /// 元画像座標に逆変換して追加する。取れなかった bbox は捨てる（合成メッシュは作らない＝品質第一）。
    private func augmentWithBBoxDetector(
        image: UIImage,
        mpResults: [FaceLandmarkSet],
        useImageMode: Bool
    ) -> [FaceLandmarkSet] {
        guard let bboxDetector else { return mpResults }
        let rawBoxes = bboxDetector.detectFaceBoundingBoxes(in: image)
        if rawBoxes.isEmpty { return mpResults }
        // 補助検出器の生 bbox を「明らかに顔ではない形状」で前段ガードする。
        // torso / 首・胸元・肩・髪など顔でない領域の bbox を弾き、ROI 再検出のコストも節約する。
        // - 6% 未満は多くの誤検知（腕・首・耳など）を含むので棄却
        // - w/h 0.6〜1.4 で torso/neck のような縦長/横長を除外
        let candidateBoxes = rawBoxes.filter { box in
            guard box.width >= 0.06, box.height >= 0.06 else { return false }
            let ratio = box.width / box.height
            return ratio >= 0.6 && ratio <= 1.4
        }
        if candidateBoxes.isEmpty { return mpResults }
        let mpBoxes = mpResults.map { $0.boundingBox }
        let novelBoxes = candidateBoxes.filter { vb in
            !mpBoxes.contains { iou($0, vb) > 0.3 }
        }
        if novelBoxes.isEmpty { return mpResults }

        // IMG モード自身は本体 landmarker を流用、VID は IMG 専用の追加 landmarker を使う。
        let cropLandmarker = useImageMode ? landmarker : landmarkerForCrop
        guard let cropLandmarker else { return mpResults }

        var extras: [FaceLandmarkSet] = []
        for box in novelBoxes {
            if let cropped = cropImage(image, normalizedRect: box),
               let mpImage = try? MPImage(uiImage: upscaledIfSmall(cropped)),
               let result = try? cropLandmarker.detect(image: mpImage),
               let face = result.faceLandmarks.first {
                let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
                let meshFraction = Float(min(1.0, Double(points.count) / Double(FaceLandmarkSet.fullMeshCount)))
                let raw = FaceLandmarkSet(points: points, confidence: meshFraction).remapped(into: box)
                // 補助検出器発の候補にはソフトマージンを使わない厳格な妥当性チェックを行う。
                // アップスケールした体・首・肩の crop に MP が顔メッシュをハルシネートすると、
                // ソフトマージン（境界横顔用）を通り抜けて体モザイクになる。
                // 面数完全 × 目間比 0.45 以上を要求 (isPlausibleFace の元来の閾値相当)。
                guard raw.isPlausibleFace(minSpan: plausibilityMinSpan,
                                          eyeRatioRange: 0.45...1.0),
                      let vetted = makeLandmarkSet(points: raw.points,
                                                   eyeRatioRange: 0.45...1.0),
                      vetted.confidence >= 0.6 else {
                    continue
                }
                // 加えて、remap 後の bbox が縦横比で顔から外れていたら棄却
                // （torso 上に MP がメッシュを描いたケースを二重防御）。
                let vb = vetted.boundingBox
                let vratio = vb.width / max(vb.height, 0.001)
                guard vratio >= 0.6, vratio <= 1.4 else { continue }
                extras.append(vetted)
            }
            // A-2 の canonical mesh フォールバックは削除。補助検出器（YuNet / Vision /
            // MP FaceDetector）は体・服・手のような顔ではない領域を bbox で拾うことがあり、
            // MediaPipe がメッシュ抽出を拒否した bbox に無理に canonical mesh を貼ると
            // 体にモザイクが乗る誤検知になる。横顔・逆光の穴埋めは Kalman ROI 予測 (A-1)
            // + lookupFaces の直近ホールドフォールバックで拾う。
        }
        return mpResults + extras
    }

    /// UIImage のピクセル寸法（UIImage.size はポイント単位で scale 依存のため CGImage を使う）。
    private func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// 画像を正規化 rect (左上原点・[0, 1]) で切り抜く。`cropping(to:)` のために
    /// ピクセル座標へ変換し、画像範囲内にクランプする。
    private func cropImage(_ image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let x = max(0, normalizedRect.minX * w)
        let y = max(0, normalizedRect.minY * h)
        let pxRect = CGRect(
            x: x, y: y,
            width: min(w - x, normalizedRect.width * w),
            height: min(h - y, normalizedRect.height * h)
        ).integral
        guard pxRect.width > 0, pxRect.height > 0,
              let cropped = cg.cropping(to: pxRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Detection helpers

    private func detectAllImage(_ image: UIImage) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(image: mpImage),
              !result.faceLandmarks.isEmpty else { return nil }
        return convertAll(result)
    }

    private func detectAllVideoFrame(_ image: UIImage, timestampMs: Int) -> [FaceLandmarkSet]? {
        guard let mpImage = try? MPImage(uiImage: image),
              let result = try? landmarker.detect(
                  videoFrame: mpImage,
                  timestampInMilliseconds: timestampMs
              ),
              !result.faceLandmarks.isEmpty else { return nil }
        return convertAll(result)
    }

    private enum EnhanceLevel { case moderate, aggressive, backlight }

    /// 暗所・ぼやけ・逆光補正。
    /// moderate: 軽微な暗さ・白飛びを改善。
    /// aggressive: 暗い動画・夜間シーンで顔を検出できるよう全体を大幅増光。
    /// backlight: 逆光・人物のシルエットだけ暗いシーン向け。明部を強く抑え暗部を最大に持ち上げる。
    private func enhance(_ image: UIImage, level: EnhanceLevel) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cgImage)
        switch level {
        case .moderate:
            ci = ci
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.6,
                    "inputShadowAmount":    0.5,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.5,
                    "inputRadius":    1.5,
                ])
        case .aggressive:
            ci = ci
                .applyingFilter("CIExposureAdjust", parameters: [
                    "inputEV": 1.5,           // +1.5段分（約2.8倍）明るく
                ])
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.8,
                    "inputShadowAmount":    0.9,
                ])
                .applyingFilter("CIColorControls", parameters: [
                    "inputContrast":   1.1,
                    "inputBrightness": 0.05,
                    "inputSaturation": 1.0,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.7,
                    "inputRadius":    1.5,
                ])
        case .backlight:
            // 逆光対策: 明部を抑え、暗部を最大に持ち上げ、ガンマでさらに暗部ディテールを引き出す。
            ci = ci
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.3,
                    "inputShadowAmount":    1.0,
                ])
                .applyingFilter("CIGammaAdjust", parameters: [
                    "inputPower": 0.65,    // < 1.0 で暗部側を強く持ち上げる
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.6,
                    "inputRadius":    1.2,
                ])
        }
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    /// MediaPipe 結果の全顔を `[FaceLandmarkSet]` に変換する。
    /// 低いしきい値（暗所・ブレでも検出するため）で拾った誤検出を、幾何学的妥当性
    /// チェックで棄却する（例: 薄暗い場面で体や乳首を顔として検出するケース）。
    /// 全件棄却したらそのまま 0 件を返す（生検出を信頼するフォールバックは入れない。
    /// 唯一の検出が誤検出だった場合に乳首などを復活させてしまうため）。
    private func convertAll(_ result: FaceLandmarkerResult) -> [FaceLandmarkSet] {
        result.faceLandmarks.compactMap { face in
            let points = face.map { FaceLandmark(x: $0.x, y: $0.y, z: $0.z) }
            return makeLandmarkSet(points: points, eyeRatioRange: plausibilityEyeRatioRange)
        }
    }

    /// 検出後処理を1箇所に集約: メッシュ完全性 × 妥当性スコア × 面数比 で
    /// `confidence` を 0..1 の連続値化する。ROI/tiled/verifySuspicious/bbox augment の
    /// 各パスから共通で呼ぶ。スコア 0 は棄却で `nil`。
    fileprivate func makeLandmarkSet(
        points: [FaceLandmark],
        eyeRatioRange: ClosedRange<CGFloat>
    ) -> FaceLandmarkSet? {
        // 面数比（0.5〜1.0）で「部分メッシュはやや低い confidence」を表現する。
        let meshCompleteness = Float(min(1.0, Double(points.count) / Double(FaceLandmarkSet.fullMeshCount)))
        let base = FaceLandmarkSet(points: points, confidence: meshCompleteness)
        let geom = base.plausibilityScore(
            minSpan: plausibilityMinSpan,
            eyeRatioRange: eyeRatioRange
        )
        guard geom > 0 else { return nil }
        // 部分メッシュは 0.5、フルメッシュは 1.0 を上限にする。境界横顔は geom≈0.3〜1.0 で
        // TrackingEvaluator の lockThreshold=0.5 は 0.5*0.5=0.25 で下回るため、
        // 面数完全 × geom≥0.71 か、部分メッシュ × geom=1.0 が実質の tracking ロック条件になる。
        let confidence = max(0.1, min(1.0, meshCompleteness * (0.5 + 0.5 * geom)))
        return FaceLandmarkSet(points: points, confidence: confidence)
    }
}
#endif
