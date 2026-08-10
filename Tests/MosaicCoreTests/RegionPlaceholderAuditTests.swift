import XCTest
@testable import MosaicCore

/// 暫定矩形（`ObjectMask.isRegionPlaceholder == true`）を外してよいかの判定式を固定する。
///
/// **被覆時刻はすべてリテラル配列で与える**（`t += step` の累算ヘルパは浮動小数誤差で
/// 境界テストが無効になる。前回それで `gapExactlyMaxGap` が守れていなかった）。
final class RegionPlaceholderAuditTests: XCTestCase {
    private let bridgeWindow = 8.0 / 15.0
    private let bucket = 1.0 / 15.0

    // MARK: 1. 拡張列の端追加（真ん中1点だけでは頭・尾が丸ごと穴になる）

    func test_audit_singleCoveredPointInMiddle_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...1, rate: 1, coveredTimes: [0.5],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
    }

    // MARK: 2. 穴の境界（maxSourceGap ちょうど）

    func test_audit_gapExactlyMaxSourceGap_isCovered() {
        // 0, (8/15 の穴), 16/15 — 中間の穴をちょうど bridgeWindow(8/15) にする。
        // rate 2 で composition 側 (gap/rate = 4/15 ≈ 0.267) を余裕を持って満たし、
        // source 側の境界(<=)だけを検査する。
        let covered: [Double] = [0.0, 8.0 / 15.0, 16.0 / 15.0]
        let span = 0...(16.0 / 15.0)
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 2, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertTrue(verdict.isCovered, "境界(maxSourceGap ちょうど)は合格のはず: \(verdict.reason)")
    }

    func test_audit_gapJustOverMaxSourceGap_isNotCovered() {
        let gap = 8.0 / 15.0 + 0.01
        let covered: [Double] = [0.0, gap]
        let span = 0...(gap + 8.0 / 15.0)
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 1, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        if case .gapTooLong(let source, _) = verdict.reason {
            XCTAssertEqual(source, gap, accuracy: 1e-9)
        } else {
            XCTFail("gapTooLong を期待していたが \(verdict.reason)")
        }
    }

    // MARK: 3. rate を挟んだ合成秒縛り

    func test_audit_slowRate_gapFailsInCompositionTime() {
        // source gap 0.3 は maxSourceGap(8/15≈0.533) 未満だが、rate 0.1 だと
        // composition gap = 0.3 / 0.1 = 3.0 で maxCompositionGap(0.5) を超える。
        let covered: [Double] = [0.0, 0.3]
        let span = 0.0...0.35
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 0.1, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
    }

    func test_audit_fastRate_sourceBoundStillBinds() {
        // source gap 0.6 は maxSourceGap(8/15≈0.533) を超える。rate 10 なら
        // composition gap = 0.06 で maxCompositionGap は満たすが、source 側で落ちるはず。
        let covered: [Double] = [0.0, 0.6]
        let span = 0.0...0.65
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 10, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        if case .gapTooLong(let source, _) = verdict.reason {
            XCTAssertEqual(source, 0.6, accuracy: 1e-9)
        } else {
            XCTFail("gapTooLong を期待していたが \(verdict.reason)")
        }
    }

    // MARK: 4. 端の許容（edgeSourceTolerance = 1バケット = 1/15秒）

    func test_audit_headGapOneBucket_isCovered() {
        let covered: [Double] = [bucket, bucket + 0.4, bucket + 0.8]
        let span = 0.0...(bucket + 0.8)
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 1, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertTrue(verdict.isCovered, "先頭1バケットの穴は合格のはず: \(verdict.reason)")
    }

    func test_audit_headGapTwoBuckets_isNotCovered() {
        let headGap = bucket * 2
        let covered: [Double] = [headGap, headGap + 0.4, headGap + 0.8]
        let span = 0.0...(headGap + 0.8)
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 1, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        if case .headUncovered(let source, _) = verdict.reason {
            XCTAssertEqual(source, headGap, accuracy: 1e-9)
        } else {
            XCTFail("headUncovered を期待していたが \(verdict.reason)")
        }
    }

    func test_audit_tailGapTwoBuckets_isNotCovered() {
        let tailGap = bucket * 2
        let end = 1.0
        let covered: [Double] = [0.0, 0.4, end - tailGap]
        let span = 0.0...end
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 1, coveredTimes: covered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        if case .tailUncovered(let source, _) = verdict.reason {
            XCTAssertEqual(source, tailGap, accuracy: 1e-9)
        } else {
            XCTFail("tailUncovered を期待していたが \(verdict.reason)")
        }
    }

    // MARK: 5. rate ガード

    func test_audit_zeroRate_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...10, rate: 0, coveredTimes: [0, 5, 10],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .invalidRate)
    }

    func test_audit_negativeRate_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...10, rate: -1, coveredTimes: [0, 5, 10],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .invalidRate)
    }

    // MARK: 6. span 長ガードは sorted より前

    func test_audit_hugeSpan_failsBeforeTouchingCoveredTimes() {
        let span: ClosedRange<Double> = 0...100_000
        let verdict = RegionPlaceholderAudit.evaluate(
            span: span, rate: 1, coveredTimes: [],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .spanTooLong, "coveredTimes が空でも spanTooLong が先に出るはず")
    }

    // MARK: 7. minCoveredTimes ガード

    func test_audit_oneCoveredTime_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...10, rate: 1, coveredTimes: [5.0],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .tooFewCoveredTimes)
    }

    // MARK: 8. span 外の被覆時刻は無視

    func test_audit_coveredTimesOutsideSpanAreIgnored() {
        // span 外の -5, 20 を混ぜても、span 内は [0.0] だけになり tooFewCoveredTimes で落ちる。
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...10, rate: 1, coveredTimes: [-5.0, 0.0, 20.0],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .tooFewCoveredTimes)
    }

    // MARK: 9. 人物同定

    /// span 0...2、0.4刻みで隙間なく埋めた被覆時刻（gapTooLong に落ちないようにするため。
    /// 境界精度は問わないテストなので `stride` で生成してよい）。
    private var denselyCovered: [Double] {
        Array(stride(from: 0.0, through: 2.0, by: 0.4))
    }

    func test_audit_identityUnconfirmed_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...2, rate: 1, coveredTimes: denselyCovered,
            identityConfirmations: 2, requiresIdentity: true, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .identityUnconfirmed(2))
    }

    func test_audit_identityNotRequired_passesWithoutSignatures() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...2, rate: 1, coveredTimes: denselyCovered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertTrue(verdict.isCovered, "\(verdict.reason)")
    }

    // MARK: 10. アンカー・空区間ガード

    func test_audit_anchorOutsideRect_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 0...2, rate: 1, coveredTimes: denselyCovered,
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: false)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .anchorMismatch)
    }

    func test_audit_emptySpan_isNotCovered() {
        let verdict = RegionPlaceholderAudit.evaluate(
            span: 5...5, rate: 1, coveredTimes: [5.0],
            identityConfirmations: 0, requiresIdentity: false, anchorInsideRect: true)

        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.reason, .emptySpan)
    }
}
