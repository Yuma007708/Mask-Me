import UIKit
import MosaicCore

/// Stores editing drafts (source media + parameters) under Documents/Drafts.
@MainActor
final class DraftStore: ObservableObject {
    /// Resumable video drafts, newest first.
    @Published private(set) var videoDrafts: [EditingDraft] = []
    /// The single in-progress photo draft, if any.
    @Published private(set) var photoDraft: EditingDraft?

    private let fileManager: FileManager
    private let directory: URL
    private let videoIndexURL: URL
    private let photoIndexURL: URL

    /// - Parameter directory: 保存先の上書き（テスト用）。nil なら Documents/Drafts。
    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = documents.appendingPathComponent("Drafts", isDirectory: true)
        }
        self.videoIndexURL = self.directory.appendingPathComponent("video_drafts.json")
        self.photoIndexURL = self.directory.appendingPathComponent("photo_draft.json")
        createDirectoryIfNeeded()
        load()
    }

    // MARK: - Source URLs

    func sourceURL(for draft: EditingDraft) -> URL {
        directory.appendingPathComponent(draft.sourceFileName)
    }

    /// 下書きが参照する全素材の 素材ID → ファイルURL 対応（復元用）。
    func sourceURLs(for draft: EditingDraft) -> [UUID: URL] {
        Dictionary(draft.sources.map { ($0.id, directory.appendingPathComponent($0.fileName)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// 下書きID に保存されている顔選択の目印（動画・写真どちらの下書きでも引ける）。
    /// nil は「情報なし」（新フィールド導入前の下書き・該当する下書きが無い）で、
    /// 復元側は顔の選択状態に触れない（`EditingDraft.faceSelections` の doc 参照）。
    func faceSelections(forDraftID id: UUID) -> [DraftFaceSelection]? {
        if let draft = videoDrafts.first(where: { $0.id == id }) { return draft.faceSelections }
        if let photo = photoDraft, photo.id == id { return photo.faceSelections }
        return nil
    }

    /// 下書きID に保存されている人物（`faceSelections` の `personID` の参照先）。
    /// nil は「情報なし」で、復元は重心照合だけになる。
    func personProfiles(forDraftID id: UUID) -> [PersonProfile]? {
        if let draft = videoDrafts.first(where: { $0.id == id }) { return draft.personProfiles }
        if let photo = photoDraft, photo.id == id { return photo.personProfiles }
        return nil
    }

    func thumbnail(for draft: EditingDraft) -> UIImage? {
        guard let name = draft.thumbnailFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Save

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    /// Saves / updates a video draft (copying all referenced source videos for durability).
    ///
    /// - Parameters:
    ///   - sources: タイムラインが参照する素材列（出現順・先頭が primary）。
    ///     `MosaicEditorModel.draftSources` をそのまま渡す。
    ///   - sessionSourceIDs: 呼び出し元の編集セッションが（undo/redo で復活し得る
    ///     ものも含めて）参照中の素材ID集合。`MosaicEditorModel.sessionReferencedSourceIDs`
    ///     をそのまま渡す。GC はこの集合の素材コピーを削除しない
    ///     （アーキテクチャ決定 7「セッション中は undo 用に保持」）。
    ///   - timeline: 保存するタイムライン（クリップ空 = 素材全体 1 クリップの意味）。
    ///
    /// 保存後は未参照になった素材コピーを GC する（`collectGarbage(protecting:)` 参照）。
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    func saveVideoDraft(
        existing: UUID?,
        sources: [(id: UUID, url: URL)],
        sessionSourceIDs: Set<UUID> = [],
        timeline: TimelineState,
        faceMosaicOn: Bool,
        objectMosaicOn: Bool = true,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        objectMasks: [ObjectMask],
        faceSelections: [DraftFaceSelection]? = nil,
        personProfiles: [PersonProfile]? = nil,
        thumbnail: UIImage?
    ) -> EditingDraft? {
        var draftSources: [DraftSource] = []
        for source in sources {
            guard let name = registerSource(source.url, sourceID: source.id) else { return nil }
            draftSources.append(DraftSource(id: source.id, fileName: name))
        }
        guard let primary = draftSources.first else { return nil }
        let thumbName = writeThumbnail(thumbnail, reuse: existing)
        let draft = EditingDraft(
            id: existing ?? UUID(),
            kind: .video,
            sourceFileName: primary.fileName,
            sources: draftSources,
            timeline: timeline,
            faceMosaicOn: faceMosaicOn,
            objectMosaicOn: objectMosaicOn,
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            objectMasks: objectMasks,
            faceSelections: faceSelections,
            personProfiles: personProfiles,
            thumbnailFileName: thumbName
        )
        if let index = videoDrafts.firstIndex(where: { $0.id == draft.id }) {
            videoDrafts[index] = draft
        } else {
            videoDrafts.insert(draft, at: 0)
        }
        saveVideoIndex()
        collectGarbage(protecting: sessionSourceIDs)
        return draft
    }

    // フェーズ2でこのファイルに本格的に手を入れる際に解消する予定の構造的負債
    // swiftlint:disable function_parameter_count
    /// Saves / replaces the photo draft (writes the source image as JPEG).
    func savePhotoDraft(
        existing: UUID?,
        image: UIImage,
        faceMosaicOn: Bool,
        objectMosaicOn: Bool = true,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        objectMasks: [ObjectMask],
        faceSelections: [DraftFaceSelection]? = nil,
        personProfiles: [PersonProfile]? = nil,
        photoEdit: PhotoEditState = .identity
    ) {
        let id = existing ?? photoDraft?.id ?? UUID()
        let fileName = "photo-\(id.uuidString).jpg"
        let url = directory.appendingPathComponent(fileName)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: url, options: .atomic)
        photoDraft = EditingDraft(
            id: id,
            kind: .photo,
            sourceFileName: fileName,
            faceMosaicOn: faceMosaicOn,
            objectMosaicOn: objectMosaicOn,
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            objectMasks: objectMasks,
            faceSelections: faceSelections,
            personProfiles: personProfiles,
            photoEdit: photoEdit,
            thumbnailFileName: nil
        )
        savePhotoIndex()
    }
    // swiftlint:enable function_parameter_count

    // MARK: - Delete

    func removeVideoDraft(_ draft: EditingDraft) {
        videoDrafts.removeAll { $0.id == draft.id }
        // 素材ファイルは直接消さず GC に委ねる: v2 では複数の下書きが同一素材コピーを
        // 共有し得るため、直接削除すると他の下書きの素材を壊す。サムネイルは
        // 下書きごとに固有（thumb-<draftID>）なので直接消してよい。
        if let thumb = draft.thumbnailFileName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(thumb))
        }
        saveVideoIndex()
        collectGarbage()
    }

    func deletePhotoDraft() {
        if let draft = photoDraft {
            deleteFiles(for: draft)
        }
        photoDraft = nil
        try? fileManager.removeItem(at: photoIndexURL)
    }

    /// Called at launch: the photo draft must not survive a user force-quit.
    /// `@SceneStorage` is cleared by the OS on force-quit, so when the live
    /// session flag is `false` at launch we discard any lingering photo draft.
    func reconcile(photoSessionActive: Bool) {
        if !photoSessionActive {
            deletePhotoDraft()
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: videoIndexURL) {
            videoDrafts = Self.decodeDraftsIndividually(data)
        }
        if let data = try? Data(contentsOf: photoIndexURL),
           let decoded = try? JSONDecoder().decode(EditingDraft.self, from: data) {
            photoDraft = decoded
        }
    }

    /// 下書き index を **1 件ずつ**デコードする。
    ///
    /// `[EditingDraft].self` の一括デコードにしてはいけない。1 件が壊れているだけで
    /// 配列全体が失敗し、`try?` に握り潰されて**全下書きが消え**、次の保存で
    /// `[]` が上書きされて永久に復旧できなくなる（`ObjectMask.init(from:)` は
    /// 不変条件違反で throw する設計なので、この受け皿が全滅では意味が逆転する）。
    /// 壊れた 1 件だけ捨てて残りを生かす。
    private static func decodeDraftsIndividually(_ data: Data) -> [EditingDraft] {
        let decoder = JSONDecoder()
        guard let elements = try? decoder.decode([AnyDraftElement].self, from: data) else { return [] }
        return elements.compactMap { $0.draft }
    }

    /// 配列要素を 1 件ずつ受けるための箱。デコードに失敗しても**その要素だけ** nil になり、
    /// 配列のデコード自体は成功する（`Decodable` の合成では要素の失敗が配列全体を落とす）。
    private struct AnyDraftElement: Decodable {
        let draft: EditingDraft?
        init(from decoder: Decoder) throws {
            draft = try? EditingDraft(from: decoder)
        }
    }

    private func saveVideoIndex() {
        guard let data = try? JSONEncoder().encode(videoDrafts) else { return }
        try? data.write(to: videoIndexURL, options: .atomic)
    }

    private func savePhotoIndex() {
        guard let draft = photoDraft, let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: photoIndexURL, options: .atomic)
    }

    // MARK: - Files

    /// 素材ファイルを下書きフォルダへ登録し、ファイル名を返す。
    ///
    /// - 既に下書きフォルダ内のファイル（下書き再開で読み込んだ素材。v1 の
    ///   `source-<draftID>` 命名を含む）はコピーせずそのまま参照する。
    /// - それ以外は `source-<sourceID>.<ext>` へコピーする。素材ID単位の命名なので、
    ///   同一素材を参照する複数下書きは 1 コピーを共有し、再保存は既存コピーを
    ///   使い回す（同一素材IDで中身が変わることはない: 素材IDはロードごとに新規発行）。
    private func registerSource(_ url: URL, sourceID: UUID) -> String? {
        if url.standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path {
            // 防波堤: フォルダ内 URL でも実体が消えていたら参照登録しない
            // （存在しないファイルを指す壊れた下書きを書かない）。nil を返して
            // 保存全体を失敗させる（コピー経路に回しても複製元が無く失敗する）。
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return url.lastPathComponent
        }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let name = "source-\(sourceID.uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: dest.path) {
            return name   // already copied for this source
        }
        do {
            try fileManager.copyItem(at: url, to: dest)
            return name
        } catch {
            return nil
        }
    }

    /// どの下書きからも参照されなくなった素材コピー（`source-*`）を削除する。
    ///
    /// 呼ぶのは**下書きの保存・削除時のみ**。削除対象は「どの下書きの `sources` にも
    /// 現れず、かつ `protecting`（保存を要求した編集セッションが undo/redo で
    /// 復活し得るものも含めて参照中の素材ID）にも該当しないコピー」だけ。
    /// 下書き再開中のセッションは素材 URL として下書きフォルダ内のコピーそのものを
    /// 参照しているため、下書きの参照だけを根拠に消すと undo で復活するクリップの
    /// 実体を失う（保護リストが無いと発生する実測済みの欠陥）。
    /// `source-` プレフィックス以外（写真下書き `photo-*`・サムネ `thumb-*`・索引 JSON）
    /// には触れない。
    private func collectGarbage(protecting sessionSourceIDs: Set<UUID> = []) {
        var referenced = Set<String>()
        for draft in videoDrafts {
            referenced.insert(draft.sourceFileName)
            referenced.formUnion(draft.sources.map(\.fileName))
        }
        if let photo = photoDraft {
            referenced.insert(photo.sourceFileName)
            referenced.formUnion(photo.sources.map(\.fileName))
        }
        // セッション参照分を合流: コピーは素材ID単位の命名（source-<sourceID>.<ext>、
        // registerSource 参照）なので、素材IDから名前プレフィックスで対応付ける。
        let protectedPrefixes = sessionSourceIDs.map { "source-\($0.uuidString)." }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where name.hasPrefix("source-")
            && !referenced.contains(name)
            && !protectedPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func writeThumbnail(_ image: UIImage?, reuse: UUID?) -> String? {
        guard let image, let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let name = "thumb-\(reuse?.uuidString ?? UUID().uuidString).jpg"
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        return name
    }

    private func deleteFiles(for draft: EditingDraft) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(draft.sourceFileName))
        if let thumb = draft.thumbnailFileName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(thumb))
        }
    }

    private func createDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// tmp に溜まる中間ファイル（`picked-*` / `photoclip-*` / `mosaic-*`）の掃除。
///
/// `DraftStore` と同じ「ファイルの寿命を管理する」責務なのでここに同居させている。
/// 判定は `MosaicCore.TempFileSweeper.shouldDelete` が単一情報源で、ここは列挙と削除だけ。
///
/// ⚠️ **age ベース（既定 24 時間）でしか消さない。即時削除はできない。**
/// - `picked-*` / `photoclip-*` は編集セッション中ずっと `sources[sourceID]` の
///   `AVURLAsset` の実体であり、AVFoundation は遅延読みするのでセッション中に消せない。
/// - 下書き保存時に `DraftStore.registerSource` が tmp → `Documents/Drafts` へコピーするため、
///   「コピーが済んだか」は下書き保存の成否に依存し、editor 離脱時点では確定できない。
/// - undo で復活し得るクリップの素材も保持が要る。
///
/// ⚠️ 掃除対象は `FileManager.default.temporaryDirectory` **だけ**。
/// `Documents/Drafts`（`source-*` / `thumb-*` / 索引 JSON = 下書きの実体）へ向けてはならない。
enum TempMediaJanitor {
    /// 期限切れの中間ファイルを削除し、削除した件数を返す。
    ///
    /// 起動パスを同期 IO で塞がないよう、呼び出し側はバックグラウンドで実行すること
    /// （`MaskMeApp` の `.onAppear`）。
    @discardableResult
    static func sweep(directory: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date(),
                      maxAge: TimeInterval = TempFileSweeper.defaultMaxAge,
                      fileManager: FileManager = .default) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for url in entries {
            // 更新日時が読めないものは「判断がつかない」ので残す（Sweeper と同じ倒し方）。
            guard let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
                  TempFileSweeper.shouldDelete(name: url.lastPathComponent,
                                               modifiedAt: modified, now: now, maxAge: maxAge)
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
