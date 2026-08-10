import CoreGraphics
import XCTest
@testable import MosaicCore

/// クリップの向き（回転・左右反転）の**保存と復元**を固定するテスト。
///
/// 本体（`ClipOrientationTests`）から分けてあるのは file_length 対策。
/// 座標系そのものの検証はあちらにある。
final class ClipOrientationCodableTests: XCTestCase {
    /// 全 8 状態（回転 4 × 反転 2）。
    private let allOrientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
        [ClipOrientation(rotation: rotation, isMirrored: false),
         ClipOrientation(rotation: rotation, isMirrored: true)]
    }

    func test_旧下書きは回転なし反転なしで復元される() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)",
         "sourceStart":0,"sourceEnd":5,"originalAudioVolume":1}
        """
        let clip = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.orientation, .identity)
        XCTAssertTrue(clip.orientation.isIdentity)
    }

    func test_向きは下書きへ保存・復元される() throws {
        for orientation in allOrientations {
            let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                                    orientation: orientation)
            let data = try JSONEncoder().encode(clip)
            let restored = try JSONDecoder().decode(TimelineClip.self, from: data)
            XCTAssertEqual(restored.orientation, orientation)
        }
    }

    func test_端数の回転値は最も近い90度へ丸めて復元される() throws {
        let json = """
        {"rotation":45,"isMirrored":true}
        """
        let orientation = try JSONDecoder().decode(ClipOrientation.self, from: Data(json.utf8))
        // 45 度は 90 度グリッドの最も近い側（90）へ丸める。壊れた下書きでも throw しない。
        XCTAssertEqual(orientation.rotation, .right90)
        XCTAssertTrue(orientation.isMirrored)
    }

    /// **壊れた回転値でデコードが失敗しないこと。**
    ///
    /// ここが throw すると `TimelineClip` ごとデコードが失敗し、そのクリップを含む
    /// 動画プロジェクトが丸ごと nil になって、次の保存で下書き一覧から静かに消える
    /// （`ClipOrientation.init(from:)` の doc）。整数で読んでいた頃は小数・桁あふれで
    /// 実際に落ちた。**下書きが消えるのは元に戻せないので、ここは必ず守ること。**
    func test_壊れた回転値でも下書きのデコードが失敗しない() throws {
        let cases: [(json: String, expected: ClipRotation)] = [
            ("{\"rotation\":90.5,\"isMirrored\":false}", .right90),          // 小数
            ("{\"rotation\":99999999999999999999,\"isMirrored\":false}", .none),  // 桁あふれ
            ("{\"rotation\":-90,\"isMirrored\":false}", .left90),            // 負
            ("{\"rotation\":\"90\",\"isMirrored\":false}", .none),           // 型違い（文字列）
            ("{\"isMirrored\":true}", .none)                                 // キー欠落
        ]
        for (json, expected) in cases {
            let orientation = try JSONDecoder().decode(ClipOrientation.self, from: Data(json.utf8))
            XCTAssertEqual(orientation.rotation, expected, json)
        }
    }

    /// クリップ全体（`TimelineClip`）としても落ちないこと。
    /// 実害はこちらの粒度で出る（クリップ 1 本の向きが壊れると下書き 1 本が消える）。
    func test_壊れた回転値を含むクリップでも下書きのデコードが失敗しない() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)",
         "sourceStart":0,"sourceEnd":10,"originalAudioVolume":1,
         "orientation":{"rotation":90.5,"isMirrored":false}}
        """
        let clip = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.orientation.rotation, .right90)
    }
}
