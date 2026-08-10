import XCTest
@testable import MosaicCore

/// `MaskBuffer.oriented(_:)` の固定（写真モード底上げ 第4段）。
final class MaskBufferOrientationTests: XCTestCase {
    func test_orientedMaskIsIdentityForIdentityOrientation() {
        let bytes: [UInt8] = [0, 255, 0, 255, 0, 0, 0, 255, 255, 0, 0, 0]
        let mask = MaskBuffer(bytes: bytes, width: 4, height: 3)
        let oriented = mask.oriented(.identity)
        XCTAssertEqual(oriented, mask)
    }

    /// `right90` を 2 回適用したものは `half` を 1 回適用したものと一致する
    /// （`ClipOrientation` の合成が成り立つことをマスクでも確認する）。
    func test_orientedMaskComposesLikeClipOrientation() {
        let width = 5
        let height = 3
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in bytes.indices where i % 3 == 0 { bytes[i] = 255 }
        let mask = MaskBuffer(bytes: bytes, width: width, height: height)

        let right90 = ClipOrientation(rotation: .right90)
        let half = ClipOrientation(rotation: .half)

        let twiceRotated = mask.oriented(right90).oriented(right90)
        let halfRotated = mask.oriented(half)

        XCTAssertEqual(twiceRotated.width, halfRotated.width)
        XCTAssertEqual(twiceRotated.height, halfRotated.height)
        XCTAssertEqual(twiceRotated.bytes, halfRotated.bytes)
    }

    /// 90/270 度で `width`/`height` が入れ替わり、画素数が保存されること。
    func test_orientedMaskSwapsDimensionsAndPreservesPixelCount() {
        let width = 6
        let height = 2
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes[0] = 255
        bytes[5] = 255
        bytes[11] = 255
        let mask = MaskBuffer(bytes: bytes, width: width, height: height)

        for rotation: ClipRotation in [.right90, .left90] {
            let oriented = mask.oriented(ClipOrientation(rotation: rotation))
            XCTAssertEqual(oriented.width, height)
            XCTAssertEqual(oriented.height, width)
            XCTAssertEqual(oriented.bytes.filter { $0 == 255 }.count, 3)
        }
    }
}
