import CoreGraphics
import Foundation
import XCTest
@testable import MosaicCore

final class TimelineOutputSummaryTests: XCTestCase {
    /// 出力枠より大きいクリップだけが index として返ること。
    func test_returnsIndicesOfLargerClips() {
        let render = CGSize(width: 1920, height: 1080)
        let sizes = [CGSize(width: 1920, height: 1080),   // 等倍
                     CGSize(width: 3840, height: 2160),   // 4K → 縮小
                     CGSize(width: 1280, height: 720),    // 小さい → 拡大側
                     CGSize(width: 1080, height: 1920)]   // 縦 → 高さで縮小
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: render, displaySizes: sizes),
                       [1, 3])
    }

    /// 等倍ちょうどは含まないこと（境界）。
    func test_exactFitIsNotDownscaled() {
        let render = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: render,
                                                               displaySizes: [render]),
                       [])
    }

    /// 判定は AspectFit.placement（scale = min(幅比, 高さ比)）と整合すること。
    /// 縮小されるクリップは placement が単位矩形にならない（レターボックスが出る）。
    func test_agreesWithAspectFitPlacement() {
        let render = CGSize(width: 1920, height: 1080)
        let sizes = [CGSize(width: 3840, height: 2160),
                     CGSize(width: 1080, height: 1920),
                     CGSize(width: 1920, height: 1081),
                     CGSize(width: 1920, height: 1080)]
        let indices = Set(TimelineOutputSummary.downscaledIndices(renderSize: render, displaySizes: sizes))
        for (index, size) in sizes.enumerated() {
            let scale = min(render.width / size.width, render.height / size.height)
            XCTAssertEqual(indices.contains(index), scale < 1, "index \(index)")
        }
        // 縦横比が違うクリップはレターボックスされる（placement が単位矩形でない）。
        XCTAssertNotEqual(AspectFit.placement(of: sizes[1], in: render), TimelineRenderLayout.unitRect)
    }

    /// 1 ピクセルだけ大きいものも縮小として拾うこと（誤差ではなく実際の縮小）。
    func test_detectsOnePixelOverflow() {
        let render = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(
            renderSize: render, displaySizes: [CGSize(width: 1921, height: 1080)]), [0])
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(
            renderSize: render, displaySizes: [CGSize(width: 1920, height: 1081)]), [0])
    }

    /// 非有限・非正のクリップサイズは判断材料が無いので無視し、他の index はずれないこと。
    func test_ignoresInvalidClipSizes() {
        let render = CGSize(width: 1920, height: 1080)
        let sizes: [CGSize] = [CGSize(width: CGFloat.nan, height: 1080),
                               CGSize(width: 3840, height: CGFloat.infinity),
                               CGSize(width: 0, height: 1080),
                               CGSize(width: -3840, height: -2160),
                               CGSize(width: 3840, height: 2160)]
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: render, displaySizes: sizes),
                       [4])
    }

    /// renderSize が不正なら空配列（AspectFit と同じ倒し方）。
    func test_invalidRenderSizeReturnsEmpty() {
        let sizes = [CGSize(width: 3840, height: 2160)]
        let invalid: [CGSize] = [CGSize(width: CGFloat.nan, height: 1080),
                                 CGSize(width: 1920, height: CGFloat.infinity),
                                 CGSize(width: 0, height: 0),
                                 CGSize(width: -1920, height: -1080)]
        for render in invalid {
            XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: render,
                                                                   displaySizes: sizes), [])
        }
    }

    /// 空入力は空配列。
    func test_emptyInput() {
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(
            renderSize: CGSize(width: 1920, height: 1080), displaySizes: []), [])
    }

    /// 先頭クリップ基準で renderSize が決まる前提の並べ替えシナリオ:
    /// 先頭が 4K のときは他が縮小されず、先頭が 1080p に変わると 4K 側が縮小される。
    func test_reorderChangesDownscaledSet() {
        let uhd = CGSize(width: 3840, height: 2160)
        let hd = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: uhd, displaySizes: [uhd, hd]), [])
        XCTAssertEqual(TimelineOutputSummary.downscaledIndices(renderSize: hd, displaySizes: [hd, uhd]), [1])
    }
}
