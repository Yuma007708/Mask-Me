import CoreGraphics
import Foundation
import XCTest
@testable import MosaicCore

/// `TimelineState.crop`（出力枠のクロップ）の状態としての契約。
///
/// **この機能で壊れると事故になるのは「クロップを設定しただけで保存済みのマスク・
/// テキストの座標が書き換わる」ことである**（`TimelineStateAspectRatio` と同じ理由:
/// 比率を戻したときに元へ戻らない不可逆な二重変換になる）。
final class TimelineStateCropTests: XCTestCase {
    // MARK: - 既定値

    func test_既定はクロップなし() {
        XCTAssertEqual(TimelineState().crop, .full)
    }

    // MARK: - test_クロップを設定してもマスクとテキストの保存値が変わらない

    /// **これが契約そのもの。**
    ///
    /// 物体マスク（`ObjectMask`）は `TimelineState` の直下には無く、上位層（アプリ側の
    /// モデル）が保持する `[ObjectMask]` として渡り歩く値型なので、ここでは
    /// `TimelineState` が実際に保持しているフィールド（`clips` / `applyRanges` /
    /// `transitions` / `sources` / `audioItems` / `clipAudioMuteRanges` /
    /// `clipDuckRanges` / `textItems`）が `settingCrop` の前後で**1 つも変わらない**
    /// （＝ `crop` 以外に触っていない）ことを直接固定する。これは「物体マスク・テキストの
    /// 保存値を変えない」という契約より強い主張（`TimelineState` が持つもの全部）である。
    func test_クロップを設定してもマスクとテキストの保存値が変わらない() throws {
        let clipID = UUID()
        let sourceID = UUID()
        let clip = TimelineClip(id: clipID, sourceID: sourceID, sourceStart: 0, sourceEnd: 4)
        let text = TextItem(text: "hello", compositionStart: 0, duration: 1,
                            center: NormalizedPoint(x: 0.5, y: 0.5))
        let source = TimelineSource(id: sourceID, kind: .video)

        var state = TimelineState(clips: [clip], sources: [sourceID: source])
        state.textItems = [text]
        let before = state

        let changed = state.settingCrop(CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))

        XCTAssertEqual(changed.clips, before.clips)
        XCTAssertEqual(changed.applyRanges, before.applyRanges)
        XCTAssertEqual(changed.transitions, before.transitions)
        XCTAssertEqual(changed.sources, before.sources)
        XCTAssertEqual(changed.audioItems, before.audioItems)
        XCTAssertEqual(changed.clipAudioMuteRanges, before.clipAudioMuteRanges)
        XCTAssertEqual(changed.clipDuckRanges, before.clipDuckRanges)
        XCTAssertEqual(changed.textItems, before.textItems)
        XCTAssertEqual(changed.aspectRatio, before.aspectRatio)
        XCTAssertEqual(changed.crop, CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        XCTAssertEqual(before.crop, .full)
    }

    // MARK: - test_クロップは往復で元に戻る

    func test_クロップは往復で元に戻る() {
        let state = TimelineState()
        let cropped = state.settingCrop(CropRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)))
        XCTAssertNotEqual(cropped, state)
        let back = cropped.settingCrop(.full)
        XCTAssertEqual(back, state, "`.full` へ戻すと元の状態と一致するはず（不可逆な変換をしていない）")
    }

    /// 他の編集操作と同じ契約: 同じ値なら self（アイデンティティ）を返す。
    func test_同じ値の再設定はselfを返す() {
        let state = TimelineState()
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let changed = state.settingCrop(crop)
        XCTAssertEqual(changed.settingCrop(crop), changed)
    }

    // MARK: - test_クロップキーの無い旧下書きが開ける

    func test_クロップキーの無い旧下書きが開ける() throws {
        let data = try JSONEncoder().encode(TimelineState())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "crop")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let state = try JSONDecoder().decode(TimelineState.self, from: legacy)
        XCTAssertEqual(state.crop, .full)
    }

    /// スキーマ版は上げていない（`crop` はトップレベルのキーが増えただけ）。
    func test_スキーマ版数は上げていない() {
        XCTAssertEqual(TimelineState.currentSchemaVersion, 7)
    }

    // MARK: - test_壊れたクロップ値で下書きが丸ごと開けなくならない

    func test_壊れたクロップ値で下書きが丸ごと開けなくならない() throws {
        let data = try JSONEncoder().encode(TimelineState())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let brokenCropPayloads: [Any] = [
            "not-a-rect",
            ["rect": "x"],
            ["rect": ["origin": ["x": -5, "y": -5], "size": ["width": 999, "height": 999]]]
        ]
        for payload in brokenCropPayloads {
            object["crop"] = payload
            let broken = try JSONSerialization.data(withJSONObject: object)
            let state = try JSONDecoder().decode(TimelineState.self, from: broken)
            XCTAssertEqual(state.crop, .full, "壊れたクロップ値は `.full` へ倒れるはず: \(payload)")
            // 下書き全体（他のフィールド）が失われていないことも確認する。
            XCTAssertEqual(state.clips.count, TimelineState().clips.count)
        }
    }

    // MARK: - 往復（Codable）

    func test_正常なクロップは保存復元で保たれる() throws {
        let crop = CropRect(rect: CGRect(x: 0.12, y: 0.34, width: 0.5, height: 0.44))
        let state = TimelineState().settingCrop(crop)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(TimelineState.self, from: data)
        XCTAssertEqual(restored.crop, crop)
    }

    // MARK: - validate()

    func test_validateは正常なクロップを通す() {
        let state = TimelineState().settingCrop(CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        XCTAssertTrue(state.validate())
    }
}
