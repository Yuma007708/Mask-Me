import CoreGraphics
import XCTest
@testable import MosaicCore

final class ExportWatermarkTests: XCTestCase {
    // 実際の `TextRasterizer.rasterize` の出力に近い、適度な縦横比のラスタサイズ。
    private let raster = CGSize(width: 400, height: 120)

    private let landscapeHD = CGSize(width: 1920, height: 1080)
    private let portraitHD = CGSize(width: 1080, height: 1920)

    // MARK: - 右下に寄る

    func test_center_isInBottomRightQuadrant() {
        guard let center = ExportWatermark.center(rasterSize: raster, canvasSize: landscapeHD) else {
            return XCTFail("center should not be nil")
        }
        XCTAssertGreaterThan(center.x, 0.5)
        XCTAssertGreaterThan(center.y, 0.5)
    }

    func test_center_isInBottomRightQuadrant_portrait() {
        guard let center = ExportWatermark.center(rasterSize: raster, canvasSize: portraitHD) else {
            return XCTFail("center should not be nil")
        }
        XCTAssertGreaterThan(center.x, 0.5)
        XCTAssertGreaterThan(center.y, 0.5)
    }

    // MARK: - 余白が短辺比で一定（縦・横）

    func test_margin_isConsistentAcrossOrientations() {
        // 短辺はどちらも 1080 なので、短辺比の余白・文字サイズは向きに依らず一致するはず。
        // 検証: 表示サイズ・余白の px 値が landscape/portrait で同じになる
        // （= 正規化座標での右端からの距離 × 対応する軸の canvas 幅/高さ が一致する）。
        guard let landscapeCenter = ExportWatermark.center(rasterSize: raster, canvasSize: landscapeHD),
              let portraitCenter = ExportWatermark.center(rasterSize: raster, canvasSize: portraitHD) else {
            return XCTFail("center should not be nil")
        }
        let landscapeRightGapPx = (1 - landscapeCenter.x) * landscapeHD.width
        let portraitRightGapPx = (1 - portraitCenter.x) * portraitHD.width
        XCTAssertEqual(landscapeRightGapPx, portraitRightGapPx, accuracy: 0.001)

        let landscapeBottomGapPx = (1 - landscapeCenter.y) * landscapeHD.height
        let portraitBottomGapPx = (1 - portraitCenter.y) * portraitHD.height
        XCTAssertEqual(landscapeBottomGapPx, portraitBottomGapPx, accuracy: 0.001)
    }

    // MARK: - テキストが枠からはみ出さない

    func test_text_doesNotOverflowCanvas() {
        for canvasSize in [landscapeHD, portraitHD] {
            guard let center = ExportWatermark.center(rasterSize: raster, canvasSize: canvasSize) else {
                XCTFail("center should not be nil")
                continue
            }
            let shortSide = min(canvasSize.width, canvasSize.height)
            let scale = (shortSide * CGFloat(ExportWatermark.fontSizeRatio))
                / CGFloat(TextRasterConstants.referenceFontPoints)
            let halfWidthNormalized = (raster.width * scale / 2) / canvasSize.width
            let halfHeightNormalized = (raster.height * scale / 2) / canvasSize.height

            XCTAssertGreaterThanOrEqual(center.x - halfWidthNormalized, 0)
            XCTAssertLessThanOrEqual(center.x + halfWidthNormalized, 1)
            XCTAssertGreaterThanOrEqual(center.y - halfHeightNormalized, 0)
            XCTAssertLessThanOrEqual(center.y + halfHeightNormalized, 1)
        }
    }

    // MARK: - 縮退入力は nil（クラッシュしない）

    func test_degenerateCanvasSize_returnsNil() {
        XCTAssertNil(ExportWatermark.center(rasterSize: raster, canvasSize: .zero))
    }

    func test_degenerateRasterSize_returnsNil() {
        XCTAssertNil(ExportWatermark.center(rasterSize: .zero, canvasSize: landscapeHD))
    }

    func test_nonFiniteInput_returnsNil() {
        XCTAssertNil(ExportWatermark.center(
            rasterSize: raster,
            canvasSize: CGSize(width: CGFloat.nan, height: 1080)))
        XCTAssertNil(ExportWatermark.center(
            rasterSize: CGSize(width: CGFloat.infinity, height: 120),
            canvasSize: landscapeHD))
    }

    // MARK: - style(canvasSize:) は既存 TextStyle の範囲に収まる

    func test_style_fontSizeIsWithinValidRange() {
        let style = ExportWatermark.style(canvasSize: landscapeHD)
        XCTAssertGreaterThanOrEqual(style.fontSize, TextStyle.minimumFontSize)
        XCTAssertLessThanOrEqual(style.fontSize, TextStyle.maximumFontSize)
    }

    func test_style_degenerateCanvas_fallsBackToDefault() {
        let style = ExportWatermark.style(canvasSize: .zero)
        XCTAssertEqual(style.fontSize, TextStyle.defaultFontSize)
    }
}
