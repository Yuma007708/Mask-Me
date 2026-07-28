import Foundation
import XCTest
@testable import MosaicCore

final class ExportStorageCheckTests: XCTestCase {
    /// 素直なケース: 60 秒 × (8Mbps + 128kbps) / 8 × 1.3 ≒ 79.2MB。
    func test_estimatedBytesUsesBitrateAndHeadroom() {
        let bytes = ExportStorageCheck.estimatedBytes(durationSeconds: 60,
                                                      videoBitsPerSecond: 8_000_000,
                                                      headroom: 1.3,
                                                      floorBytes: 0)
        let expected = 60.0 * (8_000_000 + 128_000) / 8 * 1.3
        XCTAssertEqual(Double(bytes), expected, accuracy: 1.0)
    }

    /// headroom を上げると見積もりも増えること（単調性）。
    func test_estimatedBytesGrowsWithHeadroom() {
        let low = ExportStorageCheck.estimatedBytes(durationSeconds: 60, videoBitsPerSecond: 8_000_000,
                                                    headroom: 1.0, floorBytes: 0)
        let high = ExportStorageCheck.estimatedBytes(durationSeconds: 60, videoBitsPerSecond: 8_000_000,
                                                     headroom: 2.0, floorBytes: 0)
        XCTAssertGreaterThan(high, low)
    }

    /// 小さい見積もりは floorBytes まで持ち上げられること（境界ちょうども含む）。
    func test_estimatedBytesRespectsFloor() {
        let floor: Int64 = 50 * 1024 * 1024
        XCTAssertEqual(ExportStorageCheck.estimatedBytes(durationSeconds: 0.1,
                                                         videoBitsPerSecond: 1_000,
                                                         floorBytes: floor), floor)
        // 下限が 0 なら持ち上げない。
        XCTAssertLessThan(ExportStorageCheck.estimatedBytes(durationSeconds: 0.1,
                                                            videoBitsPerSecond: 1_000,
                                                            floorBytes: 0), floor)
        // 負の下限は 0 として扱う（負のバイト数を返さない）。
        XCTAssertGreaterThanOrEqual(ExportStorageCheck.estimatedBytes(durationSeconds: 0,
                                                                      videoBitsPerSecond: 0,
                                                                      floorBytes: -100), 0)
    }

    /// 非有限・負・0 の入力は「寄与なし」に倒し、下限へ落ちること（クラッシュしない）。
    func test_estimatedBytesHandlesNonFiniteAndNegativeInputs() {
        struct Input {
            let duration: Double
            let video: Double
            let audio: Double
        }
        let floor: Int64 = 1024
        let cases = [
            Input(duration: .nan, video: 8_000_000, audio: 128_000),
            Input(duration: .infinity, video: 8_000_000, audio: 128_000),
            Input(duration: -10, video: 8_000_000, audio: 128_000),
            Input(duration: 0, video: 8_000_000, audio: 128_000),
            Input(duration: 60, video: .nan, audio: 0),
            Input(duration: 60, video: .infinity, audio: .infinity),
            Input(duration: 60, video: -8_000_000, audio: -128_000),
            Input(duration: 60, video: 0, audio: 0)
        ]
        for input in cases {
            let bytes = ExportStorageCheck.estimatedBytes(durationSeconds: input.duration,
                                                          videoBitsPerSecond: input.video,
                                                          audioBitsPerSecond: input.audio,
                                                          floorBytes: floor)
            XCTAssertEqual(bytes, floor,
                           "duration=\(input.duration) video=\(input.video) audio=\(input.audio)")
        }
    }

    /// 片方だけ不正な場合は、有効な方の寄与だけが残ること
    /// （映像ビットレートが取れない素材でも音声ぶんは見積もる）。
    func test_estimatedBytesKeepsValidComponentOnly() {
        let bytes = ExportStorageCheck.estimatedBytes(durationSeconds: 60,
                                                      videoBitsPerSecond: .nan,
                                                      audioBitsPerSecond: 128_000,
                                                      headroom: 1.0,
                                                      floorBytes: 0)
        XCTAssertEqual(Double(bytes), 60.0 * 128_000 / 8, accuracy: 1.0)
    }

    /// headroom が 1 未満・非有限のときは 1.0 に倒す（見積もりを縮めない）。
    func test_estimatedBytesClampsHeadroom() {
        let base = ExportStorageCheck.estimatedBytes(durationSeconds: 60, videoBitsPerSecond: 8_000_000,
                                                     headroom: 1.0, floorBytes: 0)
        for headroom in [0.0, 0.5, -3.0, Double.nan, -Double.infinity] {
            XCTAssertEqual(ExportStorageCheck.estimatedBytes(durationSeconds: 60,
                                                             videoBitsPerSecond: 8_000_000,
                                                             headroom: headroom,
                                                             floorBytes: 0),
                           base, "headroom=\(headroom)")
        }
        // +∞ の headroom は「有限でない」ので 1.0 に倒れる（Int64 変換のトラップも起きない）。
        XCTAssertEqual(ExportStorageCheck.estimatedBytes(durationSeconds: 60,
                                                         videoBitsPerSecond: 8_000_000,
                                                         headroom: .infinity,
                                                         floorBytes: 0), base)
    }

    /// 極端に大きい入力でも Int64 変換でトラップせず、上限で止まること。
    func test_estimatedBytesSaturatesInsteadOfTrapping() {
        let bytes = ExportStorageCheck.estimatedBytes(durationSeconds: 1e18,
                                                      videoBitsPerSecond: 1e18,
                                                      floorBytes: 0)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThanOrEqual(bytes, Int64.max)
    }

    /// 空き容量の比較は「以上」で成立（境界ちょうどは OK）。
    func test_hasEnoughSpaceBoundary() {
        XCTAssertTrue(ExportStorageCheck.hasEnoughSpace(requiredBytes: 100, availableBytes: 100))
        XCTAssertTrue(ExportStorageCheck.hasEnoughSpace(requiredBytes: 100, availableBytes: 101))
        XCTAssertFalse(ExportStorageCheck.hasEnoughSpace(requiredBytes: 100, availableBytes: 99))
    }

    /// 空き容量が負（取得失敗をそのまま渡された等）は安全側に倒して false。
    /// 必要量が負・0 は「要らない」なので空きが 0 でも true。
    func test_hasEnoughSpaceEdgeCases() {
        XCTAssertFalse(ExportStorageCheck.hasEnoughSpace(requiredBytes: 0, availableBytes: -1))
        XCTAssertFalse(ExportStorageCheck.hasEnoughSpace(requiredBytes: -1, availableBytes: -1))
        XCTAssertTrue(ExportStorageCheck.hasEnoughSpace(requiredBytes: 0, availableBytes: 0))
        XCTAssertTrue(ExportStorageCheck.hasEnoughSpace(requiredBytes: -100, availableBytes: 0))
    }
}
