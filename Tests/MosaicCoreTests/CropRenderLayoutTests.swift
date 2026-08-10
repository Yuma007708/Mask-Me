import CoreGraphics
import XCTest
@testable import MosaicCore

/// `RenderPlacement.make`（fit → crop.expand の合成）と、`TimelineRenderLayout` の
/// 静止画専用スロット（`stillPlacement` / `stillOrientation` / `remapStill`）の契約。
///
/// **この機能で壊れると事故になるのは 2 つ**: (1) クロップ後に [0,1] へ勝手にクランプされて
/// 「クロップより広い素材」の情報が失われる、(2) 静止画の配置が動画経路（`clipID` 付き）へ
/// 漏れる／動画経路の `nil` 解決が静止画の配置を掴んでしまう。
final class CropRenderLayoutTests: XCTestCase {
    // MARK: - test_クロップした配置は枠外へはみ出したまま写る

    /// クロップより広い素材（＝クロップ後にはみ出す配置）を fit すると、
    /// `RenderPlacement.make` の結果は [0,1] からはみ出す（負の原点・1 を超える幅）。
    /// これを `TimelineRenderLayout.remap` へ通しても、途中でクランプが入らないこと。
    func test_クロップした配置は枠外へはみ出したまま写る() {
        let clipID = UUID()
        let frame = CGSize(width: 1920, height: 1080)
        // 出力枠のごく中央だけを切り取るクロップ。素材（全面に fit）はこのクロップより
        // はるかに広いので、クロップ後の配置は大きく [0,1] の外へはみ出す。
        let crop = CropRect(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let placement = RenderPlacement.make(displaySize: frame, orientation: .identity,
                                             frame: frame, crop: crop)
        XCTAssertLessThan(placement.minX, 0, "クロップより広い素材ははみ出すはず")
        XCTAssertLessThan(placement.minY, 0)
        XCTAssertGreaterThan(placement.maxX, 1)
        XCTAssertGreaterThan(placement.maxY, 1)

        let layout = TimelineRenderLayout(placements: [clipID: placement])
        // 素材の中心（＝顔があるとする）を写した結果も、クランプされず負の値のまま出る。
        let rect = layout.remap(CGRect(x: 0.0, y: 0.0, width: 0.01, height: 0.01), clipID: clipID)
        XCTAssertEqual(rect.minX, placement.minX, accuracy: 1e-9,
                       "remap がクランプを入れてはならない（負の x が残るはず）")
        XCTAssertLessThan(rect.minX, 0, "クロップの外へ出た矩形が [0,1] へ押し込められている")
    }

    // MARK: - test_クロップと回転の往復が全8向きで恒等

    /// クロップ由来の（部分的に [0,1] の外へ出る）配置でも、`remap` → `inverseRemap` の
    /// 往復が全 8 向きで恒等であること。`RenderLayoutInverseRemapTests` が置いている
    /// レターボックスだけの往復に、クロップ由来の配置を追加で固定する。
    func test_クロップと回転の往復が全8向きで恒等() {
        let clipID = UUID()
        let frame = CGSize(width: 1000, height: 1000)
        let crops = [CropRect.full,
                    CropRect(rect: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5)),
                    CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        let orientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
            [ClipOrientation(rotation: rotation, isMirrored: false),
             ClipOrientation(rotation: rotation, isMirrored: true)]
        }
        let rects = [CGRect(x: 0.2, y: 0.3, width: 0.25, height: 0.4),
                    CGRect(x: 0, y: 0, width: 1, height: 1)]
        for crop in crops {
            for orientation in orientations {
                let placement = RenderPlacement.make(displaySize: frame, orientation: orientation,
                                                     frame: frame, crop: crop)
                let layout = TimelineRenderLayout(placements: [clipID: placement],
                                                  orientations: [clipID: orientation])
                for rect in rects {
                    let composed = layout.remap(rect, clipID: clipID)
                    guard let back = layout.inverseRemap(composed, clipID: clipID) else {
                        return XCTFail("\(orientation) crop=\(crop) で逆写像が nil になった")
                    }
                    XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9, "\(orientation) \(crop)")
                    XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9, "\(orientation) \(crop)")
                    XCTAssertEqual(back.width, rect.width, accuracy: 1e-9, "\(orientation) \(crop)")
                    XCTAssertEqual(back.height, rect.height, accuracy: 1e-9, "\(orientation) \(crop)")
                }
            }
        }
    }

    // MARK: - test_静止画マスクもレイアウトを通る

    func test_静止画マスクもレイアウトを通る() throws {
        let stillMask = try XCTUnwrap(ObjectMask.single(
            anchor: .still, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))

        let identityResult = ObjectMaskResolver.placements(
            [stillMask], clipID: nil, sourceTime: 0, layout: .identity)
        XCTAssertEqual(identityResult.count, 1)
        XCTAssertEqual(identityResult[0].rect, stillMask.rect(atSourceTime: 0),
                       "恒等レイアウトでは静止画の rect が変わってはならない")

        let nonUnitStillPlacement = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let stillLayout = TimelineRenderLayout(placements: [:],
                                               stillPlacement: nonUnitStillPlacement)
        let movedResult = ObjectMaskResolver.placements(
            [stillMask], clipID: nil, sourceTime: 0, layout: stillLayout)
        XCTAssertEqual(movedResult.count, 1)
        XCTAssertNotEqual(movedResult[0].rect, stillMask.rect(atSourceTime: 0),
                          "stillPlacement を非単位にしたら rect が動くはず")
        XCTAssertEqual(movedResult[0].rect, stillLayout.remapStill(stillMask.rect(atSourceTime: 0)))
    }

    // MARK: - test_静止画スロットは動画経路に漏れない

    func test_静止画スロットは動画経路に漏れない() {
        let clipID = UUID()
        let rect = CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.1)

        let plainLayout = TimelineRenderLayout(placements: [:])
        let plainResult = plainLayout.remap(rect, clipID: clipID)

        let stillHeavyLayout = TimelineRenderLayout(
            placements: [:],
            stillPlacement: CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
            stillOrientation: ClipOrientation(rotation: .right90, isMirrored: true))
        let stillHeavyResult = stillHeavyLayout.remap(rect, clipID: clipID)

        XCTAssertEqual(plainResult, stillHeavyResult,
                       "stillPlacement/stillOrientation が動画経路（clipID 付き）へ漏れてはならない")
        XCTAssertEqual(stillHeavyResult, rect, "未登録クリップは単位矩形・無変換のまま")

        // 実在するクリップを登録していても、静止画スロットは無関係のまま。
        let registeredPlacement = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let registeredLayout = TimelineRenderLayout(
            placements: [clipID: registeredPlacement],
            stillPlacement: CGRect(x: 0, y: 0, width: 0.3, height: 0.3))
        let plainRegisteredLayout = TimelineRenderLayout(placements: [clipID: registeredPlacement])
        XCTAssertEqual(registeredLayout.remap(rect, clipID: clipID),
                       plainRegisteredLayout.remap(rect, clipID: clipID))
    }
}
