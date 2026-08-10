import CoreGraphics
import XCTest
@testable import MosaicCore

/// `TimelineRenderLayout.inverseRemap(_ sets:clipID:)`（顔ランドマークの逆写像）の契約。
///
/// **なぜこの逆写像が要るか**: プレビューのライブ検出は `AVVideoComposition` を装着した
/// **合成フレーム**（レターボックス込み）を見ている。その座標をそのまま素材キーで
/// 検出キャッシュへ書くと、描画・書き出しで `remap` がもう一度掛かって二重にずれ、
/// 顔が素通しになる（このアプリで最も重い種類のバグ）。
final class RenderLayoutInverseRemapTests: XCTestCase {
    private func face(cx: Float, cy: Float, size: Float = 0.1) -> FaceLandmarkSet {
        let half = size / 2
        return FaceLandmarkSet(points: [
            FaceLandmark(x: cx - half, y: cy - half, z: 0),
            FaceLandmark(x: cx + half, y: cy - half, z: 0),
            FaceLandmark(x: cx + half, y: cy + half, z: 0),
            FaceLandmark(x: cx - half, y: cy + half, z: 0)
        ], confidence: 0.9)
    }

    private func assertClose(_ lhs: FaceLandmarkSet, _ rhs: FaceLandmarkSet,
                             accuracy: Float = 1e-5, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.points.count, rhs.points.count, message, file: file, line: line)
        for (a, b) in zip(lhs.points, rhs.points) {
            XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
            XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
        }
    }

    /// レターボックス配置で逆写像が「合成 → 素材」の正しい値になること（数値を直に固定）。
    func test_inverseRemapMapsCompositionCoordinatesBackToSource() {
        let clipID = UUID()
        let place = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let layout = TimelineRenderLayout(placements: [clipID: place])
        // 合成 x=0.45 は、幅 0.5・左端 0.25 の帯の中では素材 x=(0.45-0.25)/0.5=0.4。
        let inversed = layout.inverseRemap([face(cx: 0.45, cy: 0.5, size: 0.1)], clipID: clipID)
        XCTAssertEqual(inversed[0].points[0].x, 0.4 - 0.05 / 0.5, accuracy: 1e-5)
        XCTAssertEqual(inversed[0].points[0].y, 0.45, accuracy: 1e-5, "縦は等倍のはず")
    }

    /// `remap` → `inverseRemap` の往復が恒等であること（顔位置の二重写像を禁じる番人）。
    func test_remapThenInverseRemapIsIdentity() {
        let clipID = UUID()
        for place in [CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
                      CGRect(x: 0, y: 0.125, width: 1, height: 0.75),
                      CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)] {
            let layout = TimelineRenderLayout(placements: [clipID: place])
            let original = [face(cx: 0.3, cy: 0.7, size: 0.2), face(cx: 0.8, cy: 0.2, size: 0.05)]
            let roundTripped = layout.inverseRemap(layout.remap(original, clipID: clipID),
                                                   clipID: clipID)
            XCTAssertEqual(roundTripped.count, original.count)
            for (got, want) in zip(roundTripped, original) {
                assertClose(got, want, "remap→inverseRemap の往復が恒等でない place=\(place)")
            }
        }
    }

    /// `inverseRemap` → `remap` の往復も恒等であること（逆向き）。
    func test_inverseRemapThenRemapIsIdentity() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(placements: [
            clipID: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        ])
        let composed = [face(cx: 0.5, cy: 0.5, size: 0.1)]
        let roundTripped = layout.remap(layout.inverseRemap(composed, clipID: clipID),
                                        clipID: clipID)
        assertClose(roundTripped[0], composed[0])
    }

    /// 全面配置（恒等レイアウト・未登録クリップ・単位矩形の明示登録）では値を触らないこと。
    /// 単一クリップ・無変換の従来挙動を一切変えないための番人。
    func test_inverseRemapLeavesValuesUntouchedForFullFramePlacement() {
        let clipID = UUID()
        let original = [face(cx: 0.33, cy: 0.66, size: 0.17)]

        XCTAssertEqual(TimelineRenderLayout.identity.inverseRemap(original, clipID: clipID),
                       original, "恒等レイアウトで値が変化した")
        XCTAssertEqual(TimelineRenderLayout(placements: [:]).inverseRemap(original, clipID: nil),
                       original, "clipID=nil（写像不能）で値が変化した")
        let unit = TimelineRenderLayout(placements: [clipID: TimelineRenderLayout.unitRect])
        XCTAssertEqual(unit.inverseRemap(original, clipID: clipID), original,
                       "単位矩形の明示登録で値が変化した")
    }

    /// **黒帯へのはみ出しを切り取らない**こと。顔のランドマークは輪郭より外へ出ることが
    /// あり、切り取ると顔が痩せてモザイクが小さくなる（＝露出が増える方向）。
    /// 矩形版 `inverseRemap(_ rect:clipID:)` と意図的に挙動を変えている点の固定。
    func test_inverseRemapDoesNotClipLandmarksOutsidePlacement() {
        let clipID = UUID()
        let place = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let layout = TimelineRenderLayout(placements: [clipID: place])
        // 合成 x=0.20 は黒帯の中（配置は 0.25〜0.75）。素材座標では負値になる。
        let inversed = layout.inverseRemap([face(cx: 0.20, cy: 0.5, size: 0.0)], clipID: clipID)
        XCTAssertEqual(inversed.count, 1, "はみ出した顔を捨ててはならない")
        XCTAssertEqual(inversed[0].points[0].x, -0.1, accuracy: 1e-5,
                       "[0,1] へクランプ・切り取りをしてはならない")
    }

    /// 面積 0 の配置は逆写像が定義できない。値をそのまま返す（顔を失わない側へ倒す）。
    func test_inverseRemapFallsBackForDegeneratePlacement() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(placements: [
            clipID: CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        ])
        let original = [face(cx: 0.5, cy: 0.5)]
        XCTAssertEqual(layout.inverseRemap(original, clipID: clipID), original)
    }

    /// 件数と順序を変えないこと（呼び出し側が `signatures` と添字で対応させている）。
    func test_inverseRemapPreservesCountAndOrder() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(placements: [
            clipID: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        ])
        let original = [face(cx: 0.2, cy: 0.2), face(cx: 0.5, cy: 0.5), face(cx: 0.8, cy: 0.8)]
        let inversed = layout.inverseRemap(original, clipID: clipID)
        XCTAssertEqual(inversed.count, 3)
        XCTAssertTrue(inversed[0].points[0].x < inversed[1].points[0].x)
        XCTAssertTrue(inversed[1].points[0].x < inversed[2].points[0].x)
        XCTAssertEqual(inversed[1].confidence, original[1].confidence)
    }
}
