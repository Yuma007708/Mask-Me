import CoreGraphics
import XCTest
@testable import MosaicCore

/// クリップ変形（`ClipTransform`）・切り抜き（`CropRect`）のように「見えている素材の範囲を
/// 変える」操作と、検出キャッシュの「そのバケットは検出済み」判定の噛み合わせを固定する。
///
/// **塞いでいる穴（プライバシー事故）**: 拡大した状態で再生するとライブ検出は
/// フレーム外の顔を見られない。それでもそのバケットには「検出済み」エントリが入るため、
/// 縮小に戻しても `hasEntry` が真で二度と検出されず、端にいた顔が素通しのまま固定される。
///
/// 対策は「記録済み可視領域 ⊇ 要求可視領域」のときだけ検出済みとみなすこと。
/// 拡大（可視領域が縮む）では再検出が走らず、縮小（可視領域が広がる）で走る。
final class DetectionCoverageTests: XCTestCase {

    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: - 可視領域（ClipTransform）

    /// 拡大すると素材はフレーム外へはみ出し、見えている範囲は**狭まる**。
    /// 縮小すると素材は枠内へ収まり、見えている範囲は**広がる**（上限は素材全体）。
    func test_可視領域は拡大すると狭まり縮小すると広がる() {
        let base = unit
        var previousArea = Double.infinity
        for scale in [0.25, 0.5, 1.0, 2.0, 4.0] {
            let visible = ClipTransform(scale: scale).visibleSourceRect(basePlacement: base)
            let area = Double(visible.width * visible.height)
            XCTAssertLessThanOrEqual(area, previousArea + 1e-12,
                                     "scale=\(scale) で可視領域が広がっている（単調性が壊れている）")
            XCTAssertLessThanOrEqual(area, 1.0 + 1e-12, "可視領域が素材全体を超えている")
            previousArea = area
        }
        // 具体値: scale=2 なら配置矩形は出力枠の 2 倍、中心に置かれるので
        // 縦横それぞれ中央 1/2 だけが見えている（面積 1/4）。
        let doubled = ClipTransform(scale: 2).visibleSourceRect(basePlacement: base)
        XCTAssertEqual(Double(doubled.minX), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Double(doubled.width), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Double(doubled.minY), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Double(doubled.height), 0.5, accuracy: 1e-9)
        // scale<1 は枠内に収まるので素材は全部見えている。
        XCTAssertEqual(ClipTransform(scale: 0.5).visibleSourceRect(basePlacement: base), unit)
    }

    /// 無変形なら素材全体が見えている（＝従来どおり被覆判定が常に成立する）。
    func test_無変形の可視領域は素材全体() {
        XCTAssertEqual(ClipTransform.identity.visibleSourceRect(basePlacement: unit), unit)
        // レターボックス配置（出力枠の一部を占める）でも、素材自体は全部見えている。
        let letterboxed = CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1)
        XCTAssertEqual(ClipTransform.identity.visibleSourceRect(basePlacement: letterboxed), unit)
        // 平行移動だけなら（枠内に収まる範囲では）はみ出さない。
        XCTAssertEqual(ClipTransform(scale: 1, offset: .zero).visibleSourceRect(basePlacement: unit), unit)
    }

    /// 平行移動で枠外へ押し出すと、押し出した側が見えなくなる。
    func test_平行移動は押し出した側の可視領域を削る() {
        let visible = ClipTransform(scale: 1, offset: CGPoint(x: 0.25, y: 0))
            .visibleSourceRect(basePlacement: unit)
        // 配置矩形は x:[0.25, 1.25] → 見えるのは素材の左 3/4。
        XCTAssertEqual(Double(visible.minX), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(visible.width), 0.75, accuracy: 1e-9)
        XCTAssertEqual(Double(visible.height), 1, accuracy: 1e-9)
    }

    /// 完全に枠外へ出たら可視領域は空（＝何も見えていないので検出しても得るものが無い）。
    func test_枠外へ出たクリップの可視領域は空() {
        let visible = ClipTransform(scale: 1, offset: CGPoint(x: 1.0, y: 0))
            .visibleSourceRect(basePlacement: unit)
        XCTAssertTrue(visible.isEmpty, "枠外なのに可視領域が空でない")
    }

    // MARK: - 被覆判定（DetectionCoverage）

    /// 同じ領域どうしは被覆とみなす（浮動小数の再計算誤差で無限に再検出しないこと）。
    /// 許容は `DetectionCoverage.tolerance`（1e-9）。
    func test_被覆判定は同一領域を被覆とみなす() {
        let rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertTrue(DetectionCoverage.covers(recorded: rect, requested: rect))
        XCTAssertTrue(DetectionCoverage.covers(recorded: unit, requested: unit))
        // 許容内（1e-12）のズレは被覆とみなす。
        let jittered = CGRect(x: 0.25 - 1e-12, y: 0.25, width: 0.5 + 1e-12, height: 0.5)
        XCTAssertTrue(DetectionCoverage.covers(recorded: rect, requested: jittered),
                      "浮動小数の再計算誤差で毎フレーム再検出になる")
        // 真に広い記録は狭い要求を被覆する（拡大方向では再検出しない）。
        XCTAssertTrue(DetectionCoverage.covers(recorded: unit, requested: rect))
    }

    /// **安全側**: わずか（1e-6）でも広い領域を要求されたら被覆とみなさない。
    /// ここを緩めると、縮小して新しく見えるようになった端の顔が素通しのまま固定される。
    func test_わずかに広い要求は被覆されない() {
        let recorded = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let wider = [
            CGRect(x: 0.25 - 1e-6, y: 0.25, width: 0.5, height: 0.5),   // 左へ広い
            CGRect(x: 0.25, y: 0.25 - 1e-6, width: 0.5, height: 0.5),   // 上へ広い
            CGRect(x: 0.25, y: 0.25, width: 0.5 + 1e-6, height: 0.5),   // 右へ広い
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5 + 1e-6)    // 下へ広い
        ]
        for requested in wider {
            XCTAssertFalse(DetectionCoverage.covers(recorded: recorded, requested: requested),
                           "\(requested) が被覆扱いされている（新しく見えた領域が検出されない）")
        }
        // 拡大中に記録した狭い領域は、縮小後の素材全体を被覆しない（これが塞ぐ穴そのもの）。
        XCTAssertFalse(DetectionCoverage.covers(recorded: recorded, requested: unit))
    }

    /// 非有限な領域は判断材料が無いので**被覆しない**側（＝再検出する側）へ倒す。
    func test_非有限な領域は被覆とみなさない() {
        let bad = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)
        XCTAssertFalse(DetectionCoverage.covers(recorded: bad, requested: unit))
        XCTAssertFalse(DetectionCoverage.covers(recorded: unit, requested: bad))
    }

    // MARK: - 検出キャッシュとの結線

    /// 可視領域を伴わない従来の書き込みは「素材全体を検出済み」として扱う（挙動不変）。
    func test_可視領域を伴わない書き込みは全体被覆として扱う() {
        let store = DetectionCacheStore()
        let source = UUID()
        store.store([], sourceID: source, time: 1.0)
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0))
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0, covering: unit))
    }

    /// 拡大中（可視領域が狭い）に書いたエントリは、素材全体を要求されたら未検出扱い。
    func test_狭い可視領域で書いたエントリは全体要求を満たさない() {
        let store = DetectionCacheStore()
        let source = UUID()
        let narrow = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        store.store([], sourceID: source, time: 1.0, visibleRect: narrow)
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0), "エントリ自体は存在する")
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0, covering: narrow))
        XCTAssertFalse(store.hasEntry(sourceID: source, time: 1.0, covering: unit),
                       "縮小後の再検出が走らない（素通しのまま固定される）")
        // さらに拡大した（もっと狭い）要求は満たす＝ピンチのたびに全再走査にならない。
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0,
                                     covering: CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)))
    }

    /// 全体を見て書き直したら被覆も広がる（＝再検出が完了したら止まる）。
    func test_全体を見て書き直すと被覆が広がる() {
        let store = DetectionCacheStore()
        let source = UUID()
        store.store([], sourceID: source, time: 1.0,
                    visibleRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertFalse(store.hasEntry(sourceID: source, time: 1.0, covering: unit))
        store.store([], sourceID: source, time: 1.0, visibleRect: unit)
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0, covering: unit))
    }

    /// `visibleRect` 省略の書き込みは、既存エントリの被覆を**広げない**。
    /// `mergeDetection`（部分検出のマージ）が「全体を見た」と偽ることで、
    /// 狭い可視領域で取りこぼした顔の再検出が止まるのを防ぐ。
    func test_可視領域省略の書き込みは既存の被覆を広げない() {
        let store = DetectionCacheStore()
        let source = UUID()
        let narrow = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        store.store([], sourceID: source, time: 1.0, visibleRect: narrow)
        store.store([], sourceID: source, time: 1.0)
        XCTAssertFalse(store.hasEntry(sourceID: source, time: 1.0, covering: unit),
                       "省略した書き込みが被覆を全体へ広げてしまっている")
    }

    /// 削除は被覆台帳も一緒に捨てる（残ると別素材・再読み込み後に誤って検出済み扱いになる）。
    func test_削除は被覆台帳も捨てる() {
        let store = DetectionCacheStore()
        let source = UUID()
        let narrow = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        store.store([], sourceID: source, time: 1.0, visibleRect: narrow)
        store.removeAll(sourceID: source)
        store.store([], sourceID: source, time: 1.0)
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 1.0, covering: unit),
                      "削除したはずの狭い被覆が残っている")

        store.store([], sourceID: source, time: 2.0, visibleRect: narrow)
        store.removeAll()
        store.store([], sourceID: source, time: 2.0)
        XCTAssertTrue(store.hasEntry(sourceID: source, time: 2.0, covering: unit))
    }
}
