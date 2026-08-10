import CoreGraphics
import XCTest
@testable import MosaicCore

/// `ClipTransform`（クリップ単位の拡大縮小・位置）: クランプ・identity・
/// `applied(to:)` の数式・Codable の後方互換とデコード安全性を固定する。
final class ClipTransformTests: XCTestCase {
    // MARK: - identity / applied(to:)

    /// `identity` は配置矩形をビット同一で返す（無変形タイムラインの忠実度を守る）。
    func test_identity_returnsPlacementBitIdentical() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.4)
        XCTAssertEqual(ClipTransform.identity.applied(to: rect), rect)
        // `==` だけでなく、参照ではなく値そのものが変わっていないことも成分ごとに確認する。
        let applied = ClipTransform.identity.applied(to: rect)
        XCTAssertEqual(applied.minX, rect.minX)
        XCTAssertEqual(applied.minY, rect.minY)
        XCTAssertEqual(applied.width, rect.width)
        XCTAssertEqual(applied.height, rect.height)
    }

    /// `scale=2` で幅高さが 2 倍になり、中心は不変であること。
    func test_scale2_doublesSizeKeepsCenter() {
        let rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let transform = ClipTransform(scale: 2.0)
        let applied = transform.applied(to: rect)
        XCTAssertEqual(applied.width, 1.0, accuracy: 1e-9)
        XCTAssertEqual(applied.height, 1.0, accuracy: 1e-9)
        XCTAssertEqual(applied.midX, rect.midX, accuracy: 1e-9)
        XCTAssertEqual(applied.midY, rect.midY, accuracy: 1e-9)
    }

    /// `offset` は配置矩形自身のサイズに対する比率で中心を動かす。
    func test_offset_movesCenterByPlacementSize() {
        let rect = CGRect(x: 0.0, y: 0.0, width: 0.4, height: 0.2)
        let transform = ClipTransform(offset: CGPoint(x: 0.5, y: -0.5))
        let applied = transform.applied(to: rect)
        XCTAssertEqual(applied.width, rect.width, accuracy: 1e-9)
        XCTAssertEqual(applied.height, rect.height, accuracy: 1e-9)
        XCTAssertEqual(applied.midX, rect.midX + 0.2, accuracy: 1e-9)
        XCTAssertEqual(applied.midY, rect.midY - 0.1, accuracy: 1e-9)
    }

    // MARK: - クランプ（3 経路すべて）

    /// `init` でクランプが効くこと。
    func test_init_clampsOutOfRangeValues() {
        let over = ClipTransform(scale: 100, offset: CGPoint(x: 5, y: -5))
        XCTAssertEqual(over.scale, 4.0)
        XCTAssertEqual(over.offset.x, 1.0)
        XCTAssertEqual(over.offset.y, -1.0)

        let under = ClipTransform(scale: 0.01, offset: CGPoint(x: -5, y: 5))
        XCTAssertEqual(under.scale, 0.25)
        XCTAssertEqual(under.offset.x, -1.0)
        XCTAssertEqual(under.offset.y, 1.0)
    }

    /// 直接代入（`didSet`）でもクランプが効くこと。
    func test_directAssignment_clampsOutOfRangeValues() {
        var transform = ClipTransform.identity
        transform.scale = 100
        transform.offset = CGPoint(x: 5, y: -5)
        XCTAssertEqual(transform.scale, 4.0)
        XCTAssertEqual(transform.offset.x, 1.0)
        XCTAssertEqual(transform.offset.y, -1.0)
    }

    /// `init(from:)`（Codable のデコード経路）でもクランプが効くこと。
    func test_decoding_clampsOutOfRangeValues() throws {
        let json = """
        {"scale": 100, "offsetX": 5, "offsetY": -5}
        """
        let decoded = try JSONDecoder().decode(ClipTransform.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scale, 4.0)
        XCTAssertEqual(decoded.offset.x, 1.0)
        XCTAssertEqual(decoded.offset.y, -1.0)
    }

    /// `scale=100` → 4.0 の上限クランプ（要件どおりの具体値）。
    func test_scale100_clampsTo4() {
        XCTAssertEqual(ClipTransform.clampedScale(100), 4.0)
    }

    /// NaN は 3 経路すべてで既定値へ倒れること（scale → 1.0、offset → .zero）。
    func test_nan_fallsBackToDefaultOnAllPaths() {
        XCTAssertEqual(ClipTransform.clampedScale(.nan), 1.0)
        XCTAssertEqual(ClipTransform.clampedOffsetComponent(.nan), 0)

        let viaInit = ClipTransform(scale: .nan,
                                    offset: CGPoint(x: CGFloat.nan, y: CGFloat.nan))
        XCTAssertEqual(viaInit, ClipTransform.identity, "init 経由で NaN が既定値へ倒れない")

        var viaAssignment = ClipTransform(scale: 2.0, offset: CGPoint(x: 0.5, y: 0.5))
        viaAssignment.scale = .nan
        viaAssignment.offset = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        XCTAssertEqual(viaAssignment, ClipTransform.identity, "直接代入経由で NaN が既定値へ倒れない")
    }

    // MARK: - Codable: 後方互換・デコード安全性

    /// `transform` キーの無い旧 JSON をデコードすると `.identity` になり `validate()` も通ること。
    func test_decodingWithoutTransformKey_fallsBackToIdentityAndValidates() throws {
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
        XCTAssertEqual(decoded.transform, .identity, "transform キーが無い旧下書きが identity で復元されない")
        let state = TimelineState(clips: [decoded])
        XCTAssertTrue(state.validate())
    }

    /// 型が壊れた値（文字列）でも throw せずクリップ全体が生き残ること
    /// （下書き 1 本が丸ごと消える事故の防止）。
    func test_decodingMalformedScaleString_doesNotThrow() throws {
        let id = UUID()
        let sourceID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "sourceID": "\(sourceID.uuidString)",
          "sourceStart": 0,
          "sourceEnd": 3,
          "originalAudioVolume": 1,
          "rate": 1,
          "transform": {"scale": "abc", "offsetX": 0.2, "offsetY": 0.1}
        }
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transform.scale, 1.0, "壊れた scale は既定値へ倒れるべき")
    }

    /// 巨大値（クランプ範囲を大きく超える）でも throw せずクランプされること。
    func test_decodingHugeScale_clampsWithoutThrowing() throws {
        let id = UUID()
        let sourceID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "sourceID": "\(sourceID.uuidString)",
          "sourceStart": 0,
          "sourceEnd": 3,
          "originalAudioVolume": 1,
          "rate": 1,
          "transform": {"scale": 1e300, "offsetX": 0, "offsetY": 0}
        }
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transform.scale, 4.0)
    }

    /// `transform` の値そのものが JSON オブジェクトでない（文字列）場合も、
    /// クリップ全体のデコードが throw しないこと。
    func test_decodingTransformAsNonObject_doesNotThrow() throws {
        let id = UUID()
        let sourceID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "sourceID": "\(sourceID.uuidString)",
          "sourceStart": 0,
          "sourceEnd": 3,
          "originalAudioVolume": 1,
          "rate": 1,
          "transform": "not-an-object"
        }
        """
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transform, .identity)
    }

    // MARK: - validate()

    /// `TimelineStateValidation.validateClipTransforms()`（安全網）は常に真であること
    /// —— **`ClipTransform` は `didSet`/`init`/`init(from:)` の 3 経路すべてでクランプする
    /// 設計なので、公開 API から範囲外の値を作ることはできない**（`ColorGrade` と同じ設計。
    /// `validateColorGrades()` と同様、こちらにも「範囲外を直接代入 → validate()==false」を
    /// 実演するテストは既存コードベースに存在しない。本テストはそれを裏取りする代わりに、
    /// 通常経路で作れる最大限の値（範囲の両端）を代入しても常に validate が通ることを固定し、
    /// 安全網が誤って正常値を落とさないことを確認する）。
    func test_boundaryTransform_stillValidates() {
        var clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5)
        clip.transform = ClipTransform(scale: ClipTransform.scaleRange.upperBound,
                                       offset: CGPoint(x: ClipTransform.offsetRange.upperBound,
                                                       y: ClipTransform.offsetRange.lowerBound))
        let state = TimelineState(clips: [clip])
        XCTAssertTrue(state.validate(), "範囲の端の値で validate が誤って落ちている")
    }

    // MARK: - 分割・複製での引き継ぎ

    /// 分割しても変形が引き継がれること（`ClipOrientationTests.test_分割しても向きが引き継がれる` と同型）。
    func test_分割しても変形が引き継がれる() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10,
                                transform: ClipTransform(scale: 1.5, offset: CGPoint(x: 0.2, y: -0.1)))
        let split = TimelineEditOperations.split(clips: [clip], at: 5)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].transform, clip.transform)
        XCTAssertEqual(split[1].transform, clip.transform)
    }

    /// 複製しても変形が引き継がれること（`ClipOrientationTests.test_複製しても向きが引き継がれる` と同型）。
    func test_複製しても変形が引き継がれる() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10,
                                transform: ClipTransform(scale: 1.5, offset: CGPoint(x: 0.2, y: -0.1)))
        let duplicated = TimelineEditOperations.duplicate(clips: [clip], clipID: clip.id)
        XCTAssertEqual(duplicated.count, 2)
        XCTAssertEqual(duplicated[0].transform, clip.transform)
        XCTAssertEqual(duplicated[1].transform, clip.transform)
        XCTAssertNotEqual(duplicated[1].id, clip.id)
    }

    // MARK: - スキーマ版

    /// 現在のスキーマ版が 7 のまま（transform は v7 の 3 つ目のキーとして合流した）であること。
    func test_currentSchemaVersionIsStill7() {
        XCTAssertEqual(TimelineState.currentSchemaVersion, 7)
    }
}
