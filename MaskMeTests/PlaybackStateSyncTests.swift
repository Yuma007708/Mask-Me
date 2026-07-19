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
}
