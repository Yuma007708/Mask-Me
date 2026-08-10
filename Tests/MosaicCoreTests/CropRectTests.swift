import CoreGraphics
import XCTest
@testable import MosaicCore

/// `CropRect`（出力枠に対する正規化部分矩形）の契約。
///
/// **この機能で壊れると事故になるのは「クロップ後に映像とモザイクの縮尺が食い違う」
/// ことである**（プライバシーアプリなので、ずれた瞬間に顔が素通しになる）。
final class CropRectTests: XCTestCase {
    // MARK: - test_全面クロップは配置矩形をビット同一で返す

    func test_全面クロップは配置矩形をビット同一で返す() {
        let placements: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1),
            CGRect(x: -0.3, y: 1.2, width: 2.0, height: 0.4)
        ]
        for placement in placements {
            let expanded = CropRect.full.expand(placement)
            XCTAssertEqual(expanded.minX, placement.minX, "ビット同一のはず: \(placement)")
            XCTAssertEqual(expanded.minY, placement.minY, "ビット同一のはず: \(placement)")
            XCTAssertEqual(expanded.width, placement.width, "ビット同一のはず: \(placement)")
            XCTAssertEqual(expanded.height, placement.height, "ビット同一のはず: \(placement)")
        }
    }

    // MARK: - test_クロップ後も素材のピクセル寸法が変わらない

    /// **これが等方性＝映像とモザイクの一致の根拠。**
    ///
    /// 丸め前の生の `rect` から `expand` を計算する実装だと、`outputSize`（偶数へ
    /// スナップ済み）と縮尺が食い違い、`placement` がクロップ範囲より大きいとき
    /// （＝クロップより広い素材を写しているとき）に誤差が拡大して 1px を超える。
    /// 正しい手順は `CropRect.expandSnapped` に実体化してあり、**このテストも
    /// `RenderPlacement.make` もその同じ関数を通る**（手順をテスト側へ写さない）。
    private struct PixelParityCase {
        let frame: CGSize
        let crop: CGRect
        let placement: CGRect
    }

    func test_クロップ後も素材のピクセル寸法が変わらない() {
        let cases: [PixelParityCase] = [
            PixelParityCase(frame: CGSize(width: 1920, height: 1080),
                            crop: CGRect(x: 0.1, y: 0.15, width: 0.37, height: 0.29),
                            placement: CGRect(x: 0, y: 0, width: 1, height: 1)),
            PixelParityCase(frame: CGSize(width: 1080, height: 1920),
                            crop: CGRect(x: 0.05, y: 0.4, width: 0.6, height: 0.2),
                            placement: CGRect(x: -0.2, y: 0, width: 1.4, height: 1)),
            PixelParityCase(frame: CGSize(width: 641, height: 481),
                            crop: CGRect(x: 0.33, y: 0.0, width: 0.34, height: 1.0),
                            placement: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)),
            PixelParityCase(frame: CGSize(width: 100, height: 100),
                            crop: CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88),
                            placement: CGRect(x: 0, y: 0, width: 1, height: 1))
        ]
        for testCase in cases {
            let crop = CropRect(rect: testCase.crop)
            let outputSize = crop.outputSize(fittingFrame: testCase.frame)
            // **本番の経路（`RenderPlacement.make`）を通すこと。** テストの中で
            // `effectiveCrop` のような「正しい手順」を書き写して検査すると、本番側が
            // 丸め前の生の rect を分母に使う実装へ退行しても緑のまま素通りする
            // （親の変異検証で実際に素通りした）。ここで `placement` を直接渡したいので、
            // `RenderPlacement.make` もこの同じ関数を通る。
            let expanded = crop.expandSnapped(testCase.placement, inFrame: testCase.frame)

            let expectedPixelWidth = testCase.placement.width * testCase.frame.width
            let gotPixelWidth = expanded.width * outputSize.width
            XCTAssertEqual(gotPixelWidth, expectedPixelWidth, accuracy: 1.0,
                           "幅のピクセル寸法が 1px を超えてずれた: \(testCase)")

            let expectedPixelHeight = testCase.placement.height * testCase.frame.height
            let gotPixelHeight = expanded.height * outputSize.height
            XCTAssertEqual(gotPixelHeight, expectedPixelHeight, accuracy: 1.0,
                           "高さのピクセル寸法が 1px を超えてずれた: \(testCase)")
        }
    }

    // MARK: - test_出力サイズは常に偶数かつ2以上

    func test_出力サイズは常に偶数かつ2以上() {
        let frames: [CGSize] = [
            CGSize(width: 1920, height: 1080), CGSize(width: 641, height: 481),
            CGSize(width: 3, height: 3), CGSize(width: 0, height: 0),
            CGSize(width: -100, height: 100), CGSize(width: CGFloat.nan, height: 100),
            CGSize(width: CGFloat.infinity, height: 100)
        ]
        let crops: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
            CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001),
            CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        ]
        for frame in frames {
            for cropRect in crops {
                let size = CropRect(rect: cropRect).outputSize(fittingFrame: frame)
                XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0,
                               "幅が奇数: frame=\(frame) crop=\(cropRect) → \(size)")
                XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0,
                               "高さが奇数: frame=\(frame) crop=\(cropRect) → \(size)")
                XCTAssertGreaterThanOrEqual(size.width, 2)
                XCTAssertGreaterThanOrEqual(size.height, 2)
            }
        }
    }

    // MARK: - test_壊れたJSONでもデコードが失敗せず全面へ倒れる

    func test_壊れたJSONでもデコードが失敗せず全面へ倒れる() throws {
        let brokenPayloads = [
            "{\"rect\":\"x\"}",
            "{}",
            "{\"rect\":{\"origin\":{\"x\":0,\"y\":0},\"size\":{\"width\":-1,\"height\":1}}}",
            "{\"rect\":{\"origin\":{\"x\":2,\"y\":2},\"size\":{\"width\":1,\"height\":1}}}",
            "{\"rect\":{\"origin\":{\"x\":0},\"size\":{\"width\":1,\"height\":1}}}"
        ]
        for payload in brokenPayloads {
            let data = try XCTUnwrap(payload.data(using: .utf8))
            let decoded = try JSONDecoder().decode(CropRect.self, from: data)
            XCTAssertTrue(decoded.isFull, "壊れた値は全面へ倒れるはず: \(payload) → \(decoded)")
        }
    }

    /// 正常な JSON は往復で保たれる（壊れていないものまで `.full` へ倒さない）。
    func test_正常なJSONは往復で保たれる() throws {
        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let data = try JSONEncoder().encode(crop)
        let restored = try JSONDecoder().decode(CropRect.self, from: data)
        XCTAssertEqual(restored, crop)
    }

    // MARK: - test_最小サイズより小さいクロップはクランプされる

    func test_最小サイズより小さいクロップはクランプされる() {
        let tiny = CropRect(rect: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        XCTAssertGreaterThanOrEqual(tiny.rect.width, CropRect.minimumSide)
        XCTAssertGreaterThanOrEqual(tiny.rect.height, CropRect.minimumSide)
        XCTAssertLessThanOrEqual(tiny.rect.maxX, 1.0 + 1e-12)
        XCTAssertLessThanOrEqual(tiny.rect.maxY, 1.0 + 1e-12)

        // 端に寄っていても [0,1] からはみ出さない。
        let corner = CropRect(rect: CGRect(x: 0.99, y: 0.99, width: 0.001, height: 0.001))
        XCTAssertGreaterThanOrEqual(corner.rect.width, CropRect.minimumSide)
        XCTAssertLessThanOrEqual(corner.rect.maxX, 1.0 + 1e-12)
        XCTAssertLessThanOrEqual(corner.rect.maxY, 1.0 + 1e-12)
    }

    // MARK: - isFull

    func test_isFullは全面矩形だけがtrue() {
        XCTAssertTrue(CropRect.full.isFull)
        XCTAssertTrue(CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).isFull)
        XCTAssertFalse(CropRect(rect: CGRect(x: 0.1, y: 0, width: 0.9, height: 1)).isFull)
    }
}
