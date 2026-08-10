import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// 切り抜き（クロップ）の動画への配線（Step 4）を固定する。
///
/// コア層（`CropRect` / `RenderPlacement.make` / `TimelineState.crop`）は前段で
/// テスト済み・コミット済み。ここではアプリ層の配線——
/// - `VideoCompositionConditions.hasCrop` が装着を強制すること
/// - `TimelineCompositionBuilder.outputSizing` が「比率 → クロップ → 無料プランの上限」の
///   順で計算すること
/// - `VideoCompositionFactory.make` が配置矩形（モザイク側）と映像変換（`instruction`）を
///   **同じクロップ済み矩形**から作ること
/// - 画面比率を変えるとクロップが `.full` へリセットされること
///
/// ——を実測する。座標一致そのもの（`RenderPlacement.make` の数式）は
/// `MosaicCoreTests` がコア層の型だけで固定している
/// （`VideoCompositionFactoryTransformTests` と同じ役割分担）。
@MainActor
final class CropVideoWiringTests: XCTestCase {
    // MARK: - テストユーティリティ（`VideoCompositionFactoryTransformTests` と同じ流儀）

    private func makeTrack() -> AVMutableCompositionTrack {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            fatalError("テスト用の空トラックを作れない")
        }
        return track
    }

    private func makePlacement(clip: TimelineClip, start: Double = 0, end: Double = 4,
                               size: CGSize = CGSize(width: 1920, height: 1080)) -> ClipPlacement {
        ClipPlacement(clip: clip, format: .init(size: size, transform: .identity),
                     frameRate: 30, track: makeTrack(), audioTrack: nil,
                     start: start, end: end)
    }

    /// `videoComposition` の指定トラック・指定時刻の実際の変換（`setTransform` /
    /// `setTransformRamp` のどちらでも取れる）。テスト 5 の「instruction から逆算」の土台。
    private func extractTransform(from videoComposition: AVMutableVideoComposition,
                                  trackID: CMPersistentTrackID,
                                  at time: CMTime) throws -> CGAffineTransform {
        let instruction = try XCTUnwrap(
            videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }
                .first { $0.timeRange.start <= time && time < $0.timeRange.end },
            "指定時刻を覆う instruction が無い")
        let layer = try XCTUnwrap(
            instruction.layerInstructions.first { $0.trackID == trackID },
            "対象トラックのレイヤ instruction が無い")
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var range = CMTimeRange.zero
        let hasRamp = layer.getTransformRamp(for: time, start: &start, end: &end, timeRange: &range)
        XCTAssertTrue(hasRamp, "transform を取得できない（setTransform も内部的にはランプとして取れる）")
        return start
    }

    // MARK: - 1. クロップ時のみ合成が装着される

    func test_クロップ時のみ合成が装着される() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placements = [makePlacement(clip: clip)]
        let crop = CropRect(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))

        // クロップ以外の条件はゼロ（向き・変形・rate・トランジション・フォーマット混在なし）。
        let conditions = VideoCompositionConditions.from(placements: placements, overlaps: [], crop: crop)
        XCTAssertTrue(conditions.hasCrop, "hasCrop が立っていない")
        XCTAssertEqual(VideoCompositionPlan.decide(conditions: conditions), .attach,
                       "クロップのみのタイムラインで装着されない（クロップが無言で効かなくなる）")

        let result = VideoCompositionFactory.make(placements: placements, overlaps: [],
                                                   totalDuration: 4, crop: crop)
        XCTAssertNotNil(result.videoComposition, "videoComposition が装着されていない")

        // 対照: クロップが `.full` なら他の条件が無い限り装着しない（既存の忠実度契約）。
        let fullConditions = VideoCompositionConditions.from(placements: placements, overlaps: [])
        XCTAssertFalse(fullConditions.hasCrop)
        XCTAssertEqual(VideoCompositionPlan.decide(conditions: fullConditions), .none)
    }

    // MARK: - 2. 出力サイズは比率の後にクロップが掛かる

    /// 1920x1080 素材 ＋ 9:16 出力 ＋ 横半分クロップ の期待値を数値で固定する。
    ///
    /// 手計算: natural = 1920x1080（偶数丸め済み）。
    /// `.portrait9x16` は短辺（1080）を据え置き、長辺を 1080*16/9 = 1920 から導くので
    /// aspect = 1080x1920（縦横が入れ替わる）。この 1080x1920 の**半分の幅**を切り取ると
    /// pixel = (0, 0, 540, 1920) → 偶数丸め済みなのでそのまま cropped = 540x1920。
    func test_出力サイズは比率の後にクロップが掛かる() {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 1920, height: 1080),
                                                             transform: .identity)
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placements = [makePlacement(clip: clip, size: format.size)]
        let crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))

        let sizing = TimelineCompositionBuilder.outputSizing(
            placements: placements, aspectRatio: .portrait9x16, crop: crop,
            isPro: true, totalDuration: 4)

        XCTAssertEqual(sizing.natural, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(sizing.preCropFrameOverride, CGSize(width: 1080, height: 1920),
                       "クロップ前・比率適用後の枠（フィット計算の対象）が違う")
        XCTAssertEqual(sizing.clamped, CGSize(width: 540, height: 1920),
                       "比率の後にクロップを掛けた実出力サイズが違う")
        XCTAssertEqual(sizing.renderSizeOverride, CGSize(width: 540, height: 1920))

        // `VideoCompositionFactory.make` へ渡した実際の renderSize もこの値と一致すること
        // （表示用の `Built.outputSize` と実出力 `videoComposition.renderSize` の一致契約、
        // `TimelineCompositionBuilderTests.test_aspectRatioChangesRenderSizeAndOutputSizeTogether`
        // と同じ観点をクロップ込みで確かめる）。
        let result = VideoCompositionFactory.make(
            placements: placements, overlaps: [], totalDuration: 4, crop: crop,
            preCropFrameOverride: sizing.preCropFrameOverride, renderSizeOverride: sizing.renderSizeOverride)
        XCTAssertEqual(result.videoComposition?.renderSize, CGSize(width: 540, height: 1920))
    }

    // MARK: - 3. 無料プランの上限はクロップの後に効く

    /// 3840x2160（4K・16:9）を **高さ半分**にクロップすると 3840x1080（短辺ちょうど 1080）
    /// になり、無料プランの上限（短辺 1080）を超えない。クロップ**前**のサイズ
    /// （3840x2160・短辺 2160）で判定していたら確実に超過する——この対比で
    /// 「制限はクロップの後に効く」ことを固定する。
    func test_無料プランの上限はクロップの後に効く() {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 3840, height: 2160),
                                                             transform: .identity)
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placements = [makePlacement(clip: clip, size: format.size)]
        let crop = CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5))

        // 比較用: クロップ**前**のサイズだけを見れば無料プランの上限を超えるはずの入力。
        let restrictionBeforeCrop = ExportRestrictionPolicy.decide(
            isPro: false, durationSeconds: 4, resolution: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(restrictionBeforeCrop, .exceedsResolution(limit: 1080),
                       "前提が崩れている: クロップ前のサイズは無料プランの上限を超えるはず")

        let sizing = TimelineCompositionBuilder.outputSizing(
            placements: placements, aspectRatio: .source, crop: crop,
            isPro: false, totalDuration: 4)

        XCTAssertEqual(sizing.clamped, CGSize(width: 3840, height: 1080),
                       "クロップ後（短辺ちょうど 1080）なのに追加で縮小されている")
        XCTAssertEqual(sizing.restriction, .watermarkOnly,
                       "クロップ後のサイズで判定していない（クロップ前のサイズで縮小がかかっている）")
    }

    // MARK: - 4. 全面クロップは無変換タイムラインの忠実度を壊さない

    /// `.full` は `renderSizeOverride` / `preCropFrameOverride` のどちらも出さない
    /// （既存 `CompositionFidelityTests` の bit 同一契約はこの nil 契約の上に成立している）。
    func test_全面クロップは無変換タイムラインの忠実度を壊さない() {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 320, height: 240),
                                                             transform: .identity)
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placements = [makePlacement(clip: clip, size: format.size)]

        let sizing = TimelineCompositionBuilder.outputSizing(
            placements: placements, aspectRatio: .source, crop: .full,
            isPro: true, totalDuration: 4)
        XCTAssertNil(sizing.renderSizeOverride)
        XCTAssertNil(sizing.preCropFrameOverride)

        let conditions = VideoCompositionConditions.from(placements: placements, overlaps: [], crop: .full)
        XCTAssertFalse(conditions.hasCrop)
        XCTAssertEqual(VideoCompositionPlan.decide(conditions: conditions), .none)

        let result = VideoCompositionFactory.make(placements: placements, overlaps: [], totalDuration: 4)
        XCTAssertNil(result.videoComposition, "全面クロップ（無指定）なのに装着されている")
        XCTAssertEqual(result.layout, .identity)
    }

    // MARK: - 5. クロップ後も配置矩形と映像変換が同じ矩形から作られる（本命）

    /// **これが「layoutRects にだけクロップを掛けて fitTransform に掛け忘れる」を落とす。**
    ///
    /// 1920x1080 の素材を 1920x1080 の枠（無変換）へ、x=0.25, width=0.5 のクロップで
    /// 中央半分だけ切り取る。手計算:
    /// `AspectFit.placement` は等倍なので unit rect (0,0,1,1)。
    /// `crop.expand(unit)`: minX=(0-0.25)/0.5=-0.5, width=1/0.5=2, minY=0, height=1
    /// → `fitted = (-0.5, 0, 2, 1)`。renderSize（クロップ後）は幅 0.5*1920=960 で
    /// `(960, 1080)`。
    ///
    /// `layout.placement(for:)` がこの `fitted` と一致すること、かつ実際の
    /// `AVVideoComposition` の instruction 変換から逆算した配置矩形も同じ値になることを
    /// 突き合わせる。
    func test_クロップ後も配置矩形と映像変換が同じ矩形から作られる() throws {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 1920, height: 1080),
                                                             transform: .identity)
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placement = makePlacement(clip: clip, size: format.size)
        let crop = CropRect(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))

        let expectedPlacement = CGRect(x: -0.5, y: 0, width: 2, height: 1)
        let expectedRenderSize = CGSize(width: 960, height: 1080)

        let result = VideoCompositionFactory.make(
            placements: [placement], overlaps: [], totalDuration: 4, crop: crop)
        let videoComposition = try XCTUnwrap(result.videoComposition)
        XCTAssertEqual(videoComposition.renderSize, expectedRenderSize)

        let layoutPlacement = result.layout.placement(for: clip.id)
        XCTAssertEqual(layoutPlacement.minX, expectedPlacement.minX, accuracy: 1e-9)
        XCTAssertEqual(layoutPlacement.minY, expectedPlacement.minY, accuracy: 1e-9)
        XCTAssertEqual(layoutPlacement.width, expectedPlacement.width, accuracy: 1e-9)
        XCTAssertEqual(layoutPlacement.height, expectedPlacement.height, accuracy: 1e-9)

        // instruction の実際の変換から配置矩形を逆算する（向き identity・rotate 無しなので
        // a==d==scale, tx/ty がそのまま平行移動）。
        let transform = try extractTransform(from: videoComposition, trackID: placement.track.trackID,
                                             at: .zero)
        let derivedWidth = transform.a * format.size.width / expectedRenderSize.width
        let derivedHeight = transform.d * format.size.height / expectedRenderSize.height
        let derivedMinX = transform.tx / expectedRenderSize.width
        let derivedMinY = transform.ty / expectedRenderSize.height

        XCTAssertEqual(derivedMinX, layoutPlacement.minX, accuracy: 1e-6,
                       "instruction の変換から逆算した配置と layout の配置が食い違う（モザイクだけ枠外へずれる）")
        XCTAssertEqual(derivedMinY, layoutPlacement.minY, accuracy: 1e-6)
        XCTAssertEqual(derivedWidth, layoutPlacement.width, accuracy: 1e-6)
        XCTAssertEqual(derivedHeight, layoutPlacement.height, accuracy: 1e-6)
    }

    // MARK: - 6. 比率を変えるとクロップがリセットされる

    func test_比率を変えるとクロップがリセットされる() {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        let source = model.currentSourceID
        model.setClipsForTesting([TimelineClip(sourceID: source, sourceStart: 0, sourceEnd: 10)])

        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        model.setCrop(crop)
        XCTAssertEqual(model.timeline.crop, crop, "クロップを設定できていない（前提が崩れている）")

        model.setOutputAspectRatio(.portrait9x16)

        XCTAssertEqual(model.timeline.aspectRatio, .portrait9x16)
        XCTAssertEqual(model.timeline.crop, .full,
                       "比率を変えてもクロップがリセットされていない（不可逆な二重変換の温床になる）")
    }

    // MARK: - 7. クロップと変形を同時に掛けたとき順序が 切り抜き→変形 である

    /// **確定した適用順序**（向き → AspectFit → CropRect → ClipTransform）のうち、
    /// クロップと変形の順を実測で固定する。1920x1080 素材・`.portrait9x16` 出力・
    /// 横半分クロップ（テスト 2 と同じ入力）に `scale=1.5, offset=(0.2, 0.1)` の変形を掛ける。
    ///
    /// 手計算（正しい順序: クロップ→変形）:
    /// `preCropFrame = 1080x1920`。`AspectFit.placement(of: 1920x1080, in: 1080x1920)`
    /// = (0, 0.341796875, 1, 0.31640625)（4:3... ではなく 16:9 素材が縦長枠に収まり、
    /// 幅いっぱい・上下に黒帯）。半分幅クロップ (x=0,width=0.5) を掛けると
    /// `fitted = (0, 0.341796875, 2, 0.31640625)`。ここへ `scale=1.5, offset=(0.2,0.1)`
    /// を掛けると `expectedCorrect = (-0.1, 0.2943359375, 3, 0.474609375)`。
    ///
    /// 対照として「クロップを経ずに出力枠（540x1920）へ直接フィットしてから変形を掛けた」
    /// 誤実装（クロップが独立した段になっていない＝クロップと変形の分離が壊れている）の
    /// 値も手計算し、`expectedCorrect` と数値が異なることを確認する
    /// （順序を取り違えると異なる絵になることの裏付け）。
    func test_クロップと変形を同時に掛けたとき順序が切り抜き変形である() {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 1920, height: 1080),
                                                             transform: .identity)
        var clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        clip.transform = ClipTransform(scale: 1.5, offset: CGPoint(x: 0.2, y: 0.1))
        let placement = makePlacement(clip: clip, size: format.size)
        let crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))

        let sizing = TimelineCompositionBuilder.outputSizing(
            placements: [placement], aspectRatio: .portrait9x16, crop: crop,
            isPro: true, totalDuration: 4)
        XCTAssertEqual(sizing.preCropFrameOverride, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(sizing.renderSizeOverride, CGSize(width: 540, height: 1920))

        let result = VideoCompositionFactory.make(
            placements: [placement], overlaps: [], totalDuration: 4, crop: crop,
            preCropFrameOverride: sizing.preCropFrameOverride, renderSizeOverride: sizing.renderSizeOverride)

        let expectedCorrect = CGRect(x: -0.1, y: 0.2943359375, width: 3, height: 0.474609375)
        let expectedWrong = CGRect(x: -0.05, y: 0.39716796875, width: 1.5, height: 0.2373046875)

        let actual = result.layout.placement(for: clip.id)
        XCTAssertEqual(actual.minX, expectedCorrect.minX, accuracy: 1e-6,
                       "クロップ→変形の順（確定した適用順序）の期待値と食い違う")
        XCTAssertEqual(actual.minY, expectedCorrect.minY, accuracy: 1e-6)
        XCTAssertEqual(actual.width, expectedCorrect.width, accuracy: 1e-6)
        XCTAssertEqual(actual.height, expectedCorrect.height, accuracy: 1e-6)

        // 逆順（クロップを経ずに出力枠へ直接フィットしてから変形）の値とは異なること。
        XCTAssertNotEqual(actual.minX, expectedWrong.minX, accuracy: 1e-6)
        XCTAssertNotEqual(actual.width, expectedWrong.width, accuracy: 1e-6)
    }
}

/// `XCTAssertNotEqual` に `accuracy` 版が無いので簡易実装する
/// （`XCTAssertEqual(_:_:accuracy:)` の否定）。
private func XCTAssertNotEqual(_ expression1: @autoclosure () -> CGFloat,
                               _ expression2: @autoclosure () -> CGFloat,
                               accuracy: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) {
    let (value1, value2) = (expression1(), expression2())
    XCTAssertTrue(abs(value1 - value2) > accuracy,
                 "\(value1) と \(value2) が accuracy \(accuracy) 以内で一致してしまっている",
                 file: file, line: line)
}
