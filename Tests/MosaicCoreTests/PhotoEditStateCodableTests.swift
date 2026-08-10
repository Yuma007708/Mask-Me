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

    /// `texts`（写真モード底上げ 第2段）が保存 → 復元で往復すること。
    func testPhotoEditStateRoundTripsTexts() throws {
        let state = PhotoEditState.identity
            .addingText("こんにちは", center: NormalizedPoint(x: 0.2, y: 0.8))
            .addingSticker("🎉")
        XCTAssertEqual(state.texts.count, 2, "テスト前提: 2件追加できている")

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored, state)
        XCTAssertFalse(restored.isIdentity)
        XCTAssertEqual(restored.texts.count, 2)
    }

    /// `texts` キーを持たない旧下書きの JSON は、空配列として復元されること
    /// （`PhotoEditState.init(from:)` の `decodeIfPresent` 参照）。
    func testDecodingLegacyStateWithoutTextsYieldsEmptyTexts() throws {
        let legacyJSON = """
        {"colorGrade":{"brightness":0.1,"contrast":1.0,"saturation":1.0,"warmth":0.0}}
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored.texts, [])
        XCTAssertEqual(restored.colorGrade.brightness, 0.1)
    }

    /// `orientation`（写真モード底上げ 第4段）が保存 → 復元で往復すること。
    func test_photoEditState_roundTripsOrientation() throws {
        var state = PhotoEditState.identity
        state.orientation = ClipOrientation(rotation: .right90, isMirrored: true)
        XCTAssertFalse(state.isIdentity, "テスト前提: 向きを変えたら isIdentity が false になる")

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.orientation, state.orientation)
    }

    /// `orientation` キーを持たない旧下書きの JSON は、無変換として復元されること
    /// （`PhotoEditState.init(from:)` の `decodeIfPresent` 参照）。
    func test_decodingLegacyStateWithoutOrientation_yieldsIdentity() throws {
        let legacyJSON = """
        {"colorGrade":{"brightness":0.1,"contrast":1.0,"saturation":1.0,"warmth":0.0},"texts":[]}
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        XCTAssertEqual(restored.orientation, .identity)
        XCTAssertEqual(restored.colorGrade.brightness, 0.1)
    }
}
