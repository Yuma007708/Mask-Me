import AVFoundation
import MosaicCore
import XCTest
@testable import MaskMe

/// レターボックス（余白）の埋め方の**配線**を固定する。
///
/// コア層の値（`TimelineBackground` の規則と永続化）は `MosaicCoreTests` 側で
/// テスト済み。ここで見るのはアプリ層の 1 点だけ——
/// **選んだ色が実際に描画経路（`AVMutableVideoCompositionInstruction`）まで届くか**。
///
/// ここが繋がっていないと、設定は保存されるのに見た目が変わらない（黒帯のまま）
/// という、UI だけ見ても気づけない壊れ方になる。
///
/// **プレビューと書き出しは同じ `videoComposition` を使う**（プレビューは
/// `AVPlayerItem.videoComposition`、書き出しは `AVAssetReaderVideoCompositionOutput`）
/// ので、ここを押さえれば両経路が同時に守られる。
@MainActor
final class LetterboxBackgroundWiringTests: XCTestCase {
    private func makeTrack() -> AVMutableCompositionTrack {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            fatalError("テスト用の空トラックを作れない")
        }
        return track
    }

    /// 横長素材（1920x1080）を 1 本。9:16 を選べば必ず余白が出る構成。
    private func makePlacement() -> ClipPlacement {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        return ClipPlacement(clip: clip,
                             format: .init(size: CGSize(width: 1920, height: 1080),
                                           transform: .identity),
                             frameRate: 30, track: makeTrack(), audioTrack: nil,
                             start: 0, end: 4)
    }

    private func makeComposition(_ background: TimelineBackground) throws
    -> AVMutableVideoComposition {
        let (videoComposition, _) = VideoCompositionFactory.make(
            placements: [makePlacement()], overlaps: [], totalDuration: 4,
            background: background,
            // 9:16 の出力枠を明示（横長素材なので上下に余白が出る）。
            //
            // **`renderSizeOverride` も渡す。** 装着するかどうかは
            // `VideoCompositionConditions.forcesRenderSize`（＝`renderSizeOverride != nil`）が
            // 決めるので、`preCropFrameOverride` だけでは装着されず instruction が
            // 1 本も作られない。製品側は `TimelineCompositionBuilder.outputSizing` が
            // 「比率で自然サイズと変わったら override を渡す」形で同じ経路を通る。
            preCropFrameOverride: CGSize(width: 1080, height: 1920),
            renderSizeOverride: CGSize(width: 1080, height: 1920))
        return try XCTUnwrap(videoComposition, "videoComposition が装着されない")
    }

    private func components(_ color: CGColor) throws -> [CGFloat] {
        try XCTUnwrap(color.components, "色成分を取り出せない")
    }

    // MARK: - 色

    func test_選んだ色が合成の背景色まで届く() throws {
        let orange = RGBAColor(red: 1, green: 0.5, blue: 0)
        let composition = try makeComposition(TimelineBackground(kind: .color, color: orange))
        for instruction in composition.instructions {
            let typed = try XCTUnwrap(instruction as? AVMutableVideoCompositionInstruction)
            let parts = try components(try XCTUnwrap(typed.backgroundColor,
                                                     "背景色が設定されていない（余白は黒のまま）"))
            XCTAssertEqual(Double(parts[0]), orange.red, accuracy: 0.01)
            XCTAssertEqual(Double(parts[1]), orange.green, accuracy: 0.01)
            XCTAssertEqual(Double(parts[2]), orange.blue, accuracy: 0.01)
        }
        XCTAssertFalse(composition.instructions.isEmpty, "instruction が 1 本も無い")
    }

    /// **既定（黒）のときは何も設定しない。** AVFoundation の既定色と同じ値をわざわざ
    /// 書くと、「無変換構成では素の composition と同じ」という
    /// `CompositionFidelityTests` の性質に無用な差分を持ち込む。
    func test_黒のときは背景色を設定しない() throws {
        let composition = try makeComposition(.default)
        for instruction in composition.instructions {
            let typed = try XCTUnwrap(instruction as? AVMutableVideoCompositionInstruction)
            XCTAssertNil(typed.backgroundColor, "黒なのに背景色を明示している")
        }
    }

    /// ぼかしの下地は黒（`TimelineBackground.fillColor` の規則）。**選んだ色が
    /// 漏れてはいけない**——ぼかしの外周が明るい色で縁取られると余白が目立つ。
    func test_ぼかしの下地は黒で選んだ色が漏れない() throws {
        var background = TimelineBackground(kind: .blur)
        background.color = RGBAColor(red: 1, green: 0, blue: 0)
        let composition = try makeComposition(background)
        for instruction in composition.instructions {
            let typed = try XCTUnwrap(instruction as? AVMutableVideoCompositionInstruction)
            let parts = try components(try XCTUnwrap(typed.backgroundColor))
            XCTAssertEqual(Double(parts[0]), 0, accuracy: 0.01, "赤が下地へ漏れている")
            XCTAssertEqual(Double(parts[1]), 0, accuracy: 0.01)
            XCTAssertEqual(Double(parts[2]), 0, accuracy: 0.01)
        }
    }

    /// **余白の設定だけでは合成を装着しない。**
    ///
    /// 装着の判定（`VideoCompositionPlan.decide`）に余白の種類を足していないのは
    /// 意図どおりである。素材がそのままの枠に収まる構成（比率 `.source`・クロップ無し・
    /// 単一フォーマット）には**そもそも余白が無い**ので、塗る対象が存在しない。
    /// ここで装着を強制すると、無変換タイムラインの忠実度
    /// （`CompositionFidelityTests` の bit 同一契約）を、見た目が 1 ピクセルも
    /// 変わらないまま壊すことになる。
    func test_余白の設定だけでは合成を装着しない() {
        let (videoComposition, _) = VideoCompositionFactory.make(
            placements: [makePlacement()], overlaps: [], totalDuration: 4,
            background: TimelineBackground(kind: .color,
                                           color: RGBAColor(red: 1, green: 0, blue: 0)))
        XCTAssertNil(videoComposition,
                     "余白が存在しない構成なのに合成を装着している（無変換の忠実度が崩れる）")
    }

    /// 壊れた値でも色を作れること（`CGColor` の生成に失敗して落ちない）。
    func test_壊れた色でも合成を作れる() throws {
        let broken = TimelineBackground(kind: .color,
                                        color: RGBAColor(red: .nan, green: .infinity, blue: -5))
        let composition = try makeComposition(broken)
        XCTAssertFalse(composition.instructions.isEmpty)
    }
}
