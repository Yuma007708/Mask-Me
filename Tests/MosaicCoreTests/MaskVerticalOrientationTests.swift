import CoreGraphics
import XCTest
@testable import MosaicCore

/// マスクのバイト行が「画像の上」からなのか「下」からなのかを、GPU を通さず
/// `FaceMaskBuilder.renderMask` の戻り値そのもので確定させる調査用テスト。
///
/// 規約（`MetalTextureUtilities` / `MosaicShader.metal` 側）:
/// - `texture.replace` はバイト行 0 をテクスチャ行 0（gid.y == 0）に置く
/// - `mosaicKernel` は `uv = (gid + 0.5)/size` でマスクを引く（= 行が一致）
/// - 入力テクスチャの行 0 は画像の上（親が実測済み）
/// したがって **マスクのバイト行 0 も「画像の上」でなければならない**。
final class MaskVerticalOrientationTests: XCTestCase {

    /// 立っている行の範囲を返す。
    private func filledRowRange(_ bytes: [UInt8], bytesPerRow: Int, height: Int) -> ClosedRange<Int>? {
        var minRow = Int.max
        var maxRow = Int.min
        for row in 0..<height {
            let slice = bytes[(row * bytesPerRow)..<((row + 1) * bytesPerRow)]
            if slice.contains(where: { $0 > 0 }) {
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        return minRow <= maxRow ? minRow...maxRow : nil
    }

    private func filledColumnRange(_ bytes: [UInt8], bytesPerRow: Int, height: Int) -> ClosedRange<Int>? {
        var minCol = Int.max
        var maxCol = Int.min
        for row in 0..<height {
            for col in 0..<bytesPerRow where bytes[row * bytesPerRow + col] > 0 {
                minCol = min(minCol, col)
                maxCol = max(maxCol, col)
            }
        }
        return minCol <= maxCol ? minCol...maxCol : nil
    }

    /// 追加パス（手動矩形）: 正規化 y=0.05..0.25 → バイト行 20..99 に立つべき。
    func test_additionalRectPath_landsOnTopRows() throws {
        let builder = FaceMaskBuilder(dilation: 0)
        let size = CGSize(width: 400, height: 400)
        let path = FaceMaskBuilder.rectPath(
            from: CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2), angle: 0, in: size
        )
        let rendered = try XCTUnwrap(builder.renderMask(
            for: [] as [FaceLandmarkSet],
            additionalPaths: [.init(path: path, value: 1.0)],
            width: 400, height: 400
        ))
        let rows = try XCTUnwrap(filledRowRange(rendered.bytes, bytesPerRow: rendered.bytesPerRow, height: 400))
        let cols = try XCTUnwrap(filledColumnRange(rendered.bytes, bytesPerRow: rendered.bytesPerRow, height: 400))
        print("MEASURED additionalRect rows=\(rows) cols=\(cols)")
        XCTAssertEqual(cols.lowerBound, 20, accuracy: 2)
        XCTAssertEqual(cols.upperBound, 99, accuracy: 2)
        // 実測: rows=300...379。CGContext の原点が左下なので上下が入れ替わる。
        // 修正済み（`FaceMaskBuilder.flipToTopDown`）。ここが落ちたら反転が再発している。
        do {
            XCTAssertEqual(rows.lowerBound, 20, accuracy: 2, "行 20 付近に立つべき（画像の上）")
            XCTAssertEqual(rows.upperBound, 99, accuracy: 2)
        }
    }

    /// 部分メッシュ顔（コンタマスク経路）: 上寄りに置いた landmark は上の行に出るべき。
    func test_partialFaceLandmarks_landOnTopRows() throws {
        let builder = FaceMaskBuilder(dilation: 0)
        // faceOval の index に上寄り（y=0.1 前後）の点を置いた部分メッシュ。
        var points = [FaceLandmark](repeating: FaceLandmark(x: 0, y: 0), count: 500)
        let ovalIndices = FaceRegion.faceOval.indices
        let count = ovalIndices.count
        for (i, index) in ovalIndices.enumerated() {
            let theta = Double(i) / Double(count) * 2 * Double.pi
            points[index] = FaceLandmark(
                x: Float(0.5 + 0.1 * cos(theta)),
                y: Float(0.15 + 0.05 * sin(theta))
            )
        }
        // 部分メッシュ扱いにするため、faceOval 以外は 0 のまま（値は使われない）。
        let face = FaceLandmarkSet(points: points, confidence: 0.9)
        let rendered = try XCTUnwrap(builder.renderMask(
            for: face, width: 400, height: 400
        ))
        let rows = try XCTUnwrap(filledRowRange(rendered.bytes, bytesPerRow: rendered.bytesPerRow, height: 400))
        print("MEASURED partialFace rows=\(rows)")
        // y=0.10..0.20 → 行 40..80 に出るべき
        // 実測: rows=320...359（期待 40...79）。
        // 修正済み（`FaceMaskBuilder.flipToTopDown`）。ここが落ちたら反転が再発している。
        do {
            XCTAssertLessThan(rows.lowerBound, 200, "上寄り landmark は上半分（行<200）に出るべき")
        }
    }
}

private func XCTAssertEqual(_ lhs: Int, _ rhs: Int, accuracy: Int, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(lhs - rhs) <= accuracy, "\(message) got \(lhs), expected \(rhs)±\(accuracy)",
                  file: file, line: line)
}
