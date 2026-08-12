import MosaicCore
import XCTest
@testable import MaskMe

/// レイヤー段の器（`TimelineMetrics.layerViewportHeight`）の番人。
///
/// **守りたいのは「下にまだ段がある」ことが画面で分かること。**
/// 器の高さがちょうど 2 段ぶん（`layerRowHeight * 2 + trackSpacing`）だと、
/// 下端が段の切れ目と一致して**縦に払えることに気づく手がかりが画面から消える**。
/// 実際そうなっていて、実装済みの「文字・ステッカー」の段が無いのと同じ状態だった。
///
/// 見た目そのものは目で見るしかないが、「頭が覗く高さになっているか」
/// 「段がはみ出していて縦スクロールが要る状態か」は数字で固定できる。
final class TimelineLayerViewportTests: XCTestCase {
    private var twoRows: CGFloat {
        TimelineMetrics.layerRowHeight * 2 + TimelineMetrics.trackSpacing
    }

    /// 器は 2 段ぴったりではなく、3 段目の頭が覗く高さであること。
    func test_器は2段ぴったりではなく次の段の頭が覗く() {
        let peek = TimelineMetrics.layerViewportHeight - twoRows
        XCTAssertGreaterThanOrEqual(peek, 8,
                                    "3 段目の頭が覗いていない（縦に払えることに気づけない）。"
                                    + " 器=\(TimelineMetrics.layerViewportHeight) 2段=\(twoRows)")
    }

    /// **広げすぎない**こと。段 1 本ぶん以上広げるとプレビューがそのぶん縮む
    /// （器の doc: 段は今後も増えるので、段数ぶんに広げてはいけない）。
    func test_器を段まるごとぶん広げていない() {
        let peek = TimelineMetrics.layerViewportHeight - twoRows
        XCTAssertLessThan(peek, TimelineMetrics.layerRowHeight,
                          "3 段目をまるごと見せている（プレビューが段 1 本ぶん縮む）")
    }

    /// 段の総高さが器より高い＝縦スクロールが成立する状態であること。
    /// ここが偽になると、そもそも払っても動かない。
    func test_段は器からはみ出していて縦に送れる() {
        let viewport = TimelineLayerViewport(
            contentHeight: TimelineLayerScrollMath.contentHeight(
                rowHeights: TimelineLayerRowKind.allCases.map { _ in
                    Double(TimelineMetrics.layerRowHeight)
                },
                spacing: Double(TimelineMetrics.trackSpacing)),
            visibleHeight: Double(TimelineMetrics.layerViewportHeight))
        XCTAssertGreaterThan(viewport.maximumOffset, 0,
                             "段が器に収まっていて縦送りが無効（段数か高さの取り違え）")
    }

    /// 覗かせたぶん、縦に送れる量は減る。**送り切れば 3 段目が全部見える**こと
    /// （覗かせただけで最後まで辿れない、という状態にしない）。
    func test_送り切れば3段目が最後まで見える() {
        let rows = TimelineLayerRowKind.allCases.count
        let contentHeight = TimelineLayerScrollMath.contentHeight(
            rowHeights: (0..<rows).map { _ in Double(TimelineMetrics.layerRowHeight) },
            spacing: Double(TimelineMetrics.trackSpacing))
        let viewport = TimelineLayerViewport(
            contentHeight: contentHeight,
            visibleHeight: Double(TimelineMetrics.layerViewportHeight))
        // 最大まで送った状態で、器の下端が中身の下端に一致する。
        XCTAssertEqual(viewport.maximumOffset + Double(TimelineMetrics.layerViewportHeight),
                       contentHeight, accuracy: 0.001,
                       "送り切っても中身の下端に届かない")
    }
}
