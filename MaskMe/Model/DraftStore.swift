import UIKit
import MosaicCore

/// 下書きが参照する素材 1 件のメタ情報（v2）。
///
/// `id` はモデルの素材ID（`TimelineClip.sourceID`）と一致させる。復元時に
/// タイムラインのクリップと素材ファイルを結び付けるキーになる。
struct DraftSource: Codable, Equatable, Hashable {
    let id: UUID
    /// Documents/Drafts 内のコピー済み素材ファイル名。
    let fileName: String
}

/// A persisted "work in progress" edit. Video drafts are durable (survive a
/// force-quit) so the user can resume from the Home list; the photo draft is
/// retained only across a normal background/return and is discarded on a
/// force-quit (see ``DraftStore/reconcile(photoSessionActive:)``).
struct EditingDraft: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: MediaKind
    /// File name (in Documents/Drafts) of the copied source media.
    /// v2 でも「primary（再開時に最初へロードする素材）」として維持する。
    let sourceFileName: String
    /// 参照する全素材（v2）。v1 下書きは `sourceFileName` 1 件に合成される。
    let sources: [DraftSource]
    /// タイムライン（v2）。`clips` が空なら「素材全体 1 クリップ」の意味
    /// （v1 下書き・クリップ構築前の保存）。復元時は `load(videoURL:)` の
    /// 既定経路がそのまま素材全体 1 クリップを構築する。
    let timeline: TimelineState
    let faceMosaicOn: Bool
    let backgroundMosaicOn: Bool
    let faceBlockSize: Float
    let backgroundBlockSize: Float
    /// Manual mosaic rectangles, in normalized [0,1] coordinates.
    let manualRects: [CGRect]
    let thumbnailFileName: String?
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        sourceFileName: String,
        sources: [DraftSource]? = nil,
        timeline: TimelineState = TimelineState(),
        faceMosaicOn: Bool,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect],
        thumbnailFileName: String?,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sourceFileName = sourceFileName
        self.sources = sources ?? [DraftSource(id: UUID(), fileName: sourceFileName)]
        self.timeline = timeline
        self.faceMosaicOn = faceMosaicOn
        self.backgroundMosaicOn = backgroundMosaicOn
        self.faceBlockSize = faceBlockSize
        self.backgroundBlockSize = backgroundBlockSize
        self.manualRects = manualRects
        self.thumbnailFileName = thumbnailFileName
        self.updatedAt = updatedAt
    }

    /// `sourceFileName`（再開時に最初へロードする素材）に対応する素材メタ。
    var primarySource: DraftSource? {
        sources.first { $0.fileName == sourceFileName } ?? sources.first
    }

    // 現行スキーマのキー（Encodable はこれで自動合成される）。
    private enum CodingKeys: String, CodingKey {
        case id, kind, sourceFileName, manualRects, thumbnailFileName, updatedAt
        case faceMosaicOn, backgroundMosaicOn, faceBlockSize, backgroundBlockSize
        case sources, timeline
    }

    // 旧スキーマ（後方互換デコード専用）。
    private enum LegacyKeys: String, CodingKey {
        case blockSize, faceEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        sourceFileName = try c.decode(String.self, forKey: .sourceFileName)
        manualRects = try c.decodeIfPresent([CGRect].self, forKey: .manualRects) ?? []
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // v2 フィールド。v1（キー無し）は「素材全体 1 クリップ」へ合成する:
        // - sources: 唯一の素材（sourceFileName）1 件。id はこの場で新規発行する
        //   （v1 に素材IDは存在しない。復元フローは同一デコード結果の id を
        //   一貫して使うため、値そのものは何でもよい）。
        // - timeline: 空 = 素材全体 1 クリップの意味（素材尺はデコード時点では
        //   不明なので有限のクリップは作れない。復元時に load の既定経路が
        //   実尺で構築する）。
        sources = try c.decodeIfPresent([DraftSource].self, forKey: .sources)
            ?? [DraftSource(id: UUID(), fileName: sourceFileName)]
        timeline = try c.decodeIfPresent(TimelineState.self, forKey: .timeline) ?? TimelineState()

        // 旧フィールド（存在すれば）。
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let legacyFaceEnabled = (try? legacy?.decodeIfPresent(Bool.self, forKey: .faceEnabled)).flatMap { $0 }
        let legacyBlock = (try? legacy?.decodeIfPresent(Float.self, forKey: .blockSize)).flatMap { $0 }

        // 新フィールド優先 → 旧フィールド → 既定値。
        faceMosaicOn = try c.decodeIfPresent(Bool.self, forKey: .faceMosaicOn)
            ?? legacyFaceEnabled ?? true
        backgroundMosaicOn = try c.decodeIfPresent(Bool.self, forKey: .backgroundMosaicOn) ?? false
        faceBlockSize = try c.decodeIfPresent(Float.self, forKey: .faceBlockSize)
            ?? legacyBlock ?? 28
        backgroundBlockSize = try c.decodeIfPresent(Float.self, forKey: .backgroundBlockSize) ?? 28
    }
}

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
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect],
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
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            manualRects: manualRects,
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
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect]
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
            backgroundMosaicOn: backgroundMosaicOn,
            faceBlockSize: faceBlockSize,
            backgroundBlockSize: backgroundBlockSize,
            manualRects: manualRects,
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
        if let data = try? Data(contentsOf: videoIndexURL),
           let decoded = try? JSONDecoder().decode([EditingDraft].self, from: data) {
            videoDrafts = decoded
        }
        if let data = try? Data(contentsOf: photoIndexURL),
           let decoded = try? JSONDecoder().decode(EditingDraft.self, from: data) {
            photoDraft = decoded
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
