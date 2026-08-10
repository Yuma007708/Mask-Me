import CoreGraphics
import XCTest
@testable import MosaicCore

/// 物体マスクの「いま追えているか」の状態判定（`ObjectMaskResolver.resolve`）を固定する。
///
/// 守っているのは **「`ObjectTrack.rect(atSourceTime:) != nil` を追跡中と読まない」**こと。
/// 末尾・先頭の clamp は追跡が終わった後も最後の位置を返し続けるので、素朴な実装は
/// 「追跡が止まっているのにずっと追跡中」と表示してしまう。
final class ObjectMaskFollowStateTests: XCTestCase {
    private let sourceID = UUID()
    private let clipA = UUID()

    private func mask(x: CGFloat = 0.1) -> ObjectMask {
        ObjectMask.single(anchor: .clip(clipID: clipA, sourceID: sourceID),
                          rect: CGRect(x: x, y: 0.2, width: 0.2, height: 0.2))!
    }

    private func stillMask() -> ObjectMask {
        ObjectMask.single(anchor: .still, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))!
    }

    private func track(for mask: ObjectMask, segment: ObjectTrack.Segment) -> ObjectTrack {
        ObjectTrack(maskID: mask.id, clipID: clipA, sourceID: sourceID,
                    keyframes: mask.keyframes, segments: [segment])
    }

    private func segment(_ samples: [(Double, CGFloat)]) -> ObjectTrack.Segment {
        ObjectTrack.Segment(samples: samples.map {
            .init(sourceTime: $0.0, rect: CGRect(x: $0.1, y: 0.2, width: 0.2, height: 0.2))
        })!
    }

    // MARK: - .tracking

    func test_軌跡の区間内なら追跡中() {
        let target = mask()
        let seg = segment([(0, 0.1), (2, 0.9)])
        let tracks = [target.id: track(for: target, segment: seg)]

        let result = ObjectMaskResolver.resolve(of: target, tracks: tracks, atSourceTime: 1,
                                                isTrackingRunning: false)
        XCTAssertEqual(result.state, .tracking)
        XCTAssertEqual(result.rect.origin.x, 0.5, accuracy: 1e-12)
    }

    // MARK: - 末尾 clamp（防波堤）

    /// **末尾で止まっているときは追跡中と言わない。**
    /// 素朴な実装（`track.rect(atSourceTime:) != nil ? .tracking : .untracked`）は
    /// ここで落ちる。末尾 clamp は追跡終了後も非 nil を返し続けるため。
    func test_末尾で止まっているときは追跡中と言わない() {
        // キーフレームは 0 と 2 の 2 個だが、追跡セグメントはキーフレームの
        // 最後(2)より先の 5 まで伸びている（＝末尾 clamp が起きる形。
        // `ObjectTrack.rect(atSourceTime:)` の doc 参照）。
        let target = ObjectMask(anchor: .clip(clipID: clipA, sourceID: sourceID), keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            ObjectMask.Keyframe(sourceTime: 2, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))
        ])!
        let seg = segment([(0, 0.1), (5, 0.9)])
        let tracks = [target.id: track(for: target, segment: seg)]

        // セグメント末尾(5)より後の時刻。追跡は 5 で見失って止まっている。
        let result = ObjectMaskResolver.resolve(of: target, tracks: tracks, atSourceTime: 6,
                                                isTrackingRunning: false)
        XCTAssertEqual(result.state, .untracked)
        // rect は軌跡末尾の値（clamp）のまま——状態判定を足しても矩形は変えない。
        XCTAssertEqual(result.rect.origin.x, 0.9, accuracy: 1e-12)
    }

    // MARK: - セグメントの穴

    func test_セグメントの穴では追跡なし() {
        let target = ObjectMask(anchor: .clip(clipID: clipA, sourceID: sourceID), keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            ObjectMask.Keyframe(sourceTime: 10, rect: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.2))
        ])!
        let segFirst = segment([(0, 0.1), (2, 0.3)])
        let segSecond = segment([(6, 0.7), (10, 0.5)])
        let track = ObjectTrack(maskID: target.id, clipID: clipA, sourceID: sourceID,
                                keyframes: target.keyframes, segments: [segFirst, segSecond])

        // 2 と 6 の間（穴）。
        let result = ObjectMaskResolver.resolve(of: target, tracks: [target.id: track],
                                                atSourceTime: 4, isTrackingRunning: false)
        XCTAssertEqual(result.state, .untracked)
        // rect はキーフレーム補間（穴では track.rect(atSourceTime:) が nil）。
        XCTAssertEqual(result.rect, target.rect(atSourceTime: 4))
    }

    // MARK: - 古い軌跡

    func test_キーフレームを動かした古い軌跡は追跡中にならない() {
        let target = mask()
        let seg = segment([(0, 0.1), (2, 0.9)])
        let stale = ObjectTrack(maskID: target.id, clipID: clipA, sourceID: sourceID,
                                keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: .zero)],
                                segments: [seg])

        let result = ObjectMaskResolver.resolve(of: target, tracks: [target.id: stale],
                                                atSourceTime: 1, isTrackingRunning: true)
        // 軌跡は matches せず捨てられるので、走行中なら .computing。
        XCTAssertEqual(result.state, .computing)
        XCTAssertEqual(result.rect, target.rect(atSourceTime: 1))
    }

    // MARK: - .computing

    func test_軌跡が無く追跡が走行中なら解析中() {
        let target = mask()
        let result = ObjectMaskResolver.resolve(of: target, tracks: [:], atSourceTime: 1,
                                                isTrackingRunning: true)
        XCTAssertEqual(result.state, .computing)
    }

    func test_軌跡が最新なら走行中でも解析中にしない() {
        let target = mask()
        let seg = segment([(0, 0.1), (2, 0.9)])
        let tracks = [target.id: track(for: target, segment: seg)]

        let result = ObjectMaskResolver.resolve(of: target, tracks: tracks, atSourceTime: 1,
                                                isTrackingRunning: true)
        XCTAssertEqual(result.state, .tracking)
    }

    // MARK: - .fixed

    func test_静止画マスクは追跡状態を持たない() {
        let still = stillMask()
        let result = ObjectMaskResolver.resolve(of: still, tracks: [:], atSourceTime: 0,
                                                isTrackingRunning: true)
        XCTAssertEqual(result.state, .fixed)
        XCTAssertEqual(result.rect, still.rect(atSourceTime: 0))
    }

    // MARK: - 退行ガード

    /// **状態判定を足しても矩形は変わらない。** `resolve` が「`.tracking` 以外は
    /// キーフレームを返す」と書かれると、末尾 clamp の矩形が元の位置へ飛んでしまう
    /// （モザイクの退行）。追跡中・末尾clamp・穴/古いの 3 パターンで
    /// `rect(of:tracks:atSourceTime:)` と `resolve(...).rect` が一致することを固定する。
    func test_状態判定を足しても矩形は変わらない() {
        // 追跡中。
        let tracking = mask()
        let trackingSeg = segment([(0, 0.1), (2, 0.9)])
        let trackingTracks = [tracking.id: track(for: tracking, segment: trackingSeg)]
        XCTAssertEqual(
            ObjectMaskResolver.rect(of: tracking, tracks: trackingTracks, atSourceTime: 1),
            ObjectMaskResolver.resolve(of: tracking, tracks: trackingTracks, atSourceTime: 1,
                                       isTrackingRunning: false).rect)

        // 末尾 clamp。
        let clamped = ObjectMask(anchor: .clip(clipID: clipA, sourceID: sourceID), keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            ObjectMask.Keyframe(sourceTime: 5, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))
        ])!
        let clampedSeg = segment([(0, 0.1), (2, 0.9)])
        let clampedTracks = [clamped.id: track(for: clamped, segment: clampedSeg)]
        XCTAssertEqual(
            ObjectMaskResolver.rect(of: clamped, tracks: clampedTracks, atSourceTime: 3),
            ObjectMaskResolver.resolve(of: clamped, tracks: clampedTracks, atSourceTime: 3,
                                       isTrackingRunning: true).rect)

        // 古い軌跡（キーフレーム補間）。
        let stale = mask()
        let staleSeg = segment([(0, 0.1), (2, 0.9)])
        let staleTrack = ObjectTrack(maskID: stale.id, clipID: clipA, sourceID: sourceID,
                                     keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: .zero)],
                                     segments: [staleSeg])
        XCTAssertEqual(
            ObjectMaskResolver.rect(of: stale, tracks: [stale.id: staleTrack], atSourceTime: 1),
            ObjectMaskResolver.resolve(of: stale, tracks: [stale.id: staleTrack], atSourceTime: 1,
                                       isTrackingRunning: true).rect)
    }

    /// `isTrackingRunning` は rect に一切影響しない引数であること自体を固定する。
    func test_isTrackingRunningはrectに影響しない() {
        let target = mask()
        let running = ObjectMaskResolver.resolve(of: target, tracks: [:], atSourceTime: 1,
                                                 isTrackingRunning: true)
        let idle = ObjectMaskResolver.resolve(of: target, tracks: [:], atSourceTime: 1,
                                              isTrackingRunning: false)
        XCTAssertEqual(running.rect, idle.rect)
        XCTAssertNotEqual(running.state, idle.state)
    }
}
