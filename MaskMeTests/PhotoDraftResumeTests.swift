import XCTest
import UIKit
import MosaicCore
@testable import MaskMe

/// 写真の下書きが**ホームの「編集中」に出せて、そこから再開できる**ことを固定する。
///
/// ## なぜ要るか
///
/// 旧 UI の `RecentItemsView` は `draftStore.videoDrafts` しか見ておらず、
/// **写真の下書きは保存されているのに画面から辿れなかった**。保存側
/// （`savePhotoDraft`）も復元側（`applyRestoredParameters`）も動いていて、
/// 欠けていたのは一覧に出す導線だけだったので、既存のテストは全部緑のままだった。
///
/// ここで固定するのは、画面が下書きカードを描くために必要な 2 つの前提:
///
/// 1. **サムネイルが引ける**（`thumbnail(for:)` が nil を返さない）。返さないと
///    カードが記号だけになり、どの写真を編集していたのか分からない。
/// 2. **素材を画像として読み直せる**（`HomeView.resume` の写真経路）。動画は
///    `sourceURL` をそのまま `PickedMedia.video` に渡せるが、写真は JPEG から
///    `UIImage` を作り直す必要がある。ここが読めないまま編集画面へ進むと、
///    保存した瞬間に**空の内容で下書きが上書きされる**（元の写真が失われる）。
///
/// 実顔素材・MediaPipe・Metal は使わない（`PhotoDraftColorGradeRoundTripTests` と同じ流儀。
/// 見たいのは検出や描画ではなく、保管と読み直しの配線そのもの）。
final class PhotoDraftResumeTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDraftResumeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// **`UIGraphicsImageRendererFormat.scale = 1` を明示すること。** 既定は画面
    /// スケール（Simulator では 3）なので、指定した寸法の 3 倍の `cgImage` ができ、
    /// 「長辺 480 に縮む」の検証が 3 倍ずれる（`PhotoOrientationBurnInTests` で踏んだ罠）。
    private func makeSolidImage(width: Int, height: Int, color: UIColor = .systemTeal) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    private func save(_ image: UIImage, into store: DraftStore, existing: UUID? = nil) {
        store.savePhotoDraft(
            existing: existing,
            image: image,
            faceMosaicOn: true,
            backgroundMosaicOn: false,
            faceBlockSize: 24,
            backgroundBlockSize: 24,
            objectMasks: []
        )
    }

    // MARK: - 一覧に出すための前提

    @MainActor
    func test_写真の下書きにサムネイルが付く() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DraftStore(directory: directory)
        save(makeSolidImage(width: 120, height: 90), into: store)

        let draft = try XCTUnwrap(store.photoDraft, "写真の下書きが保存されていない")
        XCTAssertNotNil(draft.thumbnailFileName,
                        "写真の下書きにサムネイルのファイル名が付いていない"
                        + "（ホームの「編集中」カードが記号だけになる）")
        XCTAssertNotNil(store.thumbnail(for: draft),
                        "サムネイルのファイル名はあるのに画像として読めない")
    }

    /// **サムネイルは縮める。** 素材そのものを使い回すと 1 枚が数 MB になり、
    /// カードを並べるだけでメモリと IO を食う。
    @MainActor
    func test_サムネイルは長辺480に収まる() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DraftStore(directory: directory)
        save(makeSolidImage(width: 2000, height: 1000), into: store)

        let draft = try XCTUnwrap(store.photoDraft)
        let thumb = try XCTUnwrap(store.thumbnail(for: draft))
        let longSide = max(thumb.size.width, thumb.size.height) * thumb.scale
        XCTAssertLessThanOrEqual(longSide, 480 + 1,
                                 "サムネイルが縮んでいない longSide=\(longSide)")
        XCTAssertGreaterThan(longSide, 240,
                             "縮めすぎてカードで粗く見える longSide=\(longSide)")
    }

    /// 元が小さいときは**拡大しない**（引き伸ばすとファイルだけ大きくなる）。
    @MainActor
    func test_小さい写真はサムネイルで拡大されない() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DraftStore(directory: directory)
        save(makeSolidImage(width: 100, height: 60), into: store)

        let draft = try XCTUnwrap(store.photoDraft)
        let thumb = try XCTUnwrap(store.thumbnail(for: draft))
        XCTAssertEqual(max(thumb.size.width, thumb.size.height) * thumb.scale, 100, accuracy: 1,
                       "小さい素材が引き伸ばされている")
    }

    // MARK: - 再開の前提

    /// `HomeView.resume` の写真経路と**同じ手順**で素材を読み直せること。
    ///
    /// ここが壊れると「編集中」をタップしても空の編集画面が開き、
    /// 自動保存が走った瞬間に元の写真が失われる。
    @MainActor
    func test_写真の下書きの素材を画像として読み直せる() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DraftStore(directory: directory)
        save(makeSolidImage(width: 160, height: 120), into: store)

        let draft = try XCTUnwrap(store.photoDraft)
        XCTAssertEqual(draft.kind, .photo, "種別が写真になっていない")

        let url = store.sourceURL(for: draft)
        let data = try XCTUnwrap(try? Data(contentsOf: url),
                                 "下書きの素材ファイルが読めない url=\(url.lastPathComponent)")
        let restored = try XCTUnwrap(UIImage(data: data), "素材を UIImage として復元できない")
        XCTAssertEqual(restored.size.width / restored.size.height, 160.0 / 120.0, accuracy: 0.02,
                       "復元した素材の縦横比が元と違う size=\(restored.size)")
    }

    /// 上書き保存でサムネイルのファイルが**増えない**（`reuse: id` が効いている）。
    /// 増えると自動保存のたびにファイルが溜まり、掃除の対象にもならない。
    @MainActor
    func test_上書き保存でサムネイルのファイルが増えない() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DraftStore(directory: directory)
        save(makeSolidImage(width: 120, height: 90, color: .red), into: store)
        let firstID = try XCTUnwrap(store.photoDraft?.id)

        for _ in 0..<3 {
            save(makeSolidImage(width: 120, height: 90, color: .green), into: store, existing: firstID)
        }

        let thumbs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("thumb-") }
        XCTAssertEqual(thumbs.count, 1,
                       "上書きのたびにサムネイルが増えている thumbs=\(thumbs)")
    }
}
