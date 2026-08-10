import CoreGraphics
import XCTest
@testable import MosaicCore

/// `TimelineClip.transform`: 後方互換デコード・引き継ぎ後の値・往復を固定する。
/// `TimelineClipColorGradeTests` と同じ立て付け。
final class TimelineClipTransformTests: XCTestCase {
    /// 新規クリップは既定で無変形（`.identity`）を持つこと。
    func test_newClip_defaultsToIdentityTransform() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 3)
        XCTAssertEqual(clip.transform, .identity)
    }

    /// `transform` キーを持たない旧 JSON が `.identity`（無変形）として復元されること。
    func test_decodingJSONWithoutTransformKey_fallsBackToIdentity() throws {
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
        XCTAssertEqual(decoded.transform, .identity, "transform キーが無い旧下書きが identity で復元されない")
    }

    /// 変形を設定したクリップが Codable 往復で一致すること。
    func test_transform_survivesCodableRoundTrip() throws {
        var clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)
        clip.transform = ClipTransform(scale: 1.8, offset: CGPoint(x: 0.3, y: -0.2))

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: data)
        XCTAssertEqual(decoded, clip, "Codable 往復でクリップが変わった")
        XCTAssertEqual(decoded.transform, clip.transform)
    }
}
