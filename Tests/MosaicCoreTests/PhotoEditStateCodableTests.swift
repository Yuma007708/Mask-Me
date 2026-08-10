import XCTest
@testable import MosaicCore

/// `PhotoEditState` の保存形式（Codable）が、動画専用の時間軸フィールドを
/// 一切持ち込んでいないことを固定する。
///
/// `PhotoEditState` の型 doc に書いたとおり、`TimelineState` を写真へ流用しないのは
/// `compositionStart` / `duration` / `animation` / `sourceStart` のような
/// 「写真には定義されない値」が下書きの JSON に紛れ込むのを避けるため。
/// このテストはその決定が実際に守られているかを、エンコード結果そのもので確認する。
final class PhotoEditStateCodableTests: XCTestCase {
    func testEncodedStateHasNoTimeFields() throws {
        let state = PhotoEditState(colorGrade: ColorGrade(brightness: 0.2, contrast: 1.1,
                                                          saturation: 0.8, warmth: -0.3))
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let forbiddenKeys = ["compositionStart", "duration", "animation", "sourceStart"]
        for key in forbiddenKeys {
            XCTAssertNil(json[key], "PhotoEditState の JSON に動画専用フィールド `\(key)` が含まれている")
        }
        // 併せて、colorGrade のキー自体はネストして存在すること（空振り防止）。
        XCTAssertNotNil(json["colorGrade"], "PhotoEditState の JSON に colorGrade が無い")
    }

    func testIdentityRoundTrips() throws {
        let data = try JSONEncoder().encode(PhotoEditState.identity)
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored, .identity)
        XCTAssertTrue(restored.isIdentity)
    }

    func testNonIdentityRoundTrips() throws {
        let state = PhotoEditState(colorGrade: ColorGrade(brightness: -0.4, contrast: 1.5,
                                                           saturation: 0.3, warmth: 0.6))
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored, state)
        XCTAssertFalse(restored.isIdentity)
    }
}
