import CoreGraphics
import Foundation
import MosaicCore

// 出力サイズの決定。`TimelineCompositionBuilder.swift` が file_length 上限に達したため
// 分けてある（`TimelineStateCrop` 等と同じ分け方）。

extension TimelineCompositionBuilder {
    /// 出力枠のサイズ決定を 1 箇所にまとめたもの。
    ///
    /// **段の順序に意味がある**（自然な値 → 向き → 画面比率 → クロップ → 無料プランの上限）
    /// ので、呼び出し側でばらして書かないこと。ばらすと片方の経路だけ順序が違う、という
    /// 種類の欠陥ができる。**クロップは画面比率の後・無料プラン制限の前**（`CropRect` 型
    /// doc の確定した適用順序と同じ理由: 制限は「実際に書き出す解像度」＝クロップ後の
    /// サイズで判定しないと、クロップで小さくなった映像に対して無駄に厳しい／緩い判定になる）。
    struct OutputSizing {
        /// 先頭クリップの向きまで含めた「自然な」出力枠。
        let natural: CGSize
        /// 画面比率とクロップと無料プランの上限まで掛けた、実際に書き出す枠。
        let clamped: CGSize
        let restriction: ExportRestriction
        /// 自然な枠と同じなら nil（＝合成の装着を強制しない）。
        let renderSizeOverride: CGSize?
        /// クロップ**前**・画面比率適用**後**の出力枠。`natural` と同じなら nil。
        /// `VideoCompositionFactory.make` のフィット計算（`RenderPlacement.make` の
        /// `frame` 引数）に渡す——クロップはこの枠に対して切られる。
        let preCropFrameOverride: CGSize?
    }

    static func outputSizing(placements: [ClipPlacement],
                             aspectRatio: TimelineAspectRatio,
                             crop: CropRect,
                             isPro: Bool,
                             totalDuration: Double) -> OutputSizing {
        // 出力解像度の**自然な**値の算出は `VideoCompositionFactory.renderSize(for:)` の
        // 単一実装を使う（コア層に再実装しない。表示と実出力が食い違う二重管理を作らない
        // ため。`TimelineOutputSummary` の doc 参照）。
        // **先頭クリップの向き（回転・反転）も渡す。** 渡し忘れると回した縦動画の
        // 出力枠だけが横のままになり、映像が枠に収まらない。
        let natural = placements.first.map {
            VideoCompositionFactory.renderSize(for: $0.format, orientation: $0.clip.orientation)
        } ?? .zero
        // 画面比率の適用は、自然な値の**結果に掛ける後処理**（`TimelineAspectRatio` の doc）。
        // `.source` は入力をそのまま返すので、この 1 行は従来経路を一切変えない。
        // 向きを掛けた**後**のサイズへ適用する（回した縦動画に 16:9 を選んだとき、
        // 回す前の横向きサイズを基準にすると枠が二重に倒れる）。
        let aspect = aspectRatio.renderSize(fittingSourceSize: natural)
        // クロップは画面比率適用後の枠に対して掛ける（`CropRect` 型 doc の確定した
        // 適用順序: 向き → AspectFit → CropRect → ClipTransform）。**ここで初めて画が切れる。**
        // `.full` は入力をそのまま返すので、クロップを使わない経路は従来どおり
        // `aspect` がそのまま実出力サイズの起点になる。
        let cropped = crop.isFull ? aspect : crop.outputSize(fittingFrame: aspect)
        // 無料プランの制限は「実際に書き出す解像度」＝クロップまで適用した**後**のサイズで
        // 判定する（クロップの後に効く。順序を逆にすると、クロップ後は収まるはずの尺が
        // クロップ前のサイズで誤って縮小される）。
        let restriction = ExportRestrictionPolicy.decide(
            isPro: isPro, durationSeconds: totalDuration, resolution: cropped)
        let clamped: CGSize
        if case .exceedsResolution(let limit) = restriction {
            clamped = ExportRestrictionPolicy.clampedResolution(cropped, shortSideLimit: limit)
        } else {
            clamped = cropped
        }
        // 自然な出力枠と同じサイズになったなら override を渡さない（＝装着を強制しない）。
        // 素材がちょうどその比率だった場合に無変換タイムラインの忠実度
        // （`CompositionFidelityTests` の bit 同一契約）を壊さないため。
        return OutputSizing(natural: natural, clamped: clamped, restriction: restriction,
                            renderSizeOverride: clamped == natural ? nil : clamped,
                            preCropFrameOverride: aspect == natural ? nil : aspect)
    }
}
