import AVFoundation
import Foundation
import MosaicCore

/// build 中に集めたクリップ 1 本ぶんの合成情報（`TimelineCompositionBuilder` が組み、
/// `VideoCompositionFactory` / `AudioMixFactory` が読む）。
struct ClipPlacement {
    let clip: TimelineClip
    let format: TimelineCompositionBuilder.VideoFormat
    /// 素材の公称フレームレート（0 以下なら未知）。`frameDuration` の決定に使う。
    let frameRate: Float
    /// このクリップを載せた合成映像トラック（A/B のどちらか）。
    let track: AVMutableCompositionTrack
    /// このクリップの音声を載せた合成音声トラック（音声を挿入しなかったら nil）。
    let audioTrack: AVMutableCompositionTrack?
    /// 合成タイムライン上の区間 [start, end)。`TimelineMapping.clipSpans` に由来する。
    let start: Double
    let end: Double
}

/// `AVVideoComposition` を装着すべきかどうかの判定材料。
///
/// 判定は `VideoCompositionPlan.decide` の 1 箇所に閉じ込める
/// （`AudioExportPipeline.decide` と同じ流儀）。条件を個別 Bool で受ける入口を
/// 増やすと、条件が増えたときに渡し忘れが静かに「装着しない」へ落ちる。
struct VideoCompositionConditions: Equatable {
    /// トランジションによる実効的な重なりがある（A/B トラックの合成が要る）。
    var hasTransitions = false
    /// rate ≠ 1 のクリップがある。
    ///
    /// `scaleTimeRange` だけでも再生・書き出しは成立するが、実効フレームレートが
    /// rate 倍になる（rate=10 の 30fps 素材なら 300fps 相当）。videoComposition の
    /// `frameDuration` で出力フレームレートに上限を掛けるために装着する。
    var hasRateChange = false
    /// 解像度・向き（`preferredTransform`）が混在している。
    /// renderSize へ揃えるために装着する（S8 で正式解禁）。
    var hasMixedFormats = false
    /// ユーザーが掛けたクリップの向き（`TimelineClip.orientation`）がある。
    ///
    /// 無装着経路はトラックの `preferredTransform` しか反映しないので、装着しないと
    /// 回転・反転が**映像にだけ効かない**（`TimelineRenderLayout` には入るので
    /// モザイクだけが回り、顔が素通しになる）。ここは必ず装着側へ倒す。
    var hasClipOrientation = false
    /// ユーザーが掛けたクリップの変形（`TimelineClip.transform`）がある。
    ///
    /// 無装着経路は配置矩形を常にアスペクトフィットのまま（無変形）使うので、
    /// 装着しないと拡大縮小・位置の変更が**映像にだけ効かない**（`hasClipOrientation` と
    /// 同じ事故: `TimelineRenderLayout` には入るのでモザイクだけが動き、顔が素通しになる）。
    /// 単一クリップ・同一フォーマットで変形だけを掛けたタイムラインでもここが真にならないと
    /// `VideoCompositionPlan.decide` が `.none` に倒れ、変形が映像にもモザイクにも
    /// 無言で効かなくなる。
    var hasClipTransform = false
    /// 出力枠のクロップ（`TimelineState.crop`）が全面（`.full`）でない。
    ///
    /// 無装着経路は配置矩形を常にアスペクトフィットのまま（クロップなし）使うので、
    /// 装着しないとクロップが**映像にだけ効かない**（`hasClipOrientation` / `hasClipTransform`
    /// と同じ事故: `TimelineRenderLayout` には入るのでモザイクだけが動き、顔が素通しになる）。
    var hasCrop = false
    /// 出力解像度を先頭クリップの自然サイズから強制的に変える必要がある
    /// （無料プランの解像度制限による縮小。`ExportRestrictionPolicy` 参照）。
    /// これが真のときだけの単一クリップ・無変換タイムラインでも装着を強制しないと、
    /// 縮小後のサイズがどこにも反映されない。
    var forcesRenderSize = false

    /// build 中に集めたクリップ情報から判定材料を求める唯一の入口。
    static func from(placements: [ClipPlacement],
                     overlaps: [TimelineMapping.Overlap],
                     crop: CropRect = .full,
                     forcesRenderSize: Bool = false) -> VideoCompositionConditions {
        let reference = placements.first?.format
        return VideoCompositionConditions(
            hasTransitions: !overlaps.isEmpty,
            hasRateChange: placements.contains { $0.clip.rate != 1.0 },
            hasMixedFormats: placements.contains { $0.format != reference },
            hasClipOrientation: placements.contains { !$0.clip.orientation.isIdentity },
            hasClipTransform: placements.contains { !$0.clip.transform.isIdentity },
            hasCrop: !crop.isFull,
            forcesRenderSize: forcesRenderSize)
    }
}

/// 映像合成の経路。分岐判定をこの決定関数 1 箇所に閉じ込める。
///
/// - `none`: `AVVideoComposition` を装着しない。**無変換構成**（単一トラック・
///   変換なし）はフェーズ1 と同じ忠実度を保つ（`CompositionFidelityTests` の契約）。
/// - `attach`: 装着する。プレビューは `AVPlayerItem.videoComposition`、書き出しは
///   `AVAssetReaderVideoCompositionOutput` 経由で合成済みフレームを受け取る。
enum VideoCompositionPlan: Equatable {
    case none
    case attach

    /// 判定基準（1 つでも真なら `.attach`。すべて偽のときだけ `.none`）。
    /// 入口はこの 1 つだけにしてある（条件を個別 Bool で受ける素の入口は置かない）。
    static func decide(conditions: VideoCompositionConditions) -> VideoCompositionPlan {
        let needsComposition = conditions.hasTransitions
            || conditions.hasRateChange
            || conditions.hasMixedFormats
            || conditions.forcesRenderSize
            || conditions.hasClipOrientation
            || conditions.hasClipTransform
            || conditions.hasCrop
        return needsComposition ? .attach : .none
    }
}

/// `TimelineState` + builder が決めたトラック割り当てから `AVMutableVideoComposition`
/// を組む。
///
/// **ランプの単一情報源は `TransitionKind`**（`parameters(progress:side:)` /
/// `incomingLayerOpacityRamp` / `rampBreakpoints`）であり、ここに視覚変換の数式を
/// 書かない。重なり区間の顔位置（`TransitionKind.visibleLandmarks`）と同じ関数から
/// 生成することで、モザイクとフレームが必ず一致する。
///
/// **`preferredTransform` はレイヤ instruction に畳み込む。** 装着時の writer 側は
/// identity・出力サイズは `renderSize` にすること（`VideoMosaicExporter` 参照）。
/// 両方で回転を掛けると縦動画が横倒し／180 度回転する。
enum VideoCompositionFactory {
    /// 出力フレームレートの上限。rate=10 のクリップは実効 300fps 相当になるため、
    /// そのまま合成すると書き出しが極端に遅くなる（計画のリスク 1）。
    static let maxFrameRate: Double = 60
    /// 出力フレームレートの下限（フレームレートが取得できない素材の保険）。
    static let minFrameRate: Double = 1
    /// フレームレート不明時の既定値。
    static let defaultFrameRate: Double = 30

    /// - Parameter crop: 出力枠のクロップ（`TimelineState.crop`）。`.full`（既定）は
    ///   従来どおりクロップなし。非 `.full` は他の条件が無くても装着を強制する
    ///   （`VideoCompositionConditions.hasCrop`）。
    /// - Parameter preCropFrameOverride: 非 nil のとき、先頭クリップから求まる自然な
    ///   `renderSize(for:)` の代わりにこのサイズを「クロップ**前**の出力枠」として使う
    ///   （画面比率を選んでいるときの `TimelineAspectRatio.renderSize` の結果を渡すこと）。
    ///   **クロップはこの枠に対して掛かる**（`CropRect` 型 doc の確定した適用順序:
    ///   向き → AspectFit → CropRect → ClipTransform）。無料プランの解像度制限（後述の
    ///   `renderSizeOverride`）はここに含めないこと——制限はクロップの**後**に効く。
    /// - Parameter renderSizeOverride: 非 nil のとき、実際に書き出す最終ピクセルサイズ
    ///   （クロップ・無料プランの解像度制限まで適用した後のサイズ）として使う
    ///   （`ExportRestrictionPolicy.clampedResolution` の結果、またはクロップだけを
    ///   適用した `CropRect.outputSize(fittingFrame:)` の結果を渡すこと）。
    ///   これを渡すと、他の条件が無くても装着が強制される（`forcesRenderSize`）。
    ///   nil のときは `crop.isFull` なら `preCropFrameOverride` をそのまま、
    ///   そうでなければ `crop.outputSize(fittingFrame:)` を自前で計算する。
    /// - Returns: 装着する `AVMutableVideoComposition`（`.none` 判定なら nil）と、
    ///   顔座標を合成フレーム基準へ写すためのレイアウト（装着しないときは恒等）。
    static func make(placements: [ClipPlacement],
                     overlaps: [TimelineMapping.Overlap],
                     totalDuration: Double,
                     crop: CropRect = .full,
                     preCropFrameOverride: CGSize? = nil,
                     renderSizeOverride: CGSize? = nil)
    -> (videoComposition: AVMutableVideoComposition?, layout: TimelineRenderLayout) {
        let conditions = VideoCompositionConditions.from(
            placements: placements, overlaps: overlaps, crop: crop,
            forcesRenderSize: renderSizeOverride != nil)
        guard VideoCompositionPlan.decide(conditions: conditions) == .attach,
              let first = placements.first else {
            return (nil, .identity)
        }

        let naturalFirst = renderSize(for: first.format, orientation: first.clip.orientation)
        // クロップ**前**の出力枠（画面比率適用後）。フォールバックの優先順位は
        // 「明示された pre-crop 枠 → 明示された最終サイズ（旧・単一パラメータ時代の互換）→
        // 自然サイズ」。クロップが無いときは `AspectFit` の正規化結果はこの枠の絶対値に
        // 依存しない（比例不変）ため、既存の呼び出し（`renderSizeOverride` だけを渡す）の
        // 挙動は変えない。
        let preCropFrame = preCropFrameOverride ?? renderSizeOverride ?? naturalFirst
        // 実際に書き出す最終キャンバス（クロップ＋無料プランの制限まで適用した後）。
        let renderSize = renderSizeOverride
            ?? (crop.isFull ? preCropFrame : crop.outputSize(fittingFrame: preCropFrame))
        var layoutRects: [UUID: CGRect] = [:]
        var orientations: [UUID: ClipOrientation] = [:]
        var transforms: [UUID: CGAffineTransform] = [:]
        for placement in placements {
            let orientation = placement.clip.orientation
            // **`RenderPlacement.make` が fit → crop の合成の唯一の場所。** 向きを掛ける
            // 前のサイズ + 向きを渡すこと（`RenderPlacement.make` が内部で向きを掛けるため、
            // ここで先に向きを掛けた `displaySize(of:orientation:)` を渡すと二重適用になる）。
            let sourceDisplay = sourceDisplaySize(of: placement.format)
            let fitted = RenderPlacement.make(displaySize: sourceDisplay, orientation: orientation,
                                              frame: preCropFrame, crop: crop)
            // **変形の適用点はここ 1 箇所だけ。** `RenderPlacement.make`（fit → crop）の
            // 結果へ `ClipTransform.applied(to:)` を 1 回だけ掛け、その結果を映像側
            // （`fitTransform` の `placement` 引数）とモザイク側（`layoutRects` →
            // `TimelineRenderLayout`）の両方へ渡す。ここ以外で scale/offset の算術を
            // 書くと、映像とモザイクが別々に進化して顔が素通しになる
            // （`ClipTransformParityTests` が唯一の呼び出し元であることを固定している）。
            // 適用順序は 向き → AspectFit → CropRect → ClipTransform で確定している。
            let rect = placement.clip.transform.applied(to: fitted)
            layoutRects[placement.clip.id] = rect
            orientations[placement.clip.id] = orientation
            transforms[placement.clip.id] = fitTransform(format: placement.format,
                                                         orientation: orientation,
                                                         placement: rect,
                                                         renderSize: renderSize)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(for: placements)
        videoComposition.instructions = instructions(placements: placements,
                                                     overlaps: overlaps,
                                                     transforms: transforms,
                                                     renderSize: renderSize,
                                                     totalDuration: totalDuration)
        // **`orientations` を渡し忘れないこと。** 映像だけが回ってモザイクが素材の
        // まま残り、顔が素通しになる（このアプリで最も重い事故）。
        return (videoComposition, TimelineRenderLayout(placements: layoutRects,
                                                       orientations: orientations))
    }

    // MARK: - サイズ・変換

    /// `preferredTransform` 適用後の表示サイズ（縦動画なら縦横が入れ替わる）。
    ///
    /// - Parameter orientation: ユーザーが掛けたクリップの向き。90 / 270 度で
    ///   さらに縦横が入れ替わる。既定の `.identity` は「向きを意識しない既存の
    ///   呼び出し（テスト等）の挙動を変えない」ための後方互換値で、
    ///   **実アプリの経路（`TimelineCompositionBuilder` / `make`）は必ず渡す**。
    static func displaySize(of format: TimelineCompositionBuilder.VideoFormat,
                            orientation: ClipOrientation = .identity) -> CGSize {
        let rect = CGRect(origin: .zero, size: format.size).applying(format.transform)
        return orientation.displaySize(CGSize(width: abs(rect.width), height: abs(rect.height)))
    }

    /// 向きを掛ける**前**の表示サイズ（`preferredTransform` だけ適用した素材の見た目）。
    /// 向きのアフィン変換はこのサイズを入力に取る（`ClipRenderTransform.make`）。
    static func sourceDisplaySize(of format: TimelineCompositionBuilder.VideoFormat) -> CGSize {
        displaySize(of: format, orientation: .identity)
    }

    /// 出力解像度の**自然な**値。**先頭クリップの映像フォーマット基準**（表示サイズ）。
    /// エンコーダの都合で偶数へ丸める（奇数サイズは HEVC/H.264 で扱いが崩れる）。
    ///
    /// **ユーザーが画面比率を選んでいるときの最終的な出力枠はこの値ではない。**
    /// `TimelineAspectRatio.renderSize(fittingSourceSize:)` がこの結果に掛かり、さらに
    /// 無料プランの `ExportRestrictionPolicy.clampedResolution` が掛かる。3 段の合成は
    /// `TimelineCompositionBuilder.build` の 1 箇所だけで行う（結果は
    /// `Built.outputSize`）。UI も書き出しもそちらを読むこと。
    ///
    /// **仕様（S8 で意図的にこう決めた）**: 混在タイムラインの出力解像度は先頭クリップが
    /// 決める。他のクリップはこの枠へアスペクトフィット（レターボックス）される。
    /// 実測: `[320x240, 640x480]` → `renderSize=(320,240)`（640x480 側が縮小される）、
    /// `[640x480, 320x240]` → `(640,480)`（320x240 側が拡大される）。
    /// **並べ替えで先頭が変わると出力解像度も変わる。**
    ///
    /// 理由: 「最大解像度に合わせる」と低解像度素材の拡大でファイルサイズと書き出し時間だけが
    /// 膨らみ、「最小に合わせる」と主素材の画質が落ちる。ユーザーが最初に置いたクリップを
    /// 主素材と見なすのが最も予測しやすいため、先頭基準に倒した。
    ///
    /// **ユーザーへの提示（S10b で実装済み）**: S6 までは `mixedVideoFormats` エラーで
    /// 混在自体を拒否していたが、S8 でそのガードを外したため無通知になっていた。現在は
    /// この関数の結果が `TimelineCompositionBuilder.Built.outputSize` →
    /// `MosaicEditorModel.outputRenderSize`（`@Published`）を経由して
    /// `VideoControlsView` の情報行に**常時表示**される。縮小されるクリップがあるとき
    /// （`Built.downscaledClipIDs` / `MosaicEditorModel.hasDownscaledClips`。判定は
    /// `TimelineOutputSummary.downscaledIndices`）は注意色になる。
    /// **表示側で renderSize を再計算しないこと**（この関数が単一実装）。
    ///
    /// **クリップの向き（回転・反転）も先頭クリップぶんだけ効く（S12 でこう決めた）**:
    /// 先頭クリップを 90 度回すと出力の縦横も入れ替わる。他のクリップを回しても
    /// 出力枠は変わらず、回った結果がこの枠へレターボックスされる。
    /// 「先頭クリップが主素材」という既存の規則をそのまま延長したもので、
    /// 回転を「主素材の見せ方の変更」として扱うのが最も予測しやすい。
    ///
    /// **クリップの変形（`TimelineClip.transform`）はここに渡さない（意図的）。**
    /// 先頭クリップを 2 倍に拡大したからといって出力解像度が 2 倍になるのは誤りである
    /// —— 変形は「出力枠の中でどう配置されるか」（レターボックス配置矩形そのもの）を
    /// 変えるだけで、出力枠自体（`renderSize`）の大きさを決める要素ではない。
    /// `orientation` が縦横比を変える（＝出力枠の形そのものが変わる）のとは性質が違う。
    /// 変形は `make(placements:overlaps:totalDuration:renderSizeOverride:)` 内で
    /// `AspectFit.placement(...)` の結果へ後から掛かる（型 doc 参照）。
    static func renderSize(for format: TimelineCompositionBuilder.VideoFormat,
                           orientation: ClipOrientation = .identity) -> CGSize {
        let display = displaySize(of: format, orientation: orientation)
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = (value / 2).rounded() * 2
            return max(2, rounded.isFinite ? rounded : 2)
        }
        return CGSize(width: even(display.width), height: even(display.height))
    }

    /// 素材フレーム → 合成フレームの基本変換
    /// （`preferredTransform` の正規化 + クリップの向き + アスペクトフィット）。
    ///
    /// **向き以降の数式はここに書かない。** `ClipRenderTransform.make`（コア層）を
    /// 呼ぶだけにしてあるのは、モザイク座標の写像（`TimelineRenderLayout.remap`）と
    /// 同じ `ClipOrientation` / `AspectFit` から作られていることをコア層のテストで
    /// 固定するためである（`ClipOrientationTests`）。ここに回転行列を書き写すと、
    /// 映像とモザイクが別々に進化して顔が素通しになる。
    static func fitTransform(format: TimelineCompositionBuilder.VideoFormat,
                             orientation: ClipOrientation = .identity,
                             placement: CGRect,
                             renderSize: CGSize) -> CGAffineTransform {
        // preferredTransform を掛けた矩形は原点が負になり得るので、左上を 0 へ寄せる。
        let rotated = CGRect(origin: .zero, size: format.size).applying(format.transform)
        let normalized = format.transform.concatenating(
            CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
        let display = sourceDisplaySize(of: format)
        guard display.width > 0, display.height > 0 else { return normalized }
        return normalized.concatenating(
            ClipRenderTransform.make(displaySize: display, orientation: orientation,
                                     placement: placement, renderSize: renderSize))
    }

    /// 出力フレームレート（上限 `maxFrameRate`）。素材の公称値の最大を採り、
    /// rate≠1 による実効フレームレートの跳ね上がりはここで頭打ちにする。
    static func frameDuration(for placements: [ClipPlacement]) -> CMTime {
        let rates = placements.map { Double($0.frameRate) }.filter { $0.isFinite && $0 > 0 }
        let base = rates.max() ?? defaultFrameRate
        let clamped = min(max(base, minFrameRate), maxFrameRate)
        return CMTime(value: 600, timescale: CMTimeScale(600 * clamped))
    }

    // MARK: - instruction（隙間なし被覆）

    /// 合成タイムライン全体を隙間なく覆う instruction 列を作る。
    ///
    /// 区間の切れ目は「各クリップの開始・終了」と「各重なりのランプ分割点
    /// （`TransitionKind.rampBreakpoints`）」の和集合。AVFoundation は instruction の
    /// 時間範囲が連続していないと再生・書き出しが破綻するため、末尾は必ず
    /// `totalDuration` まで伸ばす。
    static func instructions(placements: [ClipPlacement],
                             overlaps: [TimelineMapping.Overlap],
                             transforms: [UUID: CGAffineTransform],
                             renderSize: CGSize,
                             totalDuration: Double) -> [AVMutableVideoCompositionInstruction] {
        var boundaries: Set<Double> = [0, totalDuration]
        for placement in placements {
            boundaries.insert(placement.start)
            boundaries.insert(placement.end)
        }
        for overlap in overlaps {
            for breakpoint in overlap.kind.rampBreakpoints {
                boundaries.insert(overlap.start + overlap.duration * breakpoint)
            }
        }
        let sorted = boundaries.filter { $0.isFinite && $0 >= 0 && $0 <= totalDuration }.sorted()
        var result: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<max(sorted.count - 1, 0) {
            let (from, to) = (sorted[index], sorted[index + 1])
            guard to > from else { continue }
            let active = placements.filter { $0.start <= from && from < $0.end }
            guard !active.isEmpty else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(from), end: time(to))
            instruction.layerInstructions = layerInstructions(
                active: active,
                segment: Segment(overlaps: overlaps, transforms: transforms,
                                 renderSize: renderSize, from: from, to: to))
            result.append(instruction)
        }
        // 端数の丸めで最後の instruction が composition の末尾に届かないと、
        // AVFoundation の検証で「隙間あり」になる。末尾だけ明示的に伸ばす。
        if let last = result.last {
            let end = time(totalDuration)
            if last.timeRange.end < end {
                last.timeRange = CMTimeRange(start: last.timeRange.start, end: end)
            }
        }
        return result
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// instruction 1 区間ぶんの生成コンテキスト。
    private struct Segment {
        let overlaps: [TimelineMapping.Overlap]
        /// クリップ id → 素材フレーム → 合成フレームの基本変換。
        let transforms: [UUID: CGAffineTransform]
        let renderSize: CGSize
        /// 区間 [from, to)（合成時刻・秒）。
        let from: Double
        let to: Double
    }

    /// 区間 [from, to) に映るクリップのレイヤ instruction。
    ///
    /// 重なり区間では**前面 = outgoing / 背面 = incoming** の順に並べる
    /// （`TransitionKind.incomingLayerOpacityRamp` の doc の合成式と同じ前提）。
    private static func layerInstructions(active: [ClipPlacement],
                                          segment: Segment)
    -> [AVMutableVideoCompositionLayerInstruction] {
        let (from, to) = (segment.from, segment.to)
        let range = CMTimeRange(start: time(from), end: time(to))
        let overlap = active.count >= 2
            ? segment.overlaps.first { $0.start <= from && from < $0.end }
            : nil
        // 前面（outgoing）が先。重なりが無ければ順序は意味を持たない。
        let ordered: [ClipPlacement]
        if let overlap {
            ordered = active.filter { $0.clip.id == overlap.outgoingClipID }
                + active.filter { $0.clip.id != overlap.outgoingClipID }
        } else {
            ordered = active
        }
        return ordered.map { placement in
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: placement.track)
            let base = segment.transforms[placement.clip.id] ?? .identity
            guard let overlap,
                  let side = side(of: placement, in: overlap) else {
                layer.setTransform(base, at: range.start)
                layer.setOpacity(1, at: range.start)
                return layer
            }
            applyRamps(to: layer, input: RampInput(
                kind: overlap.kind, side: side,
                from: progress(of: from, in: overlap),
                to: progress(of: to, in: overlap),
                base: base, renderSize: segment.renderSize, range: range))
            return layer
        }
    }

    private static func side(of placement: ClipPlacement,
                             in overlap: TimelineMapping.Overlap) -> TransitionSide? {
        switch placement.clip.id {
        case overlap.outgoingClipID: return .outgoing
        case overlap.incomingClipID: return .incoming
        default: return nil
        }
    }

    private static func progress(of compositionTime: Double,
                                 in overlap: TimelineMapping.Overlap) -> Double {
        guard overlap.duration > 0 else { return 0 }
        return TransitionKind.clampedProgress((compositionTime - overlap.start) / overlap.duration)
    }

    /// 1 レイヤぶんのランプ入力（進行度の区間と、そのレイヤの基本変換）。
    private struct RampInput {
        let kind: TransitionKind
        let side: TransitionSide
        /// 区間端の進行度（0...1）。
        let from: Double
        let to: Double
        let base: CGAffineTransform
        let renderSize: CGSize
        let range: CMTimeRange
    }

    /// 1 レイヤぶんのランプ（不透明度・変換・クロップ）を設定する。
    /// 値はすべて `TransitionKind` の純関数から取る（数式をここに書かない）。
    private static func applyRamps(to layer: AVMutableVideoCompositionLayerInstruction,
                                   input: RampInput) {
        let (kind, side, p0, p1) = (input.kind, input.side, input.from, input.to)
        let (base, renderSize, range) = (input.base, input.renderSize, input.range)
        let start = kind.parameters(progress: p0, side: side)
        let end = kind.parameters(progress: p1, side: side)

        switch side {
        case .outgoing:
            layer.setOpacityRamp(fromStartOpacity: Float(start.opacity),
                                 toEndOpacity: Float(end.opacity),
                                 timeRange: range)
        case .incoming:
            // 背面レイヤは「意図した合成結果」を再現する値を使う（doc 参照）。
            let ramp = kind.incomingLayerOpacityRamp(from: p0, to: p1)
            layer.setOpacityRamp(fromStartOpacity: Float(ramp.start),
                                 toEndOpacity: Float(ramp.end),
                                 timeRange: range)
        }

        let startTransform = base.concatenating(translation(start.translation, in: renderSize))
        let endTransform = base.concatenating(translation(end.translation, in: renderSize))
        if startTransform == endTransform {
            layer.setTransform(startTransform, at: range.start)
        } else {
            layer.setTransformRamp(fromStart: startTransform, toEnd: endTransform, timeRange: range)
        }

        // クロップは**素材座標**で指定し、変換より前に適用される。画面上の可視領域を
        // 変換の逆写像で素材座標へ戻す（回転済み素材でも画面基準のワイプになる）。
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard start.visibleRect != unit || end.visibleRect != unit else { return }
        let inverse = startTransform.inverted()
        let startCrop = screenRect(start.visibleRect, in: renderSize).applying(inverse)
        let endCrop = screenRect(end.visibleRect, in: renderSize)
            .applying(endTransform.inverted())
        if startCrop == endCrop {
            layer.setCropRectangle(startCrop, at: range.start)
        } else {
            layer.setCropRectangleRamp(fromStartCropRectangle: startCrop,
                                       toEndCropRectangle: endCrop,
                                       timeRange: range)
        }
    }

    private static func translation(_ vector: CGVector, in renderSize: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: vector.dx * renderSize.width,
                          y: vector.dy * renderSize.height)
    }

    private static func screenRect(_ normalized: CGRect, in renderSize: CGSize) -> CGRect {
        CGRect(x: normalized.minX * renderSize.width,
               y: normalized.minY * renderSize.height,
               width: normalized.width * renderSize.width,
               height: normalized.height * renderSize.height)
    }
}
