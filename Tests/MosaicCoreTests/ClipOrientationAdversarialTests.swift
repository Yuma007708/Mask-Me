import CoreGraphics
import Foundation
import XCTest
@testable import MosaicCore

/// C（検証・敵対的テスト）: クリップの向き（回転・反転）を壊しにかかる。
///
/// **`ClipOrientationTests` の extension として書いてある。** 本体側の補助
/// （`samplePoints` / `landmarkSet(at:)` / `assertEqual(_:_:_:)`）をそのまま使うのと、
/// extension のメンバーは `type_body_length` に数えられないため。
extension ClipOrientationTests {
    /// **敵対的**: 巨大・小数の `rotation` を持つ下書き。
    ///
    /// `folded(degrees:)` 自体は `Double` を受けて安全に畳むが、`CodingKeys.rotation` は
    /// `Int` としてデコードするため、JSON の数値が Int で表現できない（小数・Int64 超え）
    /// 場合は `container.decodeIfPresent(Int.self, ...)` の時点で throw する可能性がある。
    /// doc は「壊れた値もデコードを失敗させない」と主張しているので、実際に落ちるか確かめる。
    func test_小数のrotationは下書き全体のデコードを壊さない() {
        let json = #"{"rotation":90.5,"isMirrored":true}"#
        XCTAssertNoThrow(
            try JSONDecoder().decode(ClipOrientation.self, from: Data(json.utf8)),
            "rotation が小数だと ClipOrientation のデコードが throw する（doc の主張と矛盾）")
    }

    func test_Int範囲を超える巨大なrotationは下書き全体のデコードを壊さない() {
        let json = #"{"rotation":99999999999999999999,"isMirrored":true}"#
        XCTAssertNoThrow(
            try JSONDecoder().decode(ClipOrientation.self, from: Data(json.utf8)),
            "rotation が Int64 を超えると ClipOrientation のデコードが throw する（doc の主張と矛盾）")
    }

    /// 同じ壊れ方が `TimelineClip` 全体を巻き込むかも確認する
    /// （1 クリップの orientation が壊れているだけで下書き全体が開けなくなる、が最悪の帰結）。
    func test_小数のrotationを持つクリップは下書き全体のデコードを壊さない() {
        let json = """
        {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)",
         "sourceStart":0,"sourceEnd":5,"originalAudioVolume":1,
         "orientation":{"rotation":90.5,"isMirrored":false}}
        """
        XCTAssertNoThrow(
            try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8)),
            "1クリップの orientation が壊れているだけで TimelineClip 全体のデコードが失敗する")
    }

    // MARK: - 編集操作

    /// **敵対的**: 回転→反転を交互に繰り返す長い操作列でも、写像の一致
    /// （ピクセル変換 == 正規化写像）が崩れないか。
    func test_回転と反転を交互に繰り返しても写像の一致が崩れない() {
        var orientation = ClipOrientation.identity
        let source = CGSize(width: 800, height: 450)
        let ops: [(ClipOrientation) -> ClipOrientation] = [
            { $0.rotatedRight() }, { $0.flippedHorizontally() },
            { $0.rotatedRight() }, { $0.flippedHorizontally() },
            { $0.rotatedLeft() }, { $0.flippedHorizontally() },
            { $0.rotatedRight() }, { $0.rotatedRight() }, { $0.flippedHorizontally() }
        ]
        for (step, op) in ops.enumerated() {
            orientation = op(orientation)
            let transform = orientation.transform(sourceSize: source)
            let display = orientation.displaySize(source)
            for point in samplePoints {
                let pixel = CGPoint(x: point.x * source.width, y: point.y * source.height)
                let moved = pixel.applying(transform)
                let normalized = CGPoint(x: moved.x / display.width, y: moved.y / display.height)
                assertEqual(normalized, orientation.map(point),
                           "step \(step) \(orientation) \(point)", accuracy: 1e-9)
            }
            // 逆写像でも往復する。
            for point in samplePoints {
                assertEqual(orientation.inverseMap(orientation.map(point)), point,
                           "step \(step) \(orientation) \(point)")
            }
        }
    }

    /// **敵対的**: 並べ替え（move）は向きを引き継ぎ、他クリップへ漏らさない。
    func test_並べ替えても向きは引き継がれ他クリップへ漏れない() {
        let a = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                             orientation: ClipOrientation(rotation: .right90, isMirrored: true))
        let b = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                             orientation: .identity)
        let c = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                             orientation: ClipOrientation(rotation: .half))
        let moved = TimelineEditOperations.move(clips: [a, b, c], clipID: a.id, toIndex: 2)
        XCTAssertEqual(moved.count, 3)
        // a はどこへ移動しても自分の向きを保つ。
        let movedA = moved.first { $0.id == a.id }
        XCTAssertEqual(movedA?.orientation, a.orientation)
        // b・c は無変更のまま（a の向きが漏れていない）。
        XCTAssertEqual(moved.first { $0.id == b.id }?.orientation, .identity)
        XCTAssertEqual(moved.first { $0.id == c.id }?.orientation, ClipOrientation(rotation: .half))
    }

    /// **敵対的**: 削除しても、残ったクリップの向きは互いに漏れない。
    func test_削除しても残りのクリップの向きは変わらない() {
        let a = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                             orientation: ClipOrientation(rotation: .left90))
        let b = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 5,
                             orientation: ClipOrientation(isMirrored: true))
        let removed = TimelineEditOperations.remove(clips: [a, b], clipID: a.id)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].orientation, b.orientation)
    }

    /// **敵対的**: 出力解像度（先頭クリップ基準）に対する 1920x1080 のレターボックス整合。
    /// 90 度回した先頭クリップの display サイズ・配置矩形・映像変換・モザイク写像が
    /// 全て同じ枠を指すか。
    func test_1920x1080を90度回したときレターボックスとモザイクが両立する() {
        let source = CGSize(width: 1920, height: 1080)
        let clipID = UUID()
        for orientation in allOrientations {
            let display = orientation.displaySize(source)
            // 出力解像度は「向きを掛けた後の先頭クリップサイズ」基準（偶数丸めのみ、ここでは整数なので不変）。
            let renderSize = display
            let placement = AspectFit.placement(of: display, in: renderSize)
            // 縦横比が一致するので配置はレターボックス無し（恒等）のはず。
            XCTAssertEqual(placement, TimelineRenderLayout.unitRect, "\(orientation)")
            let transform = ClipRenderTransform.make(displaySize: source, orientation: orientation,
                                                      placement: placement, renderSize: renderSize)
            let layout = TimelineRenderLayout(placements: [clipID: placement],
                                              orientations: [clipID: orientation])
            for point in samplePoints {
                let pixel = CGPoint(x: point.x * source.width, y: point.y * source.height)
                let moved = pixel.applying(transform)
                let viaPixels = CGPoint(x: moved.x / renderSize.width, y: moved.y / renderSize.height)
                let viaLayout = layout.remap([landmarkSet(at: point)], clipID: clipID)[0].points[0]
                assertEqual(CGPoint(x: CGFloat(viaLayout.x), y: CGFloat(viaLayout.y)),
                           viaPixels, "\(orientation) \(point)", accuracy: 1e-5)
            }
        }
    }

    func test_分割しても向きが引き継がれる() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10,
                                orientation: ClipOrientation(rotation: .left90, isMirrored: true))
        let split = TimelineEditOperations.split(clips: [clip], at: 5)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].orientation, clip.orientation)
        XCTAssertEqual(split[1].orientation, clip.orientation)
    }

    /// **複製しても向きが引き継がれること。**
    ///
    /// 複製と向きは別々の機能として実装されたため、マージした時点では
    /// `TimelineEditOperations.duplicate` が `orientation` を渡しておらず、
    /// 回したクリップを複製すると**複製先だけ向きが戻っていた**
    /// （分割は引き継いでいたので、複製だけが漏れていた）。
    /// git は競合を出さないので、ここが唯一の番人になる。
    func test_複製しても向きが引き継がれる() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10,
                                orientation: ClipOrientation(rotation: .left90, isMirrored: true))
        let duplicated = TimelineEditOperations.duplicate(clips: [clip], clipID: clip.id)
        XCTAssertEqual(duplicated.count, 2)
        XCTAssertEqual(duplicated[0].orientation, clip.orientation)
        XCTAssertEqual(duplicated[1].orientation, clip.orientation)
        // 複製先は別のクリップ（id は新規発番）。
        XCTAssertNotEqual(duplicated[1].id, clip.id)
    }

    func test_タイムラインの回転操作がクリップへ反映される() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 10)
        let state = TimelineState(clips: [clip])
        let rotated = state.rotatingClipRight(clipID: clip.id)
        XCTAssertEqual(rotated.clips[0].orientation.rotation, .right90)
        let flipped = rotated.flippingClipHorizontally(clipID: clip.id)
        XCTAssertTrue(flipped.clips[0].orientation.isMirrored)
        // 画面で見た左右反転なので、回転は逆向きになる（正準形の書き換え）。
        XCTAssertEqual(flipped.clips[0].orientation.rotation, .left90)
        // 未知のクリップ id では何も起きない（編集操作の「失敗時は self」契約）。
        XCTAssertEqual(state.rotatingClipLeft(clipID: UUID()), state)
    }
}
