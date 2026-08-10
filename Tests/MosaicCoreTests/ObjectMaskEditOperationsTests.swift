import CoreGraphics
import XCTest
@testable import MosaicCore

/// `ObjectMaskEditOperations` の契約を固定する。
///
/// 守っているのは **「クリップを割っても、画面に出る矩形が変わらないこと」**。
/// 分割は素材時刻を変えない操作なので、ユーザーから見て何も起きてはいけない。
/// 境界のキーフレームを片側にしか渡さないと、もう片方が clamp に落ちて
/// 正規化 0.25（画面幅の 25%）ずれる——モザイクが顔から外れる実害になる。
final class ObjectMaskEditOperationsTests: XCTestCase {
    private let sourceID = UUID()

    private func rect(x: CGFloat) -> CGRect { CGRect(x: x, y: 0.2, width: 0.1, height: 0.1) }

    private func clip(id: UUID = UUID(), start: Double, end: Double) -> TimelineClip {
        TimelineClip(id: id, sourceID: sourceID, sourceStart: start, sourceEnd: end)
    }

    /// x=0 から x=1 へ 10 秒かけて動くマスク（キーフレーム 3 個）。
    private func movingMask(clipID: UUID) -> ObjectMask {
        ObjectMask(id: UUID(), anchor: .clip(clipID: clipID, sourceID: sourceID),
                   keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: 0)),
                               ObjectMask.Keyframe(sourceTime: 4, rect: rect(x: 0.7)),
                               ObjectMask.Keyframe(sourceTime: 10, rect: rect(x: 1))])!
    }

    /// 分割点 m でクリップを割った結果の (front, back) を取る。
    private func split(_ mask: ObjectMask, at m: Double, isPhoto: Bool = false,
                       clipStart: Double = 0, clipEnd: Double = 10)
        -> (front: ObjectMask, back: ObjectMask)? {
        guard let frontID = mask.anchor.clipID else { return nil }
        let front = clip(id: frontID, start: clipStart, end: m)
        let back = clip(start: m, end: clipEnd)
        let result = ObjectMaskEditOperations.masks(splittingClip: front, into: back,
                                                    atSourceTime: m, isPhoto: isPhoto,
                                                    existing: [mask])
        guard result.count == 2 else { return nil }
        return (result[0], result[1])
    }

    // MARK: - 本丸: 分割で見え方が変わらない

    /// **分割前後で全時刻の矩形が一致する。**
    ///
    /// bit 一致ではない。線分の再パラメータ化は数学的に同値でも浮動小数点では非同値で、
    /// 実測では評価点の約 9% が bit 不一致になる。
    ///
    /// 許容差は**正規化座標の絶対値**で見る。相対（ulp 比）で見ると、補間結果が 0 付近で
    /// 桁落ちしたときだけ 136 ulp まで跳ね上がり、実害の無い差を落としてしまうため
    /// （ランダム 2000 マスク × 180 万評価点で実測）。同じ試行での**絶対差の最大は
    /// 3.4e-16**——1080px 換算で 4e-13 ピクセルであり、目に見えるずれではない。
    private static let splitTolerance: CGFloat = 1e-15

    func test_分割しても全時刻の矩形が一致する() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        // 分割点はグリッド上（1/600 秒の倍数）に取る。
        guard let (front, back) = split(mask, at: 3.0) else { return XCTFail("分割に失敗") }

        for step in 0...600 {
            let time = Double(step) / 60      // 0〜10 秒を 60fps 相当で走査
            let expected = mask.rect(atSourceTime: time)
            // 素材時刻が m 未満なら front クリップ、以上なら back クリップが描く。
            let actual = (time < 3.0 ? front : back).rect(atSourceTime: time)
            XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: Self.splitTolerance,
                           "t=\(time) で x がずれた")
            XCTAssertEqual(actual.size.width, expected.size.width, accuracy: Self.splitTolerance)
        }
    }

    /// 分割点ちょうどにキーフレームがある場合も、**両側に残る**。
    /// 片側にしか渡さないと、もう片方が clamp して位置が飛ぶ。
    func test_分割点ちょうどのキーフレームは両側に残る() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)          // 4 秒ちょうどに x=0.7 がある
        guard let (front, back) = split(mask, at: 4.0) else { return XCTFail("分割に失敗") }

        XCTAssertEqual(front.keyframes.last?.sourceTime, 4)
        XCTAssertEqual(front.keyframes.last?.rect.origin.x, 0.7)
        XCTAssertEqual(back.keyframes.first?.sourceTime, 4)
        XCTAssertEqual(back.keyframes.first?.rect.origin.x, 0.7)
        // 境界の直前・直後で clamp に落ちていない（元と同じ値になる）。
        XCTAssertEqual(front.rect(atSourceTime: 3.9).origin.x,
                       mask.rect(atSourceTime: 3.9).origin.x, accuracy: 1e-12)
        XCTAssertEqual(back.rect(atSourceTime: 4.1).origin.x,
                       mask.rect(atSourceTime: 4.1).origin.x, accuracy: 1e-12)
    }

    /// 分割点がグリッド外でも、食い違うのは幅 1/600 秒未満の窓だけで、
    /// ずれ幅もその窓の移動量に収まる。
    func test_グリッド外の分割点でもずれは1グリッド分の移動量に収まる() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let m = 3.0 + 1.0 / 1400          // グリッド (1/600) に乗らない時刻
        guard let (front, back) = split(mask, at: m) else { return XCTFail("分割に失敗") }

        // [0, 4] 区間の速度は 0.7/4 = 0.175 /秒。1 グリッドぶんの移動量が上限。
        let tolerance = 0.175 / ObjectMask.timeGridPerSecond
        for step in 0...6000 {
            let time = Double(step) / 600
            let expected = mask.rect(atSourceTime: time)
            let actual = (time < m ? front : back).rect(atSourceTime: time)
            XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: CGFloat(tolerance) + 1e-12,
                           "t=\(time) のずれが 1 グリッド分の移動量を超えた")
        }
    }

    // MARK: - id とアンカー

    /// back には**新しい `ObjectMask.id`** を振る。同じ id が 2 個並ぶと
    /// `ForEach` と `firstIndex(where:)` が片方にしか当たらない。
    func test_後半のマスクは新しいidとクリップアンカーを持つ() {
        let clipID = UUID()
        let mask = movingMask(clipID: clipID)
        let front = clip(id: clipID, start: 0, end: 3)
        let back = clip(start: 3, end: 10)
        let result = ObjectMaskEditOperations.masks(splittingClip: front, into: back,
                                                    atSourceTime: 3, isPhoto: false,
                                                    existing: [mask])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, mask.id, "前半は id 据え置き")
        XCTAssertNotEqual(result[1].id, mask.id, "後半に同じ id を振ってはいけない")
        XCTAssertEqual(result[0].anchor.clipID, front.id)
        XCTAssertEqual(result[1].anchor.clipID, back.id)
    }

    /// 別クリップのマスクと `.still` のマスクは素通しする。
    func test_対象外のマスクは素通しする() {
        let otherClip = UUID()
        let other = movingMask(clipID: otherClip)
        guard let still = ObjectMask.single(anchor: .still, rect: rect(x: 0.3)) else {
            return XCTFail("生成に失敗")
        }
        let front = clip(start: 0, end: 3)
        let back = clip(start: 3, end: 10)
        let result = ObjectMaskEditOperations.masks(splittingClip: front, into: back,
                                                    atSourceTime: 3, isPhoto: false,
                                                    existing: [other, still])
        XCTAssertEqual(result, [other, still])
    }

    // MARK: - 写真クリップ

    /// 写真は割らない。素材時刻が必ず 0 へ丸められるので、`m` で割ると
    /// 後半のキーフレームが**絶対に引かれなくなる**。
    func test_写真クリップは前後どちらにも時刻0のキーフレームを配る() {
        let clipID = UUID()
        let mask = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                     rect: rect(x: 0.42))!
        guard let (front, back) = split(mask, at: 1.5, isPhoto: true, clipEnd: 3) else {
            return XCTFail("分割に失敗")
        }
        for mask in [front, back] {
            XCTAssertEqual(mask.keyframes.count, 1)
            XCTAssertEqual(mask.keyframes.first?.sourceTime, 0)
            XCTAssertEqual(mask.rect(atSourceTime: 0).origin.x, 0.42)
        }
        XCTAssertNotEqual(front.id, back.id)
    }

    // MARK: - 削除

    func test_クリップ削除でそのクリップのマスクだけ消える() {
        let doomed = UUID()
        let survivor = UUID()
        let masks = [movingMask(clipID: doomed), movingMask(clipID: survivor)]
        let result = ObjectMaskEditOperations.masks(removingClipID: doomed, from: masks)
        XCTAssertEqual(result.map(\.anchor.clipID), [survivor])
    }

    // MARK: - 旧データの移行

    /// 旧 `manualRects` は**全クリップへ**配る。先頭だけに付けると、3 クリップ構成の
    /// 下書きを再開したときクリップ 2・3 のモザイクが消える（検出の退行）。
    func test_旧矩形は全クリップへ配られる() {
        let clips = [clip(start: 0, end: 3), clip(start: 3, end: 6), clip(start: 6, end: 9)]
        let times = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.sourceStart) })
        let result = ObjectMaskEditOperations.migrated(manualRects: [rect(x: 0.1), rect(x: 0.5)],
                                                       clips: clips, sourceTimes: times)
        XCTAssertEqual(result.count, 6, "3 クリップ × 矩形 2 個")
        XCTAssertEqual(Set(result.compactMap(\.anchor.clipID)), Set(clips.map(\.id)))
        // キーフレーム 1 個 = 全時刻で同じ矩形（旧仕様の「全フレーム適用」と一致）。
        for mask in result {
            XCTAssertEqual(mask.keyframes.count, 1)
            XCTAssertEqual(mask.rect(atSourceTime: -5), mask.rect(atSourceTime: 1e6))
        }
    }

    /// 素材時刻が渡されていないクリップには配らない（写真の 0 丸めを呼び出し側に強制する）。
    func test_素材時刻が無いクリップには配らない() {
        let clips = [clip(start: 0, end: 3), clip(start: 3, end: 6)]
        let result = ObjectMaskEditOperations.migrated(manualRects: [rect(x: 0.1)], clips: clips,
                                                       sourceTimes: [clips[0].id: 0])
        XCTAssertEqual(result.map(\.anchor.clipID), [clips[0].id])
    }

    // MARK: - トランジションの重なり

    /// 重なり区間では**両側のマスクを描く**。片側に絞ると、旧 `ManualRegion`
    /// （常に全フレームへ出ていた）より退行する＝もう片方の物体が素で映る。
    func test_重なり区間では両側の矩形が残る() {
        let target = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        for kind in TransitionKind.allCases {
            let outgoing = kind.visibleRect(target, progress: 0.5, side: .outgoing)
            let incoming = kind.visibleRect(target, progress: 0.5, side: .incoming)
            // fadeToBlack の中間は黒ホールドで両側とも不可視。それ以外は少なくとも片方が残る。
            if kind == .fadeToBlack {
                XCTAssertNil(outgoing)
                XCTAssertNil(incoming)
            } else {
                XCTAssertTrue(outgoing != nil || incoming != nil, "\(kind) で両側とも消えた")
            }
        }
    }

    /// ワイプ境界を跨ぐ矩形は**切らずに丸ごと残す**（過剰適用へ倒す）。
    /// 切ると、はみ出したぶんの物体が素で出る。
    func test_ワイプ境界を跨ぐ矩形は切られない() {
        let straddling = CGRect(x: 0.4, y: 0, width: 0.2, height: 1)
        let result = TransitionKind.wipeLeft.visibleRect(straddling, progress: 0.5, side: .incoming)
        XCTAssertEqual(result?.width, 0.2, "矩形が切られた")
    }

    /// 完全に不可視な側は nil（モザイクを描かない）。
    func test_不可視の側は矩形を返さない() {
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertNil(TransitionKind.crossfade.visibleRect(rect, progress: 1, side: .outgoing))
    }

    func test_静止画の移行はstillアンカーになる() {
        let result = ObjectMaskEditOperations.migratedStill(manualRects: [rect(x: 0.1)])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].anchor.isStill)
        XCTAssertEqual(result[0].keyframes.first?.sourceTime, 0)
    }
}
