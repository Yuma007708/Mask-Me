import CoreGraphics
import XCTest
@testable import MosaicCore

final class TransitionSpecTests: XCTestCase {
    private let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let center = CGPoint(x: 0.5, y: 0.5)

    // MARK: - 端点契約

    /// progress=0 では全種類で outgoing が完全表示（不透明・移動なし・全画面可視）であり、
    /// incoming の中央の点は不可視であること。
    func test_progressZeroShowsOutgoingAndHidesIncoming() {
        for kind in TransitionKind.allCases {
            let out = kind.parameters(progress: 0, side: .outgoing)
            XCTAssertEqual(out.opacity, 1.0, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(out.translation, .zero, "\(kind)")
            XCTAssertEqual(out.visibleRect, unitRect, "\(kind)")
            XCTAssertNotNil(kind.transformPoint(center, progress: 0, side: .outgoing), "\(kind)")
            XCTAssertNil(kind.transformPoint(center, progress: 0, side: .incoming), "\(kind)")
        }
    }

    /// progress=1 では全種類で incoming が完全表示であり、outgoing の中央の点は不可視であること。
    func test_progressOneShowsIncomingAndHidesOutgoing() {
        for kind in TransitionKind.allCases {
            let inc = kind.parameters(progress: 1, side: .incoming)
            XCTAssertEqual(inc.opacity, 1.0, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(inc.translation, .zero, "\(kind)")
            XCTAssertEqual(inc.visibleRect, unitRect, "\(kind)")
            XCTAssertNotNil(kind.transformPoint(center, progress: 1, side: .incoming), "\(kind)")
            XCTAssertNil(kind.transformPoint(center, progress: 1, side: .outgoing), "\(kind)")
        }
    }

    /// progress=1 の outgoing 側パラメータの直接値検証（transformPoint 経由でない端点契約）。
    /// フェード系は opacity 0、スライド系は画面 1 枚分の translation、ワイプ系は幅 0 の visibleRect。
    func test_progressOneOutgoingParameterValues() {
        XCTAssertEqual(TransitionKind.fadeToBlack.parameters(progress: 1, side: .outgoing).opacity,
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: 1, side: .outgoing).opacity,
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.slideLeft.parameters(progress: 1, side: .outgoing).translation,
                       CGVector(dx: -1, dy: 0))
        XCTAssertEqual(TransitionKind.slideRight.parameters(progress: 1, side: .outgoing).translation,
                       CGVector(dx: 1, dy: 0))
        XCTAssertEqual(TransitionKind.wipeLeft.parameters(progress: 1, side: .outgoing).visibleRect,
                       CGRect(x: 0, y: 0, width: 0, height: 1))
        XCTAssertEqual(TransitionKind.wipeRight.parameters(progress: 1, side: .outgoing).visibleRect,
                       CGRect(x: 1, y: 0, width: 0, height: 1))
    }

    // MARK: - 中間値（progress=0.5 のハードコード期待値）

    /// フェード系は progress=0.5 で opacity だけが変わること。
    /// fadeToBlack は両側 0（黒画面）、crossfade は両側 0.5。
    func test_fadeMidpointValues() {
        XCTAssertEqual(TransitionKind.fadeToBlack.parameters(progress: 0.5, side: .outgoing).opacity,
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.fadeToBlack.parameters(progress: 0.5, side: .incoming).opacity,
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: 0.5, side: .outgoing).opacity,
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: 0.5, side: .incoming).opacity,
                       0.5, accuracy: 1e-9)
        // fadeToBlack の区分線形: 0.25 で outgoing 0.5、incoming はまだ 0。
        XCTAssertEqual(TransitionKind.fadeToBlack.parameters(progress: 0.25, side: .outgoing).opacity,
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.fadeToBlack.parameters(progress: 0.25, side: .incoming).opacity,
                       0.0, accuracy: 1e-9)
    }

    /// スライド系は progress=0.5 で translation だけが変わること（可視領域・不透明度は全画面/1）。
    func test_slideMidpointValues() {
        let outLeft = TransitionKind.slideLeft.parameters(progress: 0.5, side: .outgoing)
        XCTAssertEqual(outLeft.translation, CGVector(dx: -0.5, dy: 0))
        XCTAssertEqual(outLeft.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(outLeft.visibleRect, unitRect)
        XCTAssertEqual(TransitionKind.slideLeft.parameters(progress: 0.5, side: .incoming).translation,
                       CGVector(dx: 0.5, dy: 0))
        XCTAssertEqual(TransitionKind.slideRight.parameters(progress: 0.5, side: .outgoing).translation,
                       CGVector(dx: 0.5, dy: 0))
        XCTAssertEqual(TransitionKind.slideRight.parameters(progress: 0.5, side: .incoming).translation,
                       CGVector(dx: -0.5, dy: 0))
    }

    /// ワイプ系は progress=0.5 で visibleRect だけが変わること（左右で対称）。
    func test_wipeMidpointValues() {
        let outLeft = TransitionKind.wipeLeft.parameters(progress: 0.5, side: .outgoing)
        XCTAssertEqual(outLeft.visibleRect, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(outLeft.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(outLeft.translation, .zero)
        XCTAssertEqual(TransitionKind.wipeLeft.parameters(progress: 0.5, side: .incoming).visibleRect,
                       CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(TransitionKind.wipeRight.parameters(progress: 0.5, side: .outgoing).visibleRect,
                       CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(TransitionKind.wipeRight.parameters(progress: 0.5, side: .incoming).visibleRect,
                       CGRect(x: 0, y: 0, width: 0.5, height: 1))
    }

    // MARK: - transformPoint の可視判定

    /// スライドでは移動後に画面外へ出た点が nil になり、画面内の点は移動先の座標を返すこと。
    func test_transformPointSlideVisibility() {
        // outgoing は左へ 0.5 移動: x=0.3 は画面外、x=0.6 は (0.1, 0.5) へ。
        XCTAssertNil(TransitionKind.slideLeft.transformPoint(CGPoint(x: 0.3, y: 0.5),
                                                             progress: 0.5, side: .outgoing))
        let moved = TransitionKind.slideLeft.transformPoint(CGPoint(x: 0.6, y: 0.5),
                                                            progress: 0.5, side: .outgoing)
        XCTAssertEqual(moved?.x ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(moved?.y ?? -1, 0.5, accuracy: 1e-9)
        // incoming は右から 0.5 の位置: x=0.3 は (0.8, 0.5) へ。
        let incoming = TransitionKind.slideLeft.transformPoint(CGPoint(x: 0.3, y: 0.5),
                                                               progress: 0.5, side: .incoming)
        XCTAssertEqual(incoming?.x ?? -1, 0.8, accuracy: 1e-9)
    }

    /// ワイプでは移動なしで、可視領域の内外だけで判定されること。境界は半開区間で incoming 側に属する。
    func test_transformPointWipeVisibility() {
        // wipeLeft progress=0.5: outgoing は [0, 0.5)、incoming は [0.5, 1) が可視。
        XCTAssertEqual(TransitionKind.wipeLeft.transformPoint(CGPoint(x: 0.4, y: 0.5),
                                                              progress: 0.5, side: .outgoing),
                       CGPoint(x: 0.4, y: 0.5))
        XCTAssertNil(TransitionKind.wipeLeft.transformPoint(CGPoint(x: 0.6, y: 0.5),
                                                            progress: 0.5, side: .outgoing))
        // 境界 x=0.5 ちょうど: outgoing は不可視、incoming は可視（半開区間）。
        XCTAssertNil(TransitionKind.wipeLeft.transformPoint(center, progress: 0.5, side: .outgoing))
        XCTAssertEqual(TransitionKind.wipeLeft.transformPoint(center, progress: 0.5, side: .incoming), center)
    }

    /// フェードでは不透明度 0 の側だけが nil になること（半透明は可視 = モザイク対象）。
    func test_transformPointFadeVisibility() {
        XCTAssertEqual(TransitionKind.crossfade.transformPoint(center, progress: 0.5, side: .outgoing), center)
        XCTAssertEqual(TransitionKind.crossfade.transformPoint(center, progress: 0.5, side: .incoming), center)
        XCTAssertNil(TransitionKind.fadeToBlack.transformPoint(center, progress: 0.5, side: .outgoing))
        XCTAssertNil(TransitionKind.fadeToBlack.transformPoint(center, progress: 0.5, side: .incoming))
    }

    // MARK: - progress のクランプ

    /// 範囲外の progress は [0,1] にクランプされ、NaN は 0 扱いになること。
    func test_progressIsClamped() {
        XCTAssertEqual(TransitionKind.clampedProgress(-0.5), 0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.clampedProgress(1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.clampedProgress(.nan), 0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: -1, side: .outgoing).opacity,
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: 2, side: .outgoing).opacity,
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(TransitionKind.crossfade.parameters(progress: .nan, side: .incoming).opacity,
                       0.0, accuracy: 1e-9)
    }

    // MARK: - Codable

    /// TransitionSpec のエンコード→デコード round-trip が全種類で一致すること。
    func test_codableRoundTrip() throws {
        for kind in TransitionKind.allCases {
            let spec = TransitionSpec(kind: kind, duration: 0.75)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(TransitionSpec.self, from: data)
            XCTAssertEqual(decoded, spec, "\(kind)")
        }
    }
}
