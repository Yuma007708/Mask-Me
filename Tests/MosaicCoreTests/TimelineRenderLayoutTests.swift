import CoreGraphics
import XCTest
@testable import MosaicCore

/// S8 レビュー M-1: 合成フレーム ⇄ 素材フレームの写像（レターボックス）を固定する。
///
/// ユーザーがプレビュー（＝合成フレーム）上に描いた矩形を素材へ当てる経路
/// （`MosaicEditorModel` の矩形サーチ）は、レターボックスの**逆写像**を必ず通さないと
/// 素材上の別の場所をクロップして探す。ここで写像の往復と、矩形が黒帯へはみ出したときの
/// 扱いを純ロジックとして固定しておく。
final class TimelineRenderLayoutTests: XCTestCase {
    private let clipID = UUID()
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 240x320（縦）の素材を 320x240（横）のフレームへフィットした配置。
    /// 実測値: x=0.21875 / width=0.5625 / 高さは全面。
    private var portraitInLandscape: CGRect {
        AspectFit.placement(of: CGSize(width: 240, height: 320),
                            in: CGSize(width: 320, height: 240))
    }

    private func layout(_ rect: CGRect) -> TimelineRenderLayout {
        TimelineRenderLayout(placements: [clipID: rect])
    }

    // MARK: - 配置そのもの

    /// レターボックス配置が出力ピクセル矩形と一致すること
    /// （320x240 のフレーム内で x=70..250 = 幅 180px）。
    func test_placementMatchesOutputPixelRect() {
        let place = portraitInLandscape
        XCTAssertEqual(place.minX, 0.21875, accuracy: 1e-12)
        XCTAssertEqual(place.minY, 0, accuracy: 1e-12)
        XCTAssertEqual(place.width, 0.5625, accuracy: 1e-12)
        XCTAssertEqual(place.height, 1.0, accuracy: 1e-12)
        XCTAssertEqual(place.minX * 320, 70, accuracy: 1e-9)
        XCTAssertEqual(place.width * 320, 180, accuracy: 1e-9)
    }

    // MARK: - 前進写像（素材 → 合成）

    /// レビューが実測した「素材 x → 合成 x」のずれをそのまま固定する。
    /// 逆写像を通さずに矩形を当てると、この差ぶん（最大 0.175 = 56px）ずれる。
    func test_remapMovesSourceRectIntoPlacement() {
        let layout = layout(portraitInLandscape)
        let expected: [(source: CGFloat, composition: CGFloat)] = [
            (0.10, 0.275), (0.30, 0.3875), (0.50, 0.5), (0.90, 0.725)
        ]
        for (source, composition) in expected {
            let rect = layout.remap(CGRect(x: source, y: 0, width: 0.05, height: 0.05),
                                    clipID: clipID)
            XCTAssertEqual(rect.minX, composition, accuracy: 1e-12,
                           "素材 x=\(source) の合成 x が想定とずれている")
            XCTAssertEqual(rect.width, 0.05 * 0.5625, accuracy: 1e-12)
            XCTAssertEqual(rect.minY, 0, accuracy: 1e-12, "縦は全面なので等倍のはず")
        }
    }

    // MARK: - 逆写像（合成 → 素材）

    /// 上の表の**逆向き**: 合成座標の矩形が素材座標の正しい位置に写ること。
    func test_inverseRemapMovesCompositionRectBackToSource() {
        let layout = layout(portraitInLandscape)
        let expected: [(composition: CGFloat, source: CGFloat)] = [
            (0.275, 0.10), (0.3875, 0.30), (0.5, 0.50), (0.725, 0.90)
        ]
        for (composition, source) in expected {
            let rect = layout.inverseRemap(
                CGRect(x: composition, y: 0, width: 0.05 * 0.5625, height: 0.05), clipID: clipID)
            XCTAssertEqual(rect?.minX ?? -1, source, accuracy: 1e-12,
                           "合成 x=\(composition) が素材 x=\(source) に戻っていない")
            XCTAssertEqual(rect?.width ?? -1, 0.05, accuracy: 1e-12)
        }
    }

    /// `remap` → `inverseRemap` が恒等（round-trip）であること。
    func test_remapInverseRemapRoundTripIsIdentity() {
        let placements = [
            portraitInLandscape,
            CGRect(x: 0, y: 0.125, width: 1, height: 0.75),
            CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        ]
        let sourceRects = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            CGRect(x: 0.55, y: 0.05, width: 0.44, height: 0.9),
            CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)
        ]
        for place in placements {
            let layout = layout(place)
            for rect in sourceRects {
                let back = layout.inverseRemap(layout.remap(rect, clipID: clipID), clipID: clipID)
                let unwrapped = try? XCTUnwrap(back)
                XCTAssertEqual(unwrapped?.minX ?? -1, rect.minX, accuracy: 1e-12)
                XCTAssertEqual(unwrapped?.minY ?? -1, rect.minY, accuracy: 1e-12)
                XCTAssertEqual(unwrapped?.width ?? -1, rect.width, accuracy: 1e-12)
                XCTAssertEqual(unwrapped?.height ?? -1, rect.height, accuracy: 1e-12)
            }
        }
    }

    /// 黒帯へはみ出した矩形は配置矩形で切り落とされ、結果は必ず [0,1] に収まること。
    func test_inverseRemapClipsRectAgainstLetterbox() {
        let layout = layout(portraitInLandscape)
        // 合成 [0.1, 0.4) は左 0.11875 ぶんが黒帯。素材側は [0, (0.4−0.21875)/0.5625)。
        let clipped = layout.inverseRemap(CGRect(x: 0.1, y: 0, width: 0.3, height: 1),
                                          clipID: clipID)
        XCTAssertEqual(clipped?.minX ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(clipped?.width ?? -1, (0.4 - 0.21875) / 0.5625, accuracy: 1e-12)
        XCTAssertEqual(clipped?.maxX ?? -1, (0.4 - 0.21875) / 0.5625, accuracy: 1e-12)
        // 画面全体を指した矩形は素材全体になる（帯ぶんだけ落ちる）。
        let full = layout.inverseRemap(unit, clipID: clipID)
        XCTAssertEqual(full?.minX ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(full?.width ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(full?.height ?? -1, 1, accuracy: 1e-12)
    }

    /// 完全に黒帯の中／面積 0 の矩形は nil（＝この素材に対応領域が無い）。
    /// 潰れた矩形を返して素材の端を誤検索しないための契約。
    func test_inverseRemapReturnsNilOutsidePlacement() {
        let layout = layout(portraitInLandscape)
        XCTAssertNil(layout.inverseRemap(CGRect(x: 0.02, y: 0, width: 0.1, height: 1),
                                         clipID: clipID), "左の黒帯だけの矩形が nil でない")
        XCTAssertNil(layout.inverseRemap(CGRect(x: 0.8, y: 0, width: 0.2, height: 1),
                                         clipID: clipID), "右の黒帯だけの矩形が nil でない")
        XCTAssertNil(layout.inverseRemap(CGRect(x: 0.5, y: 0.5, width: 0, height: 0.2),
                                         clipID: clipID), "面積 0 の矩形が nil でない")
    }

    // MARK: - 退行防止（先頭クリップ = 単位矩形）

    /// 配置が単位矩形（先頭クリップ・無変換タイムライン）では写像が値を触らないこと。
    /// 前進・逆写像とも**同一の CGRect をそのまま返す**（再計算誤差も入れない）。
    func test_unitPlacementIsBitIdentityInBothDirections() {
        let cases = [unit, CGRect(x: 0.13, y: 0.29, width: 0.37, height: 0.41)]
        for layout in [layout(unit), TimelineRenderLayout.identity] {
            for rect in cases {
                XCTAssertEqual(layout.remap(rect, clipID: clipID), rect,
                               "単位配置で前進写像が値を変えた")
                XCTAssertEqual(layout.inverseRemap(rect, clipID: clipID), rect,
                               "単位配置で逆写像が値を変えた")
            }
            // 未登録クリップ（nil）も単位矩形扱い。
            XCTAssertEqual(layout.inverseRemap(cases[1], clipID: nil), cases[1])
        }
    }

    /// 潰れた配置（幅・高さ 0）は逆写像が定義できないので nil。
    func test_inverseRemapReturnsNilForDegeneratePlacement() {
        let degenerate = layout(CGRect(x: 0.5, y: 0, width: 0, height: 1))
        XCTAssertNil(degenerate.inverseRemap(unit, clipID: clipID))
    }
}
