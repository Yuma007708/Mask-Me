import XCTest
import UIKit
import MosaicCore
@testable import MaskMe

/// 写真下書きの色調補正（`MosaicEditorModel.photoEdit`）が
/// **保存 → JSON デコード → 復元** の往復で失われないことを固定する。
///
/// `DraftStore.savePhotoDraft` に `photoEdit` を渡し忘れる、あるいは
/// `MosaicEditorModel.applyRestoredParameters` が `draft.photoEdit` を読み忘れる——
/// どちらの配線漏れでも「色調を掛けて下書きを閉じ、再開すると色調が消えている」という、
/// 利用者から見て単なるバグになる（親からの指摘・写真モード底上げ 第1段の追補）。
///
/// 実顔素材・MediaPipe は使わない（`NullFaceLandmarker` で完結。
/// `ColorGradeAppLayerTests` と同じ流儀）。ここで検証したいのは検出や描画ではなく、
/// `photoEdit` という値そのものの配線なので、Metal・実画像も不要。
final class PhotoDraftColorGradeRoundTripTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDraftColorGradeRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `savePhotoDraft` が JPEG エンコードできればよいだけの、最小のダミー画像。
    private func makeSolidImage(width: Int = 8, height: Int = 8, color: UIColor = .blue) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    func test_写真下書きの色調補正が保存復元で往復する() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeSolidImage()
        let savedGrade = ColorGrade(brightness: 0.5, contrast: 1.3, saturation: 0.7, warmth: -0.2)

        // 1) 色調を設定して下書きを保存する（`EditorView.persistDraft()` の写真経路と
        //    同じ呼び方: `model.photoEdit` を `DraftStore.savePhotoDraft` へそのまま渡す）。
        let savingModel = MosaicEditorModel(mode: .photo, recents: RecentItemsStore(),
                                            landmarker: NullFaceLandmarker())
        savingModel.setPhotoColorGrade(savedGrade)
        XCTAssertEqual(savingModel.photoEdit.colorGrade, savedGrade,
                       "テスト前提: setPhotoColorGrade が効いていない")

        let savingStore = DraftStore(directory: directory)
        savingStore.savePhotoDraft(
            existing: nil,
            image: image,
            faceMosaicOn: savingModel.faceMosaicOn,
            objectMosaicOn: savingModel.objectMosaicOn,
            backgroundMosaicOn: savingModel.backgroundMosaicOn,
            faceBlockSize: savingModel.faceBlockSize,
            backgroundBlockSize: savingModel.backgroundBlockSize,
            objectMasks: savingModel.draftObjectMasks,
            faceSelections: savingModel.selectedFaceAnchors,
            personProfiles: savingModel.selectedPersonProfilesForDraft,
            photoEdit: savingModel.photoEdit
        )

        // 2) ディスク上の JSON を実際にデコードする。**別インスタンスの `DraftStore`** で
        //    同じディレクトリを読み直すことが要点: 同一プロセス内の `photoDraft`
        //    （メモリ上の値）をそのまま使うと、JSON のエンコード/デコードを経由しない
        //    「保存したつもり」の往復になり、`Codable` の配線漏れを見逃す。
        let reloadedStore = DraftStore(directory: directory)
        let draft = try XCTUnwrap(reloadedStore.photoDraft, "保存した写真下書きが再読み込みできない")
        XCTAssertEqual(draft.photoEdit?.colorGrade, savedGrade,
                       "下書きの JSON に色調補正が保存されていない（savePhotoDraft への配線漏れ）")

        // 3) 復元する（下書きの再開経路と同じ入口 `applyRestoredParameters`）。
        let restoringModel = MosaicEditorModel(mode: .photo, recents: RecentItemsStore(),
                                               landmarker: NullFaceLandmarker())
        restoringModel.applyRestoredParameters(
            faceMosaicOn: draft.faceMosaicOn,
            objectMosaicOn: draft.objectMosaicOn,
            backgroundMosaicOn: draft.backgroundMosaicOn,
            faceBlockSize: draft.faceBlockSize,
            backgroundBlockSize: draft.backgroundBlockSize,
            objectMasks: draft.objectMasks,
            photoEdit: draft.photoEdit ?? .identity
        )

        XCTAssertEqual(restoringModel.photoEdit.colorGrade, savedGrade,
                       "復元後の model.photoEdit が保存した色調と一致しない（復元側の配線漏れ）")
        // 下書きの復元は編集ではない。undo 履歴を汚す（誤って `applyPhotoEdit` /
        // `commitEdit` を経由する）と、復元直後に「元に戻す」が誤って有効になる。
        XCTAssertFalse(restoringModel.canUndo,
                       "下書きの復元が undo 履歴を汚している（復元は編集ではない）")
    }
}
