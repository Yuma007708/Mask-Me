import XCTest
@testable import MaskMe

#if canImport(Metal)

/// `ExportSpeed` の速度段マッピング検証。
/// 検出頻度・解像度は加工時間を直接左右するため、段ごとの単調性（速いほど
/// 検出回数が減り解像度も下がる）を固定して意図しない退行を防ぐ。
final class ExportSpeedTests: XCTestCase {
    func testDetectionIntervalIncreasesWithSpeed() {
        // 値が大きいほど検出をスキップする＝速い。maxQuality < balanced < fast。
        XCTAssertEqual(ExportSpeed.maxQuality.detectionInterval, 2)
        XCTAssertLessThan(
            ExportSpeed.maxQuality.detectionInterval,
            ExportSpeed.balanced.detectionInterval
        )
        XCTAssertLessThan(
            ExportSpeed.balanced.detectionInterval,
            ExportSpeed.fast.detectionInterval
        )
    }

    func testDetectionMaxWidthDecreasesWithSpeed() {
        // 速い段ほど検出入力解像度が小さい（推論が速い）。
        XCTAssertEqual(ExportSpeed.maxQuality.detectionMaxWidth, 800)
        XCTAssertGreaterThan(
            ExportSpeed.maxQuality.detectionMaxWidth,
            ExportSpeed.balanced.detectionMaxWidth
        )
        XCTAssertGreaterThan(
            ExportSpeed.balanced.detectionMaxWidth,
            ExportSpeed.fast.detectionMaxWidth
        )
    }

    /// balanced は maxQuality に対し検出コスト（回数×面積）を概ね半分以下に落とす、
    /// という設計意図を固定する回帰ガード。
    func testBalancedRoughlyHalvesDetectionCost() {
        let q = ExportSpeed.maxQuality
        let b = ExportSpeed.balanced
        let qCost = (1.0 / Double(q.detectionInterval)) * q.detectionMaxWidth * q.detectionMaxWidth
        let bCost = (1.0 / Double(b.detectionInterval)) * b.detectionMaxWidth * b.detectionMaxWidth
        XCTAssertLessThan(bCost / qCost, 0.5)
    }
}

#endif
