import XCTest
@testable import MosaicCore

/// `AudioItem.duckingGain`（BGM ダッキング時に掛ける音量）。
final class AudioItemDuckingGainTests: XCTestCase {
    /// 既定値は 1（下げない＝機能追加前の意味）。
    func test_init_defaultsToOne() {
        let item = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2, compositionStart: 0)
        XCTAssertEqual(item.duckingGain, 1)
    }

    /// 0...1 の範囲外は init でクランプされる（`TimelineClip.originalAudioVolume` と同じ規則）。
    func test_init_clampsOutOfRangeValues() {
        XCTAssertEqual(AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2,
                                 compositionStart: 0, duckingGain: -1).duckingGain, 0)
        XCTAssertEqual(AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2,
                                 compositionStart: 0, duckingGain: 2).duckingGain, 1)
    }

    /// NaN は「下げない」(1) に倒す（丸めが素通しになる事故を防ぐ）。
    func test_init_nanFallsBackToOne() {
        let item = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2,
                             compositionStart: 0, duckingGain: .nan)
        XCTAssertEqual(item.duckingGain, 1)
    }

    /// 直接代入でも didSet でクランプされる。
    func test_directAssignment_isClamped() {
        var item = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2, compositionStart: 0)
        item.duckingGain = 5
        XCTAssertEqual(item.duckingGain, 1)
        item.duckingGain = -3
        XCTAssertEqual(item.duckingGain, 0)
    }

    // MARK: - Codable（後方互換）

    /// キーの無い旧下書きは `duckingGain` が 1（機能追加前の意味）で復元される。
    func test_codable_missingKeyDecodesToOne() throws {
        let item = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2, compositionStart: 0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        XCTAssertNotNil(json?.removeValue(forKey: "duckingGain"), "前提: 通常は書き出される")
        let data = try JSONSerialization.data(withJSONObject: json as Any)

        let decoded = try JSONDecoder().decode(AudioItem.self, from: data)
        XCTAssertEqual(decoded.duckingGain, 1)
    }

    /// 往復で `duckingGain` が保たれる。
    func test_codable_roundTripPreservesDuckingGain() throws {
        let item = AudioItem(sourceID: UUID(), sourceStart: 0, sourceEnd: 2,
                             compositionStart: 0, duckingGain: 0.35)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(AudioItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.duckingGain, 0.35, accuracy: 1e-6)
    }
}
