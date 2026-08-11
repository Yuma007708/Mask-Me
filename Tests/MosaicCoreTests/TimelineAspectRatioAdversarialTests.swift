import CoreGraphics
import Foundation
import XCTest
@testable import MosaicCore

/// C（検証・敵対的テスト）: 出力の画面比率機能を壊しにかかる。
///
/// 対象: `TimelineAspectRatio.renderSize(fittingSourceSize:)` / `AspectFit.placement` /
/// `TimelineRenderLayout`。狙いは「極端な入力で、選んだ比率の形が保たれるか」
/// 「丸めの影響で顔座標が絵からずれないか」。
final class TimelineAspectRatioAdversarialTests: XCTestCase {
    private let clipID = UUID()

    // MARK: - 極端に小さい素材で「選んだ比率の形」が保たれるか

    /// 短辺が 1px しかない極端な素材（例: 3000x1 の激細バナー）で `.portrait9x16` を
    /// 選んだとき、出力枠は依然として「縦長」（幅 < 高さ）になるはずである。
    ///
    /// 実際には `even()` が短辺・長辺の両方を「2」へ丸めてしまい、
    /// 縦長のはずが 2x2 の正方形になる（選んだ比率の形が失われる）。
    func test_extremelyThinSource_portraitRatioStaysPortraitShaped() {
        let thin = CGSize(width: 3000, height: 1)
        let frame = TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: thin)
        XCTAssertLessThan(frame.width, frame.height,
                          "9:16 を選んだのに縦長にならない: \(frame)")
    }

    /// 同じく、短辺 1px の素材で `.landscape16x9` を選んだら横長（幅 > 高さ）のはず。
    func test_extremelyThinSource_landscapeRatioStaysLandscapeShaped() {
        let thin = CGSize(width: 1, height: 3000)
        let frame = TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: thin)
        XCTAssertGreaterThan(frame.width, frame.height,
                             "16:9 を選んだのに横長にならない: \(frame)")
    }

    /// 2x2 のごく小さい素材でも、選んだ比率どうしで出力の形が区別できるはず
    /// （9:16 と 16:9 が同じ frame になってはいけない）。
    func test_tinySource_distinctRatiosProduceDistinctShapes() {
        let tiny = CGSize(width: 2, height: 2)
        let portrait = TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: tiny)
        let landscape = TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: tiny)
        XCTAssertNotEqual(portrait, landscape,
                          "2x2 素材で 9:16 と 16:9 の出力枠が区別できない: \(portrait) vs \(landscape)")
        XCTAssertLessThan(portrait.width, portrait.height, "9:16 が縦長でない: \(portrait)")
        XCTAssertGreaterThan(landscape.width, landscape.height, "16:9 が横長でない: \(landscape)")
    }

    // MARK: - 巨大な素材（8K）でオーバーフロー・非有限値が出ないか

    func test_8KSource_noOverflowOrNonFiniteResults() {
        let source8K = CGSize(width: 7680, height: 4320)
        for ratio in TimelineAspectRatio.allCases {
            let frame = ratio.renderSize(fittingSourceSize: source8K)
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite, "\(ratio): \(frame)")
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    // MARK: - 奇数サイズ（1081x1921）での顔座標ずれ（px 単位で計測）

    /// 素材サイズが奇数のとき、実際の書き出しパイプラインを模して
    /// （raw display → `even()` で自然サイズへ丸め → その丸めた自然サイズへ比率を適用）
    /// 顔ランドマークが絵からピクセル単位でずれないかを固定する。
    ///
    /// ここでは「丸めた分だけモザイクがずれないか」を実際に計算して確認する。
    func test_oddSourceSize_landmarkStaysWithinSubPixelOfDrawnImage() {
        let rawDisplay = CGSize(width: 1081, height: 1921)  // 縦動画、奇数
        // VideoCompositionFactory.renderSize(for:) と同じ規則で自然サイズへ丸める。
        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded() * 2)
        }
        let naturalOutputSize = CGSize(width: even(rawDisplay.width), height: even(rawDisplay.height))

        for ratio in TimelineAspectRatio.allCases {
            let frame = ratio == .source ? naturalOutputSize
                : ratio.renderSize(fittingSourceSize: naturalOutputSize)
            // 実際の映像側変換と同じく、フレームへ収める対象は「素の raw display」。
            let place = AspectFit.placement(of: rawDisplay, in: frame)
            let layout = TimelineRenderLayout(placements: [clipID: place])
            let scale = place.width * frame.width / rawDisplay.width

            let probes: [CGPoint] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.02, y: 0.98),
                                     CGPoint(x: 0.99, y: 0.01)]
            for probe in probes {
                let set = FaceLandmarkSet(points: [FaceLandmark(x: Float(probe.x), y: Float(probe.y))],
                                          confidence: 1)
                guard let mapped = layout.remap([set], clipID: clipID).first?.points.first else {
                    return XCTFail("写像後のランドマークが取れない")
                }
                let mosaicX = CGFloat(mapped.x) * frame.width
                let mosaicY = CGFloat(mapped.y) * frame.height
                let drawnX = probe.x * rawDisplay.width * scale + place.minX * frame.width
                let drawnY = probe.y * rawDisplay.height * scale + place.minY * frame.height
                let dx = abs(mosaicX - drawnX)
                let dy = abs(mosaicY - drawnY)
                XCTAssertLessThan(dx, 1.0, "\(ratio) probe=\(probe) で \(dx)px ずれた")
                XCTAssertLessThan(dy, 1.0, "\(ratio) probe=\(probe) で \(dy)px ずれた")
            }
        }
    }

    // MARK: - 複数クリップで縦横混在 + 比率変更（フレームは 1 つ、配置は各クリップ独立）

    /// 先頭が横（1920x1080）、2 本目が縦（1080x1920）の混在タイムラインで
    /// `.square1x1` を選んだとき、両クリップとも中央揃え・アスペクト保持・
    /// 枠内に収まる（切り取りが起きない）ことを固定する。
    func test_mixedOrientationClips_bothPlaceCorrectlyUnderSharedFrame() {
        let landscapeClip = CGSize(width: 1920, height: 1080)
        let portraitClip = CGSize(width: 1080, height: 1920)
        // 出力枠は「先頭クリップ基準の自然サイズ」に比率を適用したもの
        // （TimelineCompositionBuilder と同じ手順）。
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let naturalOutputSize = CGSize(width: even(landscapeClip.width), height: even(landscapeClip.height))
        let frame = TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: naturalOutputSize)

        let clipA = UUID()
        let clipB = UUID()
        let placeA = AspectFit.placement(of: landscapeClip, in: frame)
        let placeB = AspectFit.placement(of: portraitClip, in: frame)
        let layout = TimelineRenderLayout(placements: [clipA: placeA, clipB: placeB])

        for (clip, source, place) in [(clipA, landscapeClip, placeA), (clipB, portraitClip, placeB)] {
            // 枠内に収まる。
            XCTAssertGreaterThanOrEqual(place.minX, -1e-9)
            XCTAssertGreaterThanOrEqual(place.minY, -1e-9)
            XCTAssertLessThanOrEqual(place.maxX, 1 + 1e-9)
            XCTAssertLessThanOrEqual(place.maxY, 1 + 1e-9)
            // アスペクト比を保つ。
            let drawn = CGSize(width: place.width * frame.width, height: place.height * frame.height)
            XCTAssertEqual(drawn.width / drawn.height, source.width / source.height, accuracy: 1e-6,
                           "\(clip) のアスペクト比が保たれていない")
            // 顔ランドマークの往復（矩形）。
            let rect = CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.2)
            let composed = layout.remap(rect, clipID: clip)
            guard let back = layout.inverseRemap(composed, clipID: clip) else {
                return XCTFail("\(clip) の逆写像が nil")
            }
            XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9)
            XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9)
        }
        // 2 つのクリップの配置は別々（同じ枠に押し込められて誤って共有されていないか）。
        XCTAssertNotEqual(placeA, placeB, "縦横混在なのに配置が同一 = 別クリップの配置が漏れている")
    }

    // MARK: - 比率を A → B → A と戻したときに完全復元するか（純粋関数としての往復）

    /// `TimelineState.aspectRatio` は履歴を持たない単純な列挙値なので、
    /// A → B → A の往復は保存される値そのものが等しいことで担保される。
    func test_toggleAspectRatioAThenBThenA_stateFullyRestores() {
        let original = TimelineState()
        let toB = original.settingAspectRatio(.square1x1)
        let backToA = toB.settingAspectRatio(.source)
        XCTAssertEqual(backToA, original, "A→B→A で状態が完全に元へ戻らない")
    }

    /// 出力サイズ計算そのものも、A→B→A で同じ入力に対して同じ出力を返す
    /// （比率適用は毎回 naturalOutputSize から再計算される純関数であり、
    /// 過去に何を選んだかの履歴に依存しない）。
    func test_toggleAspectRatioAThenBThenA_renderSizeIsPure() {
        let natural = CGSize(width: 1920, height: 1080)
        let firstA = TimelineAspectRatio.source.renderSize(fittingSourceSize: natural)
        _ = TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: natural)
        let secondA = TimelineAspectRatio.source.renderSize(fittingSourceSize: natural)
        XCTAssertEqual(firstA, secondA)
    }
}

extension TimelineAspectRatioAdversarialTests {
    // MARK: - フラット・フォールバック: ランダムな極端サイズでの往復・整合性フットプリント

    /// 乱数の素材サイズ（極端な比率・奇数を含む）× 全比率 × 乱数矩形で、
    /// remap→inverseRemap の往復が壊れない（nil にならない・大きくずれない）ことを
    /// 広く確認する（1 本 1 本手で書くと網羅できないパターンをまとめて叩く）。
    func test_fuzzedSizesAndRects_roundTripNeverDriftsBeyondSubPixel() {
        var rng = SystemRandomNumberGenerator()
        let clip = UUID()
        for _ in 0..<500 {
            let w = CGFloat.random(in: 1...8000, using: &rng)
            let h = CGFloat.random(in: 1...8000, using: &rng)
            let source = CGSize(width: w, height: h)
            for ratio in TimelineAspectRatio.allCases {
                let frame = ratio == .source ? source : ratio.renderSize(fittingSourceSize: source)
                guard frame.width > 0, frame.height > 0 else { continue }
                let place = AspectFit.placement(of: source, in: frame)
                let layout = TimelineRenderLayout(placements: [clip: place])
                let rx = CGFloat.random(in: 0...0.8, using: &rng)
                let ry = CGFloat.random(in: 0...0.8, using: &rng)
                let rw = CGFloat.random(in: 0.01...(1 - rx), using: &rng)
                let rh = CGFloat.random(in: 0.01...(1 - ry), using: &rng)
                let rect = CGRect(x: rx, y: ry, width: rw, height: rh)
                let composed = layout.remap(rect, clipID: clip)
                guard let back = layout.inverseRemap(composed, clipID: clip) else {
                    XCTFail("nil 往復: source=\(source) ratio=\(ratio) rect=\(rect) frame=\(frame) place=\(place)")
                    continue
                }
                XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-6,
                               "source=\(source) ratio=\(ratio) rect=\(rect)")
                XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-6,
                               "source=\(source) ratio=\(ratio) rect=\(rect)")
                XCTAssertEqual(back.width, rect.width, accuracy: 1e-6,
                               "source=\(source) ratio=\(ratio) rect=\(rect)")
                XCTAssertEqual(back.height, rect.height, accuracy: 1e-6,
                               "source=\(source) ratio=\(ratio) rect=\(rect)")
            }
        }
    }
}
