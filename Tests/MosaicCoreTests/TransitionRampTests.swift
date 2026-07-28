import CoreGraphics
import XCTest
@testable import MosaicCore

/// S8: AVVideoComposition の**ランプ表現**が `TransitionKind` の意図と一致することを
/// 純ロジックだけで固定する。
///
/// AVFoundation のランプ（opacity / transform / cropRectangle）は与えた 2 端点の間を
/// **線形補間**する。したがって `parameters(progress:side:)` が各区間内で線形でない
/// 種類が現れた瞬間、ランプは意図とずれる（＝顔位置とフレームの食い違い＝モザイク漏れ）。
/// ここで「分割点（`rampBreakpoints`）ごとの区間内では線形」を全種類・全区間について
/// 固定しておくことで、新しい種類を足したときに気付ける。
final class TransitionRampTests: XCTestCase {
    private let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: - 区分線形性（ランプで再現できることの前提）

    /// 全種類・全側・全区間について、区間の中点の `parameters` が両端点の平均に一致すること。
    /// （= 区間内が線形 ⇔ 端点だけ渡す AVFoundation のランプで誤差なく再現できる）
    func test_parametersAreLinearWithinEachRampSegment() {
        for kind in TransitionKind.allCases {
            let breaks = kind.rampBreakpoints
            XCTAssertEqual(breaks.first, 0, "\(kind): 分割点が 0 から始まっていない")
            XCTAssertEqual(breaks.last, 1, "\(kind): 分割点が 1 で終わっていない")
            for index in 0..<(breaks.count - 1) {
                let (lower, upper) = (breaks[index], breaks[index + 1])
                XCTAssertLessThan(lower, upper, "\(kind): 分割点が昇順でない")
                let mid = (lower + upper) / 2
                for side in TransitionSide.allCases {
                    let a = kind.parameters(progress: lower, side: side)
                    let b = kind.parameters(progress: upper, side: side)
                    let m = kind.parameters(progress: mid, side: side)
                    XCTAssertEqual(m.opacity, (a.opacity + b.opacity) / 2, accuracy: 1e-9,
                                   "\(kind)/\(side) [\(lower),\(upper)]: opacity が非線形")
                    XCTAssertEqual(m.translation.dx, (a.translation.dx + b.translation.dx) / 2,
                                   accuracy: 1e-9,
                                   "\(kind)/\(side) [\(lower),\(upper)]: translation.dx が非線形")
                    XCTAssertEqual(m.translation.dy, (a.translation.dy + b.translation.dy) / 2,
                                   accuracy: 1e-9,
                                   "\(kind)/\(side) [\(lower),\(upper)]: translation.dy が非線形")
                    for (label, value, expected) in [
                        ("minX", m.visibleRect.minX, (a.visibleRect.minX + b.visibleRect.minX) / 2),
                        ("minY", m.visibleRect.minY, (a.visibleRect.minY + b.visibleRect.minY) / 2),
                        ("width", m.visibleRect.width, (a.visibleRect.width + b.visibleRect.width) / 2),
                        ("height", m.visibleRect.height, (a.visibleRect.height + b.visibleRect.height) / 2)
                    ] {
                        XCTAssertEqual(value, expected, accuracy: 1e-9,
                                       "\(kind)/\(side) [\(lower),\(upper)]: visibleRect.\(label) が非線形")
                    }
                }
            }
        }
    }

    /// 折れ点を持つのは fadeToBlack だけであること（分割点の仕様そのものの固定）。
    func test_onlyFadeToBlackIsPiecewise() {
        for kind in TransitionKind.allCases {
            XCTAssertEqual(kind.rampBreakpoints, kind == .fadeToBlack ? [0, 0.5, 1] : [0, 1],
                           "\(kind): 分割点が想定と違う")
        }
    }

    // MARK: - 2 レイヤ合成（背面の不透明度）

    /// 前面 = outgoing / 背面 = incoming の over 合成が、`parameters` の意図
    /// （a_out·O + a_in·I、残りは黒）を再現すること。
    ///
    /// 検算は「O=1・I=0 の画」と「O=0・I=1 の画」の 2 つで行う。前者の合成値が a_out に、
    /// 後者が a_in に一致すれば、線形合成なので任意の画で意図どおりになる。
    func test_incomingLayerOpacityReproducesIntendedComposite() {
        for kind in TransitionKind.allCases {
            for step in 1...19 {
                let p = Double(step) / 20
                let outgoing = kind.parameters(progress: p, side: .outgoing).opacity
                let incoming = kind.parameters(progress: p, side: .incoming).opacity
                let back = kind.incomingLayerOpacityInside(progress: p)
                XCTAssertGreaterThanOrEqual(back, 0, "\(kind) p=\(p): 背面不透明度が負")
                XCTAssertLessThanOrEqual(back, 1, "\(kind) p=\(p): 背面不透明度が 1 超")
                // I だけが写っている画: 合成値 = (1 − a_out)·back。これが a_in と一致すべき。
                // スライド・ワイプ（a_out = 1）は画面上で重ならないので検算対象外。
                if outgoing < 1 {
                    XCTAssertEqual((1 - outgoing) * back, incoming, accuracy: 1e-9,
                                   "\(kind) p=\(p): 背面レイヤの合成結果が意図と違う")
                }
            }
        }
    }

    /// crossfade の背面（incoming）ランプは端点まで含めて 1 のままであること
    /// （素直に a_in = p を与えると中間で黒が透けて暗くなる、の回帰ガード）。
    func test_crossfadeKeepsBackLayerFullyOpaque() {
        let ramp = TransitionKind.crossfade.incomingLayerOpacityRamp(from: 0, to: 1)
        XCTAssertEqual(ramp.start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ramp.end, 1.0, accuracy: 1e-9)
    }

    /// fadeToBlack は前半で背面が完全に沈み（黒が見える）、後半で 0 → 1 に戻ること。
    func test_fadeToBlackBackLayerStaysHiddenInFirstHalf() {
        let first = TransitionKind.fadeToBlack.incomingLayerOpacityRamp(from: 0, to: 0.5)
        XCTAssertEqual(first.start, 0, accuracy: 1e-9)
        XCTAssertEqual(first.end, 0, accuracy: 1e-9)
        let second = TransitionKind.fadeToBlack.incomingLayerOpacityRamp(from: 0.5, to: 1)
        XCTAssertEqual(second.start, 0, accuracy: 1e-9)
        XCTAssertEqual(second.end, 1, accuracy: 1e-9)
    }

    /// スライド・ワイプ（画面上で重ならない種類）の背面は常に不透明 1 であること。
    func test_nonOverlappingKindsKeepBackLayerOpaque() {
        for kind in [TransitionKind.slideLeft, .slideRight, .wipeLeft, .wipeRight] {
            let ramp = kind.incomingLayerOpacityRamp(from: 0, to: 1)
            XCTAssertEqual(ramp.start, 1.0, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(ramp.end, 1.0, accuracy: 1e-9, "\(kind)")
        }
    }

    /// 外挿したランプ端点と、区間内部の実値が一致すること
    /// （= 端点だけ渡す AVFoundation のランプが区間内で意図どおりに補間される）。
    func test_incomingLayerOpacityRampMatchesInteriorValues() {
        for kind in TransitionKind.allCases {
            let breaks = kind.rampBreakpoints
            for index in 0..<(breaks.count - 1) {
                let (lower, upper) = (breaks[index], breaks[index + 1])
                let ramp = kind.incomingLayerOpacityRamp(from: lower, to: upper)
                for step in 1...9 {
                    let t = Double(step) / 10
                    let p = lower + (upper - lower) * t
                    let interpolated = ramp.start + (ramp.end - ramp.start) * t
                    XCTAssertEqual(interpolated, kind.incomingLayerOpacityInside(progress: p),
                                   accuracy: 1e-9,
                                   "\(kind) [\(lower),\(upper)] t=\(t): ランプ補間が実値とずれる")
                }
            }
        }
    }

    // MARK: - 重なり区間のランドマーク union

    private func face(cx: Float, cy: Float, size: Float = 0.1) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [
            FaceLandmark(x: cx - size, y: cy - size),
            FaceLandmark(x: cx + size, y: cy - size),
            FaceLandmark(x: cx + size, y: cy + size),
            FaceLandmark(x: cx - size, y: cy + size)
        ], confidence: 0.9)
    }

    /// crossfade の中間では両側の顔がそのまま残る（= union が 2 顔になる）こと。
    func test_crossfadeKeepsBothSidesFaces() {
        let outgoing = TransitionKind.crossfade.visibleLandmarks([face(cx: 0.3, cy: 0.5)],
                                                                 progress: 0.5, side: .outgoing)
        let incoming = TransitionKind.crossfade.visibleLandmarks([face(cx: 0.7, cy: 0.5)],
                                                                 progress: 0.5, side: .incoming)
        XCTAssertEqual(outgoing.count + incoming.count, 2, "重なり中に片側の顔が落ちている")
        XCTAssertEqual(outgoing[0].points[0].x, 0.2, accuracy: 1e-6, "移動しないはずの顔が動いた")
    }

    /// fadeToBlack の前半では incoming 側（まだ黒の中）の顔が落ちること。
    func test_fadeToBlackDropsHiddenSide() {
        XCTAssertTrue(TransitionKind.fadeToBlack
            .visibleLandmarks([face(cx: 0.5, cy: 0.5)], progress: 0.25, side: .incoming).isEmpty)
        XCTAssertFalse(TransitionKind.fadeToBlack
            .visibleLandmarks([face(cx: 0.5, cy: 0.5)], progress: 0.25, side: .outgoing).isEmpty)
    }

    /// スライドでは顔が画面移動量ぶん平行移動し、画面外に出たら落ちること。
    func test_slideTranslatesFacesAndDropsOffscreen() {
        let moved = TransitionKind.slideLeft.visibleLandmarks([face(cx: 0.8, cy: 0.5)],
                                                              progress: 0.3, side: .outgoing)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].points[0].x, 0.8 - 0.1 - 0.3, accuracy: 1e-6,
                       "スライドの移動量がランプと一致しない")
        // 完全に左へ抜けた顔（中心 0.1 を 0.9 移動）は不可視。
        XCTAssertTrue(TransitionKind.slideLeft
            .visibleLandmarks([face(cx: 0.1, cy: 0.5, size: 0.05)],
                              progress: 0.9, side: .outgoing).isEmpty)
    }

    /// ワイプの境界を跨ぐ顔は、点を間引かず丸ごと残す（メッシュを壊さない・
    /// モザイクの過剰適用は安全側）。完全に隠れた顔だけが落ちる。
    func test_wipeKeepsStraddlingFaceAndDropsHiddenFace() {
        // 進行度 0.5 の wipeLeft では outgoing の可視域は [0, 0.5)。
        let straddling = TransitionKind.wipeLeft.visibleLandmarks([face(cx: 0.5, cy: 0.5)],
                                                                  progress: 0.5, side: .outgoing)
        XCTAssertEqual(straddling.count, 1, "境界を跨ぐ顔が丸ごと落ちた（モザイク不足）")
        XCTAssertEqual(straddling[0].points.count, 4, "点が間引かれてメッシュが壊れている")
        let hidden = TransitionKind.wipeLeft.visibleLandmarks([face(cx: 0.9, cy: 0.5, size: 0.05)],
                                                              progress: 0.5, side: .outgoing)
        XCTAssertTrue(hidden.isEmpty, "可視域の外の顔が残っている")
    }

    // MARK: - AspectFit / TimelineRenderLayout

    /// 縦横比が同じなら配置は単位矩形（恒等＝従来挙動）になること。
    func test_aspectFitIsIdentityForSameAspect() {
        let rect = AspectFit.placement(of: CGSize(width: 640, height: 480),
                                       in: CGSize(width: 320, height: 240))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 縦長素材を横長フレームへ収めると、左右に等幅の帯ができること。
    func test_aspectFitLetterboxesPortraitIntoLandscape() {
        let rect = AspectFit.placement(of: CGSize(width: 1080, height: 1920),
                                       in: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect.height, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, (1080.0 / 1920.0 * 1080.0) / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(rect.minX, (1 - rect.width) / 2, accuracy: 1e-9)
    }

    /// 壊れたサイズ（0・NaN）は恒等に倒すこと。
    func test_aspectFitFallsBackToIdentityForInvalidSizes() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(AspectFit.placement(of: .zero, in: CGSize(width: 100, height: 100)), unit)
        XCTAssertEqual(AspectFit.placement(of: CGSize(width: CGFloat.nan, height: 100),
                                           in: CGSize(width: 100, height: 100)), unit)
    }

    /// レイアウトの remap が顔座標を配置矩形へ写すこと・恒等では値を触らないこと。
    func test_renderLayoutRemapsFacesIntoPlacement() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(placements: [
            clipID: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        ])
        let remapped = layout.remap([face(cx: 0.5, cy: 0.5, size: 0.1)], clipID: clipID)
        XCTAssertEqual(remapped[0].points[0].x, 0.25 + 0.4 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(remapped[0].points[0].y, 0.4, accuracy: 1e-6, "縦方向は等倍のはず")
        let identity = TimelineRenderLayout.identity.remap([face(cx: 0.5, cy: 0.5)], clipID: clipID)
        XCTAssertEqual(identity[0], face(cx: 0.5, cy: 0.5), "恒等レイアウトで値が変化した")
    }
}
