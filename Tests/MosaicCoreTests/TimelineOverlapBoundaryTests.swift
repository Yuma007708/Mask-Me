import XCTest
@testable import MosaicCore

/// S8 レビュー i-1: 重なり区間の**境界の bit 一致**を固定する。
///
/// `Overlap.end` と先行クリップの `ClipSpan.end` は同じ値なので、同じ値を 2 通りに
/// 計算してはならない。旧実装は `Overlap.end = start + duration`（`start` は減算後の acc）で
/// 作っていたため、演算順の違いで 1 ulp ずれた。ずれた時刻では
/// `overlap(at:)` と `sourceLocations(at:).count >= 2` の判定が食い違い、
/// 重なり中なのに片側だけのキャッシュ経路へ落ちる（さらに
/// `shouldDetectPreviewFrame` の重なりガードも外れ、合成済みフレームの検出結果が
/// 素材キーで書かれうる＝検出キャッシュ汚染の理論的な穴）。
final class TimelineOverlapBoundaryTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// クリップ尺とトランジション尺の 1 組。
    private struct OverlapCase {
        let clipA: Double
        let clipB: Double
        let transition: Double
    }

    private func makeMapping(_ testCase: OverlapCase) -> TimelineMapping {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: testCase.clipA)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 0, sourceEnd: testCase.clipB)
        return TimelineMapping(
            clips: [a, b],
            transitions: [a.id: TransitionSpec(kind: .crossfade, duration: testCase.transition)])
    }

    /// `Overlap` の両端が、対応するクリップの `ClipSpan` の端と **bit 一致**すること。
    func test_overlapEndIsBitIdenticalToOutgoingClipSpanEnd() {
        // 旧実装が実際にずれた組み合わせ（A=1.7/B=1.3/D=0.7 など）を含める。
        let cases = [
            OverlapCase(clipA: 4, clipB: 4, transition: 1.0),
            OverlapCase(clipA: 4, clipB: 4, transition: 1.0 / 3.0),
            OverlapCase(clipA: 1.7, clipB: 1.3, transition: 0.7),
            OverlapCase(clipA: 1.8, clipB: 1.3, transition: 0.7),
            OverlapCase(clipA: 2.6, clipB: 1.1, transition: 0.7),
            OverlapCase(clipA: 2.8000000000000003, clipB: 1.1, transition: 0.7),
            OverlapCase(clipA: 2.8000000000000003, clipB: 1.5, transition: 0.7)
        ]
        for testCase in cases {
            let label = "A=\(testCase.clipA) B=\(testCase.clipB) D=\(testCase.transition)"
            let mapping = makeMapping(testCase)
            guard let overlap = mapping.overlaps.first,
                  let outgoing = mapping.clipSpans.first(where: { $0.clip.id == overlap.outgoingClipID }),
                  let incoming = mapping.clipSpans.first(where: { $0.clip.id == overlap.incomingClipID })
            else { return XCTFail("\(label): 重なりが作られていない") }
            XCTAssertEqual(overlap.end.bitPattern, outgoing.end.bitPattern,
                           "\(label): Overlap.end が先行クリップの span 終端と bit 一致しない")
            XCTAssertEqual(overlap.start.bitPattern, incoming.start.bitPattern,
                           "\(label): Overlap.start が後続クリップの span 開始と bit 一致しない")
        }
    }

    /// 重なりの境界を 1 ulp 刻みで掃引し、`overlap(at:)` と
    /// `sourceLocations(at:).count >= 2` の判定が **1 点も食い違わない**こと。
    ///
    /// 旧実装（`end = start + duration`）はこの掃引 34000 点のうち 27 点で食い違った。
    func test_overlapBoundarySweepAgreesWithSourceLocations() {
        func stepped(_ value: Double, ulps: Int) -> Double {
            var result = value
            for _ in 0..<abs(ulps) { result = ulps > 0 ? result.nextUp : result.nextDown }
            return result
        }

        var checked = 0
        var mismatches: [String] = []
        // 2 進で割り切れない尺・D を混ぜて、丸めが効く組み合わせを広く踏む。
        for clipA in stride(from: 0.7, through: 3.1, by: 0.1) {
            for clipB in stride(from: 0.9, through: 2.9, by: 0.2) {
                for transition in [0.1, 0.3, 1.0 / 3.0, 0.7] {
                    let mapping = makeMapping(
                        OverlapCase(clipA: clipA, clipB: clipB, transition: transition))
                    guard let overlap = mapping.overlaps.first else { continue }
                    for boundary in [overlap.start, overlap.end] {
                        for ulps in -8...8 {
                            let time = stepped(boundary, ulps: ulps)
                            checked += 1
                            let byOverlap = mapping.overlap(at: time) != nil
                            let byLocations = mapping.sourceLocations(at: time).count >= 2
                            if byOverlap != byLocations {
                                mismatches.append("A=\(clipA) B=\(clipB) D=\(transition) t=\(time)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3000, "掃引点数が想定より少ない（テストが空回りしている）")
        XCTAssertEqual(mismatches.count, 0,
                       "境界掃引 \(checked) 点中 \(mismatches.count) 点で重なり判定が食い違う: "
                       + mismatches.prefix(5).joined(separator: " / "))
    }

    /// 進行度（progress）の分母が `sourceLocations` と `Overlap.duration` で一致すること。
    /// 分母が別々だと、instruction のランプ（`VideoCompositionFactory` が
    /// `Overlap.duration` を使う）と顔位置の視覚変換がずれる。
    func test_progressDenominatorMatchesOverlapDuration() {
        let testCase = OverlapCase(clipA: 1.7, clipB: 1.3, transition: 0.7)
        let mapping = makeMapping(testCase)
        guard let overlap = mapping.overlaps.first else { return XCTFail("重なりが作られていない") }
        for step in 1...9 {
            let time = overlap.start + overlap.duration * (Double(step) / 10)
            let locations = mapping.sourceLocations(at: time)
            XCTAssertEqual(locations.count, 2, "t=\(time) が重なり区間として扱われていない")
            let expected = (time - overlap.start) / overlap.duration
            XCTAssertEqual(locations[0].progress ?? -1, expected, accuracy: 1e-15)
            XCTAssertEqual(locations[1].progress ?? -1, expected, accuracy: 1e-15)
        }
    }
}
