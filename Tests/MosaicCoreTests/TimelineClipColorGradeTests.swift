import XCTest
@testable import MosaicCore

/// `TimelineClip.colorGrade`（E4）: 後方互換デコード・引き継ぎ後の値・往復を固定する。
final class TimelineClipColorGradeTests: XCTestCase {
    /// 新規クリップは既定で無補正（`.identity`）を持つこと。
    func test_newClip_defaultsToIdentityColorGrade() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)
        XCTAssertEqual(clip.colorGrade, .identity)
    }

    /// `colorGrade` キーを持たない v6 相当の実 JSON が `.identity`（無補正）として
    /// 復元されること（`orientation` と同じ後方互換規約。`rate` 導入時からの慣例）。
    func test_decodingV6JSONWithoutColorGradeKey_fallsBackToIdentity() throws {
        let id = UUID()
        let sourceID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "sourceID": "\(sourceID.uuidString)",
          "sourceStart": 0,
          "sourceEnd": 3,
          "originalAudioVolume": 1,
          "rate": 1
        }
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.sourceID, sourceID)
        XCTAssertEqual(decoded.colorGrade, .identity, "colorGrade キーが無い旧下書きが identity で復元されない")
    }

    /// 色調補正を設定したクリップが Codable 往復で一致すること。
    func test_colorGrade_survivesCodableRoundTrip() throws {
        var clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)
        clip.colorGrade = ColorGrade(brightness: 0.3, contrast: 1.4, saturation: 0.6, warmth: -0.2)

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: data)
        XCTAssertEqual(decoded, clip, "Codable 往復でクリップが変わった")
        XCTAssertEqual(decoded.colorGrade, clip.colorGrade)
    }
}
