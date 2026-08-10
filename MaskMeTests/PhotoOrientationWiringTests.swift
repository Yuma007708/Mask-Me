import CoreGraphics
import UIKit
import XCTest
import MosaicCore
@testable import MaskMe

/// 写真の回転（写真モード底上げ 第6段）の **配線**（UI 入力 ⇄ モデル状態 ⇄ 描画）を、
/// モデルを実際に動かして確かめる。ソース走査ではない。
///
/// **この作業ツリーでは実行できない**（`MaskMeTests/` は `xcodebuild` 経由でのみ動く。
/// `CLAUDE.md` の作業ツリー制約参照）。`ObjectMaskAngleWiringTests` と同じ流儀
/// （`MosaicEditorModel(mode: .photo, ...)` を直接動かし、実素材・MediaPipe は使わない）。
@MainActor
final class PhotoOrientationWiringTests: XCTestCase {
    private func makeModel() -> MosaicEditorModel {
        MosaicEditorModel(mode: .photo, recents: RecentItemsStore())
    }

    /// 300x200（縦横比あり）の単色画像。`load(image:)` は MediaPipe 無しの環境では
    /// `NullFaceLandmarker` が常に 0 件を返すので、検出結果に依存しないテストにできる。
    private func makeImage(width: CGFloat = 300, height: CGFloat = 200) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            UIColor.gray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private let allOrientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
        [ClipOrientation(rotation: rotation, isMirrored: false),
         ClipOrientation(rotation: rotation, isMirrored: true)]
    }

    /// テスト専用: `applyPhotoEdit` を経由せず向きだけを直接差し替える
    /// （`rotatePhotoLeft/Right`/`flipPhotoHorizontally` の**組み合わせの正しさ**は
    /// `ClipOrientationTests` が固定済みなので、ここでは任意の向きを直接注入して
    /// `renderLayout` 以降の配線だけを見る）。
    private func setOrientation(_ model: MosaicEditorModel, _ orientation: ClipOrientation) {
        model.photoEdit.orientation = orientation
    }

    // MARK: - 矩形の往復（片道 + 往復をセットで）

    /// **片道の絶対値**: プレビュー（＝回転後の合成フレーム）上に描いた矩形が、
    /// `renderLayout.inverseRemapStill` で写した素材フレーム基準の座標で保存されること。全 8 向き。
    func test_rectDrawnOnRotatedPreview_isStoredInSourceCoordinates() throws {
        for orientation in allOrientations {
            let model = makeModel()
            model.load(image: makeImage())
            setOrientation(model, orientation)

            let compositionRect = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.15)
            let expectedSourceRect = try XCTUnwrap(
                model.renderLayout.inverseRemapStill(compositionRect), "orientation=\(orientation)")

            model.appendObjectMask(compositionRect: compositionRect)
            let stored = try XCTUnwrap(model.objectMasks.first?.rect(atSourceTime: 0),
                                       "orientation=\(orientation)")

            XCTAssertEqual(stored.minX, expectedSourceRect.minX, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(stored.minY, expectedSourceRect.minY, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(stored.width, expectedSourceRect.width, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(stored.height, expectedSourceRect.height, accuracy: 1e-9, "orientation=\(orientation)")
        }
    }

    /// **往復**: 保存された素材座標を `objectMaskPlacements` で合成へ戻すと、元の矩形へ戻ること。
    /// 片道テストと必ずセットで置く（往復だけだと「両方向とも写像しない」実装が緑になる）。
    func test_rectDrawnOnRotatedPreview_comesBackToTheSameSpot() throws {
        for orientation in allOrientations {
            let model = makeModel()
            model.load(image: makeImage())
            setOrientation(model, orientation)

            let compositionRect = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.15)
            model.appendObjectMask(compositionRect: compositionRect)

            let placement = try XCTUnwrap(model.objectMaskPlacements(atComposition: 0).first,
                                          "orientation=\(orientation)")
            XCTAssertEqual(placement.rect.minX, compositionRect.minX, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(placement.rect.minY, compositionRect.minY, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(placement.rect.width, compositionRect.width, accuracy: 1e-9, "orientation=\(orientation)")
            XCTAssertEqual(placement.rect.height, compositionRect.height, accuracy: 1e-9, "orientation=\(orientation)")
        }
    }

    // MARK: - 二重掛かりの直接検査

    /// `objectMaskPlacements` の戻りが `renderLayout.remapStill(保存rect)` と**厳密に**一致すること。
    /// 二重に掛かっていれば（`right90` なら）`half` 相当になるので必ず落ちる。傾きも同様。
    func test_photoPlacementsAreRemappedExactlyOnce() throws {
        let model = makeModel()
        model.load(image: makeImage())
        let orientation = ClipOrientation(rotation: .right90, isMirrored: true)
        setOrientation(model, orientation)

        let sourceRect = CGRect(x: 0.15, y: 0.25, width: 0.2, height: 0.3)
        let sourceAngle = 0.4
        guard let mask = ObjectMask(anchor: .still, keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: sourceRect, angle: sourceAngle)
        ]) else {
            return XCTFail("マスクを作れない")
        }
        model.objectMasks = [mask]

        let placement = try XCTUnwrap(model.objectMaskPlacements(atComposition: 0).first)
        let expectedRect = model.renderLayout.remapStill(sourceRect)
        let expectedAngle = model.renderLayout.remapStillAngle(sourceAngle)

        XCTAssertEqual(placement.rect.minX, expectedRect.minX, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.minY, expectedRect.minY, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.width, expectedRect.width, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.height, expectedRect.height, accuracy: 1e-9)
        XCTAssertEqual(placement.angle, expectedAngle, accuracy: 1e-9)

        // 二重掛かりの反証: 二重に掛けた結果とは一致しないこと（空振り対策）。
        let doubleApplied = model.renderLayout.remapStill(expectedRect)
        XCTAssertNotEqual(placement.rect.minX, doubleApplied.minX, accuracy: 1e-9,
            "二重掛かりの結果と一致してしまっている（テストの前提が成立していない）")
    }

    // MARK: - 枠（UI）と焼き込み（描画）の一致

    /// `visibleObjectMasks`（UI のチップ表示）と `objectMaskPlacements`（描画の入力）が
    /// 一致すること。全 8 向き。片方だけ委譲し忘れるという最も起きやすい漏れを捕まえる。
    func test_visibleObjectMasksMatchesObjectMaskPlacements() throws {
        for orientation in allOrientations {
            let model = makeModel()
            model.load(image: makeImage())
            setOrientation(model, orientation)

            let compositionRect = CGRect(x: 0.1, y: 0.15, width: 0.25, height: 0.2)
            model.appendObjectMask(compositionRect: compositionRect)

            let placements = model.objectMaskPlacements(atComposition: 0)
            XCTAssertGreaterThan(placements.count, 0, "orientation=\(orientation): 空振りガード")

            let visible = model.visibleObjectMasks
            XCTAssertEqual(visible.count, placements.count, "orientation=\(orientation)")
            for (v, p) in zip(visible, placements) {
                XCTAssertEqual(v.rect.minX, p.rect.minX, accuracy: 1e-9, "orientation=\(orientation)")
                XCTAssertEqual(v.rect.minY, p.rect.minY, accuracy: 1e-9, "orientation=\(orientation)")
                XCTAssertEqual(v.rect.width, p.rect.width, accuracy: 1e-9, "orientation=\(orientation)")
                XCTAssertEqual(v.rect.height, p.rect.height, accuracy: 1e-9, "orientation=\(orientation)")
                XCTAssertEqual(v.angle, p.angle, accuracy: 1e-9, "orientation=\(orientation)")
            }
        }
    }

    // MARK: - 矩形サーチ（クロップ範囲）

    /// `detectInRegion` がクロップに使う `materialRect` が、
    /// `renderLayout.inverseRemapStill(normalizedRect)` と一致すること（回した写真の矩形
    /// サーチが正しい素材位置を走査しているかの代理指標。
    /// `lastDetectInRegionMaterialRectForTesting` の doc 参照）。
    func test_detectInRegionSearchesTheRotatedSourceArea() async throws {
        let model = makeModel()
        model.load(image: makeImage())
        let orientation = ClipOrientation(rotation: .left90)
        setOrientation(model, orientation)

        let normalizedRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        let expected = try XCTUnwrap(model.renderLayout.inverseRemapStill(normalizedRect))

        await model.detectInRegion(normalizedRect)

        let actual = try XCTUnwrap(model.lastDetectInRegionMaterialRectForTesting)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9)
    }

    // MARK: - 回転しても再検出しない

    /// 回転しても顔検出をやり直さないこと。「回転したら検出し直せばいい」という
    /// 最も危険な直し方（上下逆・横倒しの顔は検出率が落ちるので再検出は検出退行そのもの）
    /// を封じる。冒頭で顔 0 件での空振り緑を塞ぐ。
    func test_rotatingDoesNotReRunFaceDetection() {
        let model = makeModel()
        model.load(image: makeImage())
        model.detectedFaces = [
            FaceTarget(id: UUID(), landmarks: FaceLandmarkSet(points: [
                FaceLandmark(x: 0.4, y: 0.4), FaceLandmark(x: 0.6, y: 0.4), FaceLandmark(x: 0.5, y: 0.6)
            ], confidence: 1), thumbnail: UIImage(), isSelected: true)
        ]
        XCTAssertGreaterThan(model.detectedFaces.count, 0, "テスト前提: 顔が仕込めていない（空振り緑を防ぐ）")
        let before = model.detectedFaces

        model.rotatePhotoRight()

        XCTAssertEqual(model.detectedFaces.count, before.count, "回転で detectedFaces の件数が変わった")
        XCTAssertEqual(model.detectedFaces.map(\.id), before.map(\.id), "回転で detectedFaces が作り直された（再検出の疑い）")
    }

    // MARK: - undo

    func test_rotatingIsUndoable() {
        let model = makeModel()
        model.load(image: makeImage())
        XCTAssertTrue(model.photoEdit.orientation.isIdentity)

        model.rotatePhotoRight()
        XCTAssertEqual(model.photoEdit.orientation, ClipOrientation(rotation: .right90))

        model.undo()
        XCTAssertTrue(model.photoEdit.orientation.isIdentity, "undo で向きが戻らない")

        model.redo()
        XCTAssertEqual(model.photoEdit.orientation, ClipOrientation(rotation: .right90), "redo で向きが復元しない")
    }

    // MARK: - stillPlacement の非上書き

    /// `renderLayout` が向きだけを注入し、`stillPlacement`（将来のクロップ）を上書きしないこと。
    func test_renderLayoutNeverOverwritesStillPlacement() {
        let model = makeModel()
        model.load(image: makeImage())
        let crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        model.builtLayout = TimelineRenderLayout(placements: [:], stillPlacement: crop, stillOrientation: .identity)

        model.rotatePhotoRight()

        XCTAssertEqual(model.renderLayout.stillPlacement, crop, "renderLayout が stillPlacement を上書きした")
        XCTAssertEqual(model.renderLayout.stillOrientation, ClipOrientation(rotation: .right90))
    }
}
