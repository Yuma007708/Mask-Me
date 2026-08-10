import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// `VideoCompositionFactory` へのクリップ変形（`TimelineClip.transform`）の配線を固定する。
///
/// **座標一致そのもの**（映像のアフィン変換とモザイクの正規化写像が変形込みで一致するか）は
/// `MosaicCoreTests/ClipTransformParityTests` がコア層の型だけで固定している。ここでは
/// アプリ層固有の配線 —— `VideoCompositionConditions.hasClipTransform` が装着を強制すること、
/// `VideoCompositionFactory.renderSize(for:orientation:)` が変形の影響を受けないこと —— を
/// 実測する（`orientation` 導入時の同種の doc 警告と同じ理由: 渡し忘れは無言で効かなくなる）。
final class VideoCompositionFactoryTransformTests: XCTestCase {
    private func makeTrack() -> AVMutableCompositionTrack {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            fatalError("テスト用の空トラックを作れない")
        }
        return track
    }

    private func makePlacement(clip: TimelineClip, start: Double = 0, end: Double = 4,
                               size: CGSize = CGSize(width: 640, height: 480)) -> ClipPlacement {
        ClipPlacement(clip: clip, format: .init(size: size, transform: .identity),
                     frameRate: 30, track: makeTrack(), audioTrack: nil,
                     start: start, end: end)
    }

    /// 単一クリップ・同一フォーマットで**変形だけ**を掛けたタイムラインでも
    /// `VideoCompositionPlan.decide == .attach` になること。
    ///
    /// これが `.none` に倒れると、`make(placements:overlaps:totalDuration:)` が
    /// 装着なしの早期リターンへ入り、変形が映像にもモザイクにも無言で効かなくなる
    /// （`hasClipOrientation` 導入時と同じ事故のパターン）。
    func test_変形のみのタイムラインでもdecideがattachになる() {
        var clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        clip.transform = ClipTransform(scale: 1.5, offset: CGPoint(x: 0.1, y: 0))
        let placements = [makePlacement(clip: clip)]

        let conditions = VideoCompositionConditions.from(placements: placements, overlaps: [])
        XCTAssertTrue(conditions.hasClipTransform, "hasClipTransform が立っていない")
        XCTAssertEqual(VideoCompositionPlan.decide(conditions: conditions), .attach,
                       "変形のみのタイムラインで装着されない（変形が無言で効かなくなる）")

        let result = VideoCompositionFactory.make(placements: placements, overlaps: [],
                                                   totalDuration: 4)
        XCTAssertNotNil(result.videoComposition, "videoComposition が装着されていない")
    }

    /// 無変換（変形も向きもフォーマット混在もトランジションも無い）タイムラインでは
    /// 引き続き `.none`（無装着）のままであること（既存の忠実度契約を壊していない確認）。
    func test_無変形のタイムラインは引き続きnoneのまま() {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        let placements = [makePlacement(clip: clip)]

        let conditions = VideoCompositionConditions.from(placements: placements, overlaps: [])
        XCTAssertFalse(conditions.hasClipTransform)
        XCTAssertEqual(VideoCompositionPlan.decide(conditions: conditions), .none)
    }

    /// 先頭クリップを拡大（`scale=2`）しても `renderSize(for:orientation:)` の結果は
    /// 変わらないこと（変形は出力枠自体の大きさを決める要素ではない。型 doc 参照）。
    func test_先頭クリップを拡大してもrenderSizeが変わらない() {
        let format = TimelineCompositionBuilder.VideoFormat(size: CGSize(width: 640, height: 480),
                                                             transform: .identity)
        let baseline = VideoCompositionFactory.renderSize(for: format, orientation: .identity)

        var scaledClip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 4)
        scaledClip.transform = ClipTransform(scale: 2.0)
        let placements = [makePlacement(clip: scaledClip, size: format.size)]
        let result = VideoCompositionFactory.make(placements: placements, overlaps: [],
                                                   totalDuration: 4)

        XCTAssertEqual(result.videoComposition?.renderSize, baseline,
                       "先頭クリップの拡大で出力解像度（renderSize）まで変わっている")
    }
}
