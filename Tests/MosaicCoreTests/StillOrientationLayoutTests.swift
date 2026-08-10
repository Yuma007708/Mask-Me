import CoreGraphics
import XCTest
@testable import MosaicCore

/// 静止画（写真モード）の向き写像（`TimelineRenderLayout.remapStill` 系）を固定する。
///
/// 写真モード底上げ 第4段。`remapStill(_ sets:)` / `inverseRemapStill(_ sets:)` /
/// `remapStill(_ mask:)` は「クリップ版（`remap(_ sets:clipID:)` 等）の
/// `placement(for:)`/`orientation(for:)` を `stillPlacement`/`stillOrientation` へ
/// 置き換えただけ」という設計どおりであることを、既存のクリップ版と同じ手口で確認する。
final class StillOrientationLayoutTests: XCTestCase {
    private let allOrientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
        [ClipOrientation(rotation: rotation, isMirrored: false),
         ClipOrientation(rotation: rotation, isMirrored: true)]
    }

    private func layout(orientation: ClipOrientation) -> TimelineRenderLayout {
        TimelineRenderLayout(placements: [:], stillPlacement: TimelineRenderLayout.unitRect,
                             stillOrientation: orientation)
    }

    private func makeSet(_ points: [(Float, Float)]) -> FaceLandmarkSet {
        FaceLandmarkSet(points: points.map { FaceLandmark(x: $0.0, y: $0.1) }, confidence: 1)
    }

    // MARK: - 片道の絶対値（`FaceLandmarkSet.oriented(_:)` と一致すること）

    func test_remapStillLandmarks_appliesStillOrientation() {
        let set = makeSet([(0.1, 0.2), (0.8, 0.05), (0.5, 0.9)])
        for orientation in allOrientations {
            let layout = layout(orientation: orientation)
            let got = layout.remapStill([set])
            let expected = set.oriented(orientation)
            XCTAssertEqual(got.count, 1)
            for (g, e) in zip(got[0].points, expected.points) {
                XCTAssertEqual(g.x, e.x, accuracy: 1e-6, "orientation=\(orientation)")
                XCTAssertEqual(g.y, e.y, accuracy: 1e-6, "orientation=\(orientation)")
            }
        }
    }

    // MARK: - 往復（片道テストと必ずセット。単独では判定しない）

    func test_remapStillLandmarks_roundTripsThroughInverse() {
        let set = makeSet([(0.12, 0.34), (0.77, 0.21), (0.5, 0.5)])
        for orientation in allOrientations {
            let layout = layout(orientation: orientation)
            let back = layout.inverseRemapStill(layout.remapStill([set]))
            XCTAssertEqual(back.count, 1)
            for (b, o) in zip(back[0].points, set.points) {
                // `FaceLandmark` は `Float` 格納なので、往復誤差の下限は Float の桁精度
                // （約 1.2e-7 の相対誤差）で決まる。1e-12 は `Double` 演算のみの
                // `TimelineRenderLayoutTests`（矩形）向けの精度で、ここには適用できない。
                XCTAssertEqual(Double(b.x), Double(o.x), accuracy: 1e-6, "orientation=\(orientation)")
                XCTAssertEqual(Double(b.y), Double(o.y), accuracy: 1e-6, "orientation=\(orientation)")
            }
        }
    }

    // MARK: - マスク（1 セルだけ立てた `MaskBuffer`）

    /// 1 セルだけ立てた `MaskBuffer` を回し、立っているセルの位置が `remapStill(_ rect:)`
    /// の予測（そのセルに対応する正規化矩形を写した先）と一致すること。
    func test_remapStillMask_cellLandsWhereRemapStillRectSays() {
        let width = 4
        let height = 6
        let setX = 1
        let setY = 4
        for orientation in allOrientations {
            let layout = layout(orientation: orientation)
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes[setY * width + setX] = 255
            let mask = MaskBuffer(bytes: bytes, width: width, height: height)
            let oriented = layout.remapStill(mask)

            // 立っているセル（1個だけのはず）の位置。
            let litIndices = oriented.bytes.indices.filter { oriented.bytes[$0] == 255 }
            XCTAssertEqual(litIndices.count, 1, "orientation=\(orientation)")
            guard let lit = litIndices.first else { continue }
            let gotX = lit % oriented.width
            let gotY = lit / oriented.width

            // 元セルに対応する正規化矩形を remapStill(_ rect:) で写し、その中心が
            // 出力側のどのセルに落ちるかで予測する。
            let sourceRect = CGRect(x: CGFloat(setX) / CGFloat(width),
                                    y: CGFloat(setY) / CGFloat(height),
                                    width: 1.0 / CGFloat(width), height: 1.0 / CGFloat(height))
            let mappedRect = layout.remapStill(sourceRect)
            let centerX = mappedRect.midX
            let centerY = mappedRect.midY
            let expectedX = min(max(Int(centerX * CGFloat(oriented.width)), 0), oriented.width - 1)
            let expectedY = min(max(Int(centerY * CGFloat(oriented.height)), 0), oriented.height - 1)
            XCTAssertEqual(gotX, expectedX, "orientation=\(orientation)")
            XCTAssertEqual(gotY, expectedY, "orientation=\(orientation)")
        }
    }

    func test_remapStillMask_preservesSetPixelCountAndSwapsDimensions() {
        let width = 5
        let height = 3
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes[0] = 255
        bytes[7] = 255
        bytes[14] = 255
        let mask = MaskBuffer(bytes: bytes, width: width, height: height)
        for orientation in allOrientations {
            let layout = layout(orientation: orientation)
            let oriented = layout.remapStill(mask)
            if orientation.swapsDimensions {
                XCTAssertEqual(oriented.width, height, "orientation=\(orientation)")
                XCTAssertEqual(oriented.height, width, "orientation=\(orientation)")
            } else {
                XCTAssertEqual(oriented.width, width, "orientation=\(orientation)")
                XCTAssertEqual(oriented.height, height, "orientation=\(orientation)")
            }
            let setCount = oriented.bytes.filter { $0 == 255 }.count
            XCTAssertEqual(setCount, 3, "orientation=\(orientation)")
        }
    }

    // MARK: - 空振り対策: 動画側（clipID 引き）が 1 ビットも変わらないこと

    /// **動画側が 1 ビットも変わらないことの直接検査。** 冒頭で `stillOrientation` が
    /// 無変換でないことを確認し（空振り緑を塞ぐ）、そのうえで clipID 引きの
    /// `remap(_ sets:clipID:)` / `remap(_ rect:clipID:)` が `stillOrientation` の影響を
    /// 一切受けないことを固定する。
    func test_stillOrientationDoesNotLeakIntoClipKeyedLandmarkRemap() {
        let clipID = UUID()
        let orientation = ClipOrientation(rotation: .right90, isMirrored: true)
        let layout = TimelineRenderLayout(placements: [:], orientations: [:],
                                          stillPlacement: TimelineRenderLayout.unitRect,
                                          stillOrientation: orientation)
        XCTAssertFalse(layout.stillOrientation.isIdentity, "テストの前提: 静止画向きが無変換になっている")

        let set = makeSet([(0.1, 0.2), (0.8, 0.05)])
        // 未登録クリップは常に無変換（`orientation(for:)` の doc 参照）。
        XCTAssertEqual(layout.remap([set], clipID: clipID), [set])
        XCTAssertEqual(layout.remap([set], clipID: nil), [set])

        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        XCTAssertEqual(layout.remap(rect, clipID: clipID), rect)
        XCTAssertEqual(layout.remap(rect, clipID: nil), rect)
    }
}
