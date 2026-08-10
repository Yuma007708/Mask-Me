import MosaicCore
import XCTest
@testable import MaskMe

/// 矩形の傾きが、モデルを通しても失われないことの確認。
///
/// 角度の意味づけ自体は `MosaicCore`（`ObjectMaskAngleTests` / `RectangleHandleMathTests`）で
/// 固定済み。ここで見るのは**配線**——アプリ層が角度を落とさずに往復させているか。
/// 落ちると「掴んで動かしただけで傾きが戻る」という、触れば分かるが原因は追いにくい
/// 壊れ方をする。
@MainActor
final class ObjectMaskAngleWiringTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .photo, recents: RecentItemsStore())
    }

    private func box(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0.3, width: 0.2, height: 0.2)
    }

    /// 静止画マスクを 1 つ置いたモデル。
    private func modelWithMask(angle: Double) -> (MosaicEditorModel, UUID)? {
        let model = makeModel()
        guard let mask = ObjectMask(anchor: .still, keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: angle)
        ]) else { return nil }
        model.objectMasks = [mask]
        return (model, mask.id)
    }

    /// **位置を動かしても傾きが残ること。**
    func test_movingTheRectangle_keepsItsAngle() throws {
        guard let (model, id) = modelWithMask(angle: 0.8) else {
            return XCTFail("マスクを作れない")
        }
        model.setObjectMaskKeyframe(id, compositionRect: box(0.5), angle: 0.8)

        let visible = try XCTUnwrap(model.visibleObjectMasks.first)
        XCTAssertEqual(visible.angle, 0.8, accuracy: 1e-9, "動かしたら傾きが失われた")
        XCTAssertEqual(visible.rect.origin.x, 0.5, accuracy: 1e-9)
    }

    /// 傾けた結果がモデルへ入り、表示にも出ること。
    func test_rotatingTheRectangle_isReflectedInTheOverlay() throws {
        guard let (model, id) = modelWithMask(angle: 0) else {
            return XCTFail("マスクを作れない")
        }
        model.setObjectMaskKeyframe(id, compositionRect: box(0.1), angle: -1.1)

        let visible = try XCTUnwrap(model.visibleObjectMasks.first)
        XCTAssertEqual(visible.angle, -1.1, accuracy: 1e-9)
    }

    /// **描画へ渡す path が実際に回っていること。**
    /// ここが繋がっていないと、画面の枠だけ傾いてモザイクは正立したまま
    /// （＝隠したい所が隠れない）になる。
    func test_drawnPath_isRotated() throws {
        guard let (model, _) = modelWithMask(angle: .pi / 2) else {
            return XCTFail("マスクを作れない")
        }
        let size = CGSize(width: 1600, height: 900)
        let rotated = try XCTUnwrap(model.objectMaskPaths(for: size, atComposition: 0).first)

        guard let upright = ObjectMask(anchor: .still, keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: 0)
        ]) else { return XCTFail("マスクを作れない") }
        let plain = makeModel()
        plain.objectMasks = [upright]
        let uprightPath = try XCTUnwrap(plain.objectMaskPaths(for: size, atComposition: 0).first)

        XCTAssertEqual(rotated.path.boundingBox.width, uprightPath.path.boundingBox.height,
                       accuracy: 1e-6, "描画パスが回っていない（枠だけ傾いてモザイクは正立）")
        XCTAssertEqual(rotated.path.boundingBox.midX, uprightPath.path.boundingBox.midX,
                       accuracy: 1e-6)
    }

    /// 傾きが undo/redo の対象になっていること。
    ///
    /// **マスクは編集 API（`appendObjectMask`）で置くこと。** `objectMasks` へ直接
    /// 代入すると「変更前」が記録されず、undo が戻る先を持たない（テストの
    /// 組み立てを誤ってここで一度落ちた）。
    func test_angleSurvivesUndo() throws {
        let model = makeModel()
        model.appendObjectMask(compositionRect: box(0.1))
        let id = try XCTUnwrap(model.objectMasks.first?.id)
        model.setObjectMaskKeyframe(id, compositionRect: box(0.1), angle: 0.9)
        XCTAssertEqual(model.visibleObjectMasks.first?.angle ?? .nan, 0.9, accuracy: 1e-9)

        model.undo()
        XCTAssertEqual(model.visibleObjectMasks.first?.angle ?? .nan, 0, accuracy: 1e-9,
                       "undo で傾きが戻らない")
        model.redo()
        XCTAssertEqual(model.visibleObjectMasks.first?.angle ?? .nan, 0.9, accuracy: 1e-9,
                       "redo で傾きが復元しない")
    }
}
