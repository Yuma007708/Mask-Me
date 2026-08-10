import CoreGraphics
import XCTest
@testable import MosaicCore

/// `ObjectMaskEditOperations.masks(freezingClip:atSourceTime:into:existing:)` の振る舞いを固定する。
///
/// **これは見落とすと致命的な経路である。** 手描き矩形は「検出が効かない顔」を隠す
/// 最後の手段なので、フリーズフレームに引き継がれないと検出も矩形も無いフレームが生まれる。
final class ObjectMaskFreezeTests: XCTestCase {
    private let sourceID = UUID()
    private let freezeSourceID = UUID()

    private func rect(x: CGFloat) -> CGRect { CGRect(x: x, y: 0.2, width: 0.1, height: 0.1) }

    private func clip(id: UUID = UUID(), sourceID: UUID? = nil,
                      start: Double = 0, end: Double = 1) -> TimelineClip {
        TimelineClip(id: id, sourceID: sourceID ?? self.sourceID, sourceStart: start, sourceEnd: end)
    }

    /// x=0 → x=1 へ 10 秒かけて動くマスク（キーフレーム 3 個、傾きも変化する）。
    private func movingMask(clipID: UUID) -> ObjectMask {
        ObjectMask(id: UUID(), anchor: .clip(clipID: clipID, sourceID: sourceID),
                   keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: 0), angle: 0),
                               ObjectMask.Keyframe(sourceTime: 4, rect: rect(x: 0.7), angle: 0.4),
                               ObjectMask.Keyframe(sourceTime: 10, rect: rect(x: 1), angle: 1.0)])!
    }

    /// 補間途中の素材時刻で解決した矩形・角度が、キーフレーム 1 個としてそのまま写る。
    func test_補間途中の矩形と角度がキーフレーム1個として写る() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let freezeClip = clip(sourceID: freezeSourceID)
        let expectedRect = mask.rect(atSourceTime: 2.0)
        let expectedAngle = mask.angle(atSourceTime: 2.0)

        let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: 2.0,
                                                    into: freezeClip, existing: [mask])

        XCTAssertEqual(result.count, 2, "元のマスクは残り、フリーズクリップ用が 1 本追加される")
        guard let frozen = result.first(where: { $0.anchor.clipID == freezeClip.id }) else {
            return XCTFail("フリーズクリップ用のマスクが見つからない")
        }
        XCTAssertEqual(frozen.keyframes.count, 1, "フリーズ先はキーフレーム 1 個に畳む")
        XCTAssertEqual(frozen.keyframes[0].sourceTime, 0, "フリーズ先の素材時刻は常に 0")
        XCTAssertEqual(frozen.keyframes[0].rect.origin.x, expectedRect.origin.x, accuracy: 1e-12)
        XCTAssertEqual(frozen.keyframes[0].angle, expectedAngle, accuracy: 1e-12)
        XCTAssertEqual(frozen.anchor.sourceID, freezeSourceID)
    }

    /// `sourceTime == 0`（キーフレームの唯一の時刻）が常に成り立つ。
    func test_フリーズ先のsourceTimeは常に0() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let freezeClip = clip(sourceID: freezeSourceID)

        for sourceTime in [0.0, 1.0, 4.0, 9.9, 10.0] {
            let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: sourceTime,
                                                        into: freezeClip, existing: [mask])
            let frozen = result.first { $0.anchor.clipID == freezeClip.id }
            XCTAssertEqual(frozen?.keyframes.map(\.sourceTime), [0], "t=\(sourceTime)")
        }
    }

    /// 元クリップのマスクは一切変わらない。
    func test_元クリップのマスクは変わらない() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let freezeClip = clip(sourceID: freezeSourceID)

        let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: 2.0,
                                                    into: freezeClip, existing: [mask])

        XCTAssertEqual(result.first { $0.id == mask.id }, mask, "元のマスクは id ごとそのまま残る")
    }

    /// 対象クリップにマスクが 0 本なら、追加も 0 本。
    func test_マスクが0本なら0本を返す() {
        let clipID = UUID()
        let otherClipID = UUID()
        let other = movingMask(clipID: otherClipID)
        let freezeClip = clip(sourceID: freezeSourceID)

        let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: 2.0,
                                                    into: freezeClip, existing: [other])

        XCTAssertEqual(result, [other], "対象外のマスクだけがそのまま残り、フリーズ先は追加されない")
    }

    /// `isRegionPlaceholder` は引き継ぐ（分割・複製と同じ規則）。
    func test_isRegionPlaceholderを引き継ぐ() {
        let clipID = UUID()
        guard let placeholder = ObjectMask(id: UUID(), anchor: .clip(clipID: clipID, sourceID: sourceID),
                                           keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: 0.2))],
                                           isRegionPlaceholder: true) else {
            return XCTFail("生成に失敗")
        }
        let freezeClip = clip(sourceID: freezeSourceID)

        let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: 0,
                                                    into: freezeClip, existing: [placeholder])
        let frozen = result.first { $0.anchor.clipID == freezeClip.id }
        XCTAssertEqual(frozen?.isRegionPlaceholder, true)
    }

    /// 新しい id を振る（元と同じ id が並ぶと `ForEach` / `firstIndex(where:)` が片方にしか当たらない）。
    func test_新しいidを振る() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let freezeClip = clip(sourceID: freezeSourceID)

        let result = ObjectMaskEditOperations.masks(freezingClip: clipID, atSourceTime: 2.0,
                                                    into: freezeClip, existing: [mask])
        let frozen = result.first { $0.anchor.clipID == freezeClip.id }
        XCTAssertNotEqual(frozen?.id, mask.id)
    }
}
