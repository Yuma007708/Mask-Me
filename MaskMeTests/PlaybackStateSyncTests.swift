import XCTest
@testable import MaskMe

/// 再生状態（`isPlaying`）と実際の再生器（`previewController`）のずれを防ぐ回帰ガード。
///
/// Composition 経由に切り替えたことで、`load(videoURL:)` から戻った後も
/// `previewController` が構築されるまでの窓ができた。この窓で再生ボタンを押すと
/// `play()` は no-op なのに `isPlaying` だけ true になり、
/// 「UI は再生中・映像は停止」で2回押さないと復帰できない状態になっていた。
@MainActor
final class PlaybackStateSyncTests: XCTestCase {
    /// previewController が未構築の間は再生状態を進めないこと。
    func test_togglePlaybackIsNoOpWithoutPreviewController() {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        XCTAssertNil(model.previewController, "前提: 動画未ロードなら previewController は nil")
        XCTAssertFalse(model.isPlaying)

        model.togglePlayback()
        XCTAssertFalse(model.isPlaying,
                       "previewController が無いのに isPlaying が true になった（表示と実挙動のずれ）")

        // 連打しても状態が進まないこと（2回押さないと復帰できない挙動の否定）。
        model.togglePlayback()
        model.togglePlayback()
        XCTAssertFalse(model.isPlaying)
    }

    /// Composition 未構築の間に書き出しを押しても無言で終わらないこと。
    ///
    /// 移行前は同期代入の `videoAsset` を見ていたため押せば必ず書き出しが始まった。
    /// Composition 経由になって窓ができた結果、`guard let composition else { return }`
    /// だと進捗もアラートも出ず「押しても何も起きない」状態になっていた。
    func test_exportVideoReportsErrorWhileCompositionIsBuilding() async {
        let model = MosaicEditorModel(mode: .video, recents: RecentItemsStore())
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.exportProgress, "前提: まだ書き出しは走っていない")

        await model.exportVideo()

        XCTAssertNotNil(model.errorMessage,
                        "Composition 未構築で書き出しを押したのに無言で終わった（進捗もアラートも出ない）")
        XCTAssertNil(model.exportProgress, "書き出しは開始していないので進捗は出さない")
        XCTAssertFalse(model.didSave)
    }
}
