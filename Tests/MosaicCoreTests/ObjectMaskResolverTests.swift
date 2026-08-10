import CoreGraphics
import XCTest
@testable import MosaicCore

/// `ObjectMaskResolver` の契約を固定する。
///
/// 守っているのは **「そのクリップに置いたマスクだけが、そのクリップに出ること」**。
/// 絞り込みを落とすと A に置いたマスクが B にも出る（S11 で一度潰したバグと同型）。
/// レイアウト写像を落とすと、解像度混在のレターボックスで矩形が黒帯へずれる。
final class ObjectMaskResolverTests: XCTestCase {
    private let sourceID = UUID()
    private let clipA = UUID()
    private let clipB = UUID()

    private func mask(clipID: UUID, x: CGFloat) -> ObjectMask {
        ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                          rect: CGRect(x: x, y: 0.2, width: 0.2, height: 0.2))!
    }

    /// **他クリップのマスクは出さない。**
    func test_指定クリップのマスクだけを返す() {
        let masks = [mask(clipID: clipA, x: 0.1), mask(clipID: clipB, x: 0.5)]
        let result = ObjectMaskResolver.placements(masks, clipID: clipA, sourceTime: 0, layout: .identity)
        XCTAssertEqual(result.map(\.rect.origin.x), [0.1])
    }

    /// `clipID` が nil（写像不能）のときは `.still` だけ。どのクリップとも一致しない
    /// `.clip` を通すと、終端フレームで別クリップのマスクが混ざる。
    func test_写像不能なら静止画マスクだけを返す() {
        guard let still = ObjectMask.single(anchor: .still,
                                            rect: CGRect(x: 0.3, y: 0, width: 0.1, height: 0.1))
        else { return XCTFail("生成に失敗") }
        let result = ObjectMaskResolver.placements([mask(clipID: clipA, x: 0.1), still],
                                              clipID: nil, sourceTime: 0, layout: .identity)
        XCTAssertEqual(result.map(\.rect.origin.x), [0.3])
    }

    /// 素材フレーム基準の矩形は、レターボックスの配置へ写してから返す。
    /// 写さないと、縦動画を横フレームに収めた構成で矩形が黒帯側へずれる。
    func test_レターボックス配置へ写してから返す() {
        let place = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let layout = TimelineRenderLayout(placements: [clipA: place])
        let result = ObjectMaskResolver.placements([mask(clipID: clipA, x: 0.1)],
                                              clipID: clipA, sourceTime: 0, layout: layout)
        XCTAssertEqual(result.first?.rect.origin.x, 0.25 + 0.1 * 0.5)
        XCTAssertEqual(result.first?.rect.width, 0.2 * 0.5)
    }

    /// 素材時刻で補間する（合成時刻を渡すと rate ≠ 1 で位置がずれるので、
    /// 渡された値がそのまま補間に使われることを固定する）。
    func test_素材時刻で補間する() {
        guard let moving = ObjectMask(
            anchor: .clip(clipID: clipA, sourceID: sourceID),
            keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
                        ObjectMask.Keyframe(sourceTime: 2, rect: CGRect(x: 1, y: 0, width: 0.1, height: 0.1))])
        else { return XCTFail("生成に失敗") }
        let result = ObjectMaskResolver.placements([moving], clipID: clipA, sourceTime: 1, layout: .identity)
        XCTAssertEqual(result.first?.rect.origin.x ?? 0, 0.5, accuracy: 1e-12)
    }

    // MARK: - 自動追跡（O2）

    /// 追跡の軌跡がある時刻では、キーフレームの直線補間ではなく**軌跡**を描く。
    func test_軌跡がある時刻は追跡位置を使う() {
        let target = mask(clipID: clipA, x: 0.1)
        guard let segment = ObjectTrack.Segment(samples: [
            .init(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            .init(sourceTime: 2, rect: CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.2))])
        else { return XCTFail("区間の生成に失敗") }
        let track = ObjectTrack(maskID: target.id, clipID: clipA, sourceID: sourceID,
                                keyframes: target.keyframes, segments: [segment])
        let result = ObjectMaskResolver.placements([target], tracks: [target.id: track],
                                              clipID: clipA, sourceTime: 1, layout: .identity)
        XCTAssertEqual(result.first?.rect.origin.x ?? 0, 0.5, accuracy: 1e-12)
    }

    /// **キーフレームが変わった軌跡は使わない。** 手直しが画面に出ないのは
    /// プライバシーアプリでは実害（隠したい場所を隠せていない）になる。
    func test_古い軌跡はキーフレーム補間へフォールバックする() {
        let target = mask(clipID: clipA, x: 0.1)
        guard let segment = ObjectTrack.Segment(samples: [
            .init(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            .init(sourceTime: 2, rect: CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.2))])
        else { return XCTFail("区間の生成に失敗") }
        let stale = ObjectTrack(maskID: target.id, clipID: clipA, sourceID: sourceID,
                                keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: .zero)],
                                segments: [segment])
        let result = ObjectMaskResolver.placements([target], tracks: [target.id: stale],
                                              clipID: clipA, sourceTime: 1, layout: .identity)
        XCTAssertEqual(result.first?.rect.origin.x ?? 0, 0.1, accuracy: 1e-12)
    }
}
