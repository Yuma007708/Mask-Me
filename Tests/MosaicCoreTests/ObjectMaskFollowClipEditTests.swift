import XCTest
@testable import MosaicCore

/// クリップ編集への `ObjectMask` の追従（`ObjectMaskEditOperations.masks(following:...)`）を固定する。
///
/// **複製で元クリップのマスクが壊れたバグの回帰テストがここにある。**
/// 旧実装はクリップ列の差分から「直前のクリップと同じ素材の新規クリップ＝分割の後半」と
/// 推測しており、複製がその条件を完全に満たすため分割として処理されていた。複製では
/// 分割点がクリップ先頭になるので、元クリップのマスクがキーフレーム 1 個へ潰れ、
/// 動く人物を追っていた矩形が止まって顔が露出した。
final class ObjectMaskFollowClipEditTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// A(0-10) 1 本だけのタイムライン。
    private func makeState() -> TimelineState {
        TimelineState(clips: [TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)])
    }

    /// 素材時刻 1/5/9 に矩形を置いた、**動く人物を追っている**マスク。
    private func makeMovingMask(clipID: UUID, sourceID: UUID,
                                isRegionPlaceholder: Bool = false) -> ObjectMask {
        let frames = [
            ObjectMask.Keyframe(sourceTime: 1, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            ObjectMask.Keyframe(sourceTime: 5, rect: CGRect(x: 0.5, y: 0.3, width: 0.2, height: 0.2),
                                angle: 0.3),
            ObjectMask.Keyframe(sourceTime: 9, rect: CGRect(x: 0.8, y: 0.6, width: 0.2, height: 0.2))
        ]
        guard let mask = ObjectMask(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                    keyframes: frames, isRegionPlaceholder: isRegionPlaceholder) else {
            fatalError("テストのマスクが作れない")
        }
        return mask
    }

    // MARK: - 複製（本題）

    /// **複製で元クリップのマスクが一切変わらない**こと、複製先に同じ内容が付くこと。
    func test_duplicate_keepsOriginalKeyframesAndCopiesThemToTheCopy() {
        let before = makeState()
        let original = before.clips[0]
        let mask = makeMovingMask(clipID: original.id, sourceID: sourceA)
        let edit = before.duplicatingEdit(clipID: original.id)
        let copyClip = edit.state.clips[1]

        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])

        XCTAssertEqual(result.count, 2, "元 1 個 + 複製先 1 個")
        guard let kept = result.first(where: { $0.anchor.clipID == original.id }),
              let copied = result.first(where: { $0.anchor.clipID == copyClip.id }) else {
            return XCTFail("元クリップ／複製先のマスクが見つからない")
        }
        // 1. 元クリップのマスクは**一切変更しない**（id もキーフレームもそのまま）。
        XCTAssertEqual(kept, mask, "複製で元クリップのマスクが書き換わっている")
        XCTAssertEqual(kept.keyframes.count, 3, "キーフレームが潰れている（複製が分割として処理された）")
        // 2. 複製先は新しい ObjectMask.id・複製先の clipID・同じキーフレーム内容。
        XCTAssertNotEqual(copied.id, mask.id, "同じ id が 2 個並ぶと ForEach / firstIndex が片方にしか当たらない")
        XCTAssertEqual(copied.anchor.sourceID, sourceA)
        XCTAssertEqual(copied.keyframes.map(\.sourceTime), mask.keyframes.map(\.sourceTime))
        XCTAssertEqual(copied.keyframes.map(\.rect), mask.keyframes.map(\.rect))
        XCTAssertEqual(copied.keyframes.map(\.angle), mask.keyframes.map(\.angle))
    }

    /// 複製先の矩形は、全時刻で元と同じ位置に出る（＝軌跡がそのまま引き継がれている）。
    func test_duplicate_copyFollowsTheSameTrajectory() {
        let before = makeState()
        let original = before.clips[0]
        let mask = makeMovingMask(clipID: original.id, sourceID: sourceA)
        let edit = before.duplicatingEdit(clipID: original.id)
        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])
        guard let copied = result.first(where: { $0.anchor.clipID == edit.state.clips[1].id }) else {
            return XCTFail("複製先のマスクが無い")
        }
        XCTAssertTrue(result.contains(mask), "元クリップのマスクが原形のまま残っていない")
        for t in stride(from: 0.0, through: 10.0, by: 0.25) {
            XCTAssertEqual(copied.rect(atSourceTime: t), mask.rect(atSourceTime: t),
                           "sourceTime=\(t) で複製先の矩形が元とずれている")
            XCTAssertEqual(copied.angle(atSourceTime: t), mask.angle(atSourceTime: t), accuracy: 1e-12)
        }
    }

    /// `isRegionPlaceholder`（矩形サーチ第 1 段の暫定マスク）は複製先へ引き継ぐ。
    func test_duplicate_inheritsRegionPlaceholderFlag() {
        let before = makeState()
        let original = before.clips[0]
        let mask = makeMovingMask(clipID: original.id, sourceID: sourceA, isRegionPlaceholder: true)
        let edit = before.duplicatingEdit(clipID: original.id)
        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])
        XCTAssertEqual(result.filter(\.isRegionPlaceholder).count, 2)
        XCTAssertTrue(result.contains(mask), "元クリップのマスクが原形のまま残っていない")
    }

    /// 別クリップのマスクは複製に巻き込まれない。
    func test_duplicate_doesNotTouchOtherClipsMasks() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 10)
        let before = TimelineState(clips: [clipA, clipB])
        let maskA = makeMovingMask(clipID: clipA.id, sourceID: sourceA)
        let maskB = makeMovingMask(clipID: clipB.id, sourceID: sourceB)
        let edit = before.duplicatingEdit(clipID: clipA.id)
        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [maskA, maskB])
        XCTAssertEqual(result.filter { $0.anchor.clipID == clipB.id }, [maskB])
        XCTAssertEqual(result.filter { $0.anchor.clipID == clipA.id }, [maskA], "元クリップのマスクが変わっている")
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - 分割（回帰防止。今までどおり動くこと）

    /// 分割は従来どおり front / back の 2 個へ分かれる。
    func test_split_stillSplitsMasksAtTheSplitPoint() {
        let before = makeState()
        let original = before.clips[0]
        let mask = makeMovingMask(clipID: original.id, sourceID: sourceA)
        let edit = before.splittingEdit(at: 6)   // 素材時刻 6 で割る
        XCTAssertEqual(edit.state.clips.count, 2)
        let front = edit.state.clips[0]
        let back = edit.state.clips[1]
        XCTAssertEqual(back.sourceStart, 6, accuracy: 1e-9)

        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])
        XCTAssertEqual(result.count, 2)
        guard let frontMask = result.first(where: { $0.anchor.clipID == front.id }),
              let backMask = result.first(where: { $0.anchor.clipID == back.id }) else {
            return XCTFail("分割後のマスクが両側に無い")
        }
        // front: 6 未満の 1/5 + 境界 6。back: 境界 6 + 6 超の 9。
        XCTAssertEqual(frontMask.id, mask.id, "front は元の id を継承する")
        XCTAssertEqual(frontMask.keyframes.map(\.sourceTime), [1, 5, 6])
        XCTAssertNotEqual(backMask.id, mask.id)
        XCTAssertEqual(backMask.keyframes.map(\.sourceTime), [6, 9])
        // 境界の矩形は分割前の補間値と一致する（clamp で飛ばない）。
        XCTAssertEqual(frontMask.rect(atSourceTime: 6), mask.rect(atSourceTime: 6))
        XCTAssertEqual(backMask.rect(atSourceTime: 6), mask.rect(atSourceTime: 6))
    }

    /// 分割の追従は「分割前の位置」を保つ（境界の外側も clamp ではなく元の軌跡に乗る）。
    func test_split_preservesTrajectoryOnBothSides() {
        let before = makeState()
        let mask = makeMovingMask(clipID: before.clips[0].id, sourceID: sourceA)
        let edit = before.splittingEdit(at: 6)
        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])
        guard let frontMask = result.first(where: { $0.anchor.clipID == edit.state.clips[0].id }),
              let backMask = result.first(where: { $0.anchor.clipID == edit.state.clips[1].id }) else {
            return XCTFail("分割後のマスクが両側に無い")
        }
        for t in stride(from: 0.0, through: 6.0, by: 0.25) {
            XCTAssertEqual(frontMask.rect(atSourceTime: t).minX,
                           mask.rect(atSourceTime: t).minX, accuracy: 1e-12, "front sourceTime=\(t)")
        }
        for t in stride(from: 6.0, through: 10.0, by: 0.25) {
            XCTAssertEqual(backMask.rect(atSourceTime: t).minX,
                           mask.rect(atSourceTime: t).minX, accuracy: 1e-12, "back sourceTime=\(t)")
        }
    }

    /// 写真クリップの分割は前後へ「時刻 0 のキーフレーム 1 個」を配る（従来どおり）。
    func test_split_photoClipKeepsRectOnBothSides() {
        let photo = UUID()
        let clip = TimelineClip(sourceID: photo, sourceStart: 0, sourceEnd: 6)
        let before = TimelineState(clips: [clip],
                                   sources: [photo: TimelineSource(id: photo, kind: .photo)])
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        guard let mask = ObjectMask.single(anchor: .clip(clipID: clip.id, sourceID: photo),
                                           rect: rect) else { return XCTFail("マスクが作れない") }
        let edit = before.splittingEdit(at: 3)
        let result = ObjectMaskEditOperations.masks(following: edit.lineage, from: before,
                                                    to: edit.state, existing: [mask])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.rect(atSourceTime: 0) == rect })
    }

    // MARK: - 削除・追従不要な編集

    /// 消えたクリップのマスクは落とす（従来どおり）。
    func test_removeClip_dropsItsMasks() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 10)
        let before = TimelineState(clips: [clipA, clipB])
        let maskA = makeMovingMask(clipID: clipA.id, sourceID: sourceA)
        let maskB = makeMovingMask(clipID: clipB.id, sourceID: sourceB)
        let after = before.removing(clipID: clipA.id)
        let result = ObjectMaskEditOperations.masks(following: [], from: before, to: after,
                                                    existing: [maskA, maskB])
        XCTAssertEqual(result, [maskB])
    }

    /// トリム・並べ替え・速度変更は素材時刻アンカーがそのまま成立するので何もしない。
    func test_trimMoveRate_leaveMasksUntouched() {
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 10)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 10)
        let before = TimelineState(clips: [clipA, clipB])
        let masks = [makeMovingMask(clipID: clipA.id, sourceID: sourceA),
                     makeMovingMask(clipID: clipB.id, sourceID: sourceB)]
        for after in [before.trimming(clipID: clipA.id, sourceStart: 2, sourceEnd: 8),
                      before.moving(clipID: clipA.id, toIndex: 1),
                      before.settingRate(clipID: clipA.id, rate: 2)] {
            XCTAssertEqual(ObjectMaskEditOperations.masks(following: [], from: before, to: after,
                                                          existing: masks), masks)
        }
    }

    /// 素材追加（新しい `sourceID` の新規クリップ）は血統が無くても何も起きない
    /// ——既存クリップのマスクとは無関係なので、追従の対象ではない。
    func test_appendClip_withNewSource_doesNothing() {
        let before = makeState()
        let masks = [makeMovingMask(clipID: before.clips[0].id, sourceID: sourceA)]
        let added = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: 4)
        let after = before.appending(clip: added,
                                     source: TimelineSource(id: sourceB, kind: .video),
                                     coveringWithApplyRange: false)
        XCTAssertEqual(after.clips.count, 2)
        XCTAssertEqual(ObjectMaskEditOperations.masks(following: [], from: before, to: after,
                                                      existing: masks), masks)
    }
}
