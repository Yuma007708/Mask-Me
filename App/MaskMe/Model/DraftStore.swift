import UIKit

/// A persisted "work in progress" edit. Video drafts are durable (survive a
/// force-quit) so the user can resume from the Home list; the photo draft is
/// retained only across a normal background/return and is discarded on a
/// force-quit (see ``DraftStore/reconcile(photoSessionActive:)``).
struct EditingDraft: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: MediaKind
    /// File name (in Documents/Drafts) of the copied source media.
    let sourceFileName: String
    let blockSize: Float
    let faceEnabled: Bool
    /// Manual mosaic rectangles, in normalized [0,1] coordinates.
    let manualRects: [CGRect]
    let thumbnailFileName: String?
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        sourceFileName: String,
        blockSize: Float,
        faceEnabled: Bool,
        manualRects: [CGRect],
        thumbnailFileName: String?,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sourceFileName = sourceFileName
        self.blockSize = blockSize
        self.faceEnabled = faceEnabled
        self.manualRects = manualRects
        self.thumbnailFileName = thumbnailFileName
        self.updatedAt = updatedAt
    }
}

/// Stores editing drafts (source media + parameters) under Documents/Drafts.
@MainActor
public final class DraftStore: ObservableObject {
    /// Resumable video drafts, newest first.
    @Published public private(set) var videoDrafts: [EditingDraft] = []
    /// The single in-progress photo draft, if any.
    @Published public private(set) var photoDraft: EditingDraft?

    private let fileManager: FileManager
    private let directory: URL
    private let videoIndexURL: URL
    private let photoIndexURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = documents.appendingPathComponent("Drafts", isDirectory: true)
        self.videoIndexURL = directory.appendingPathComponent("video_drafts.json")
        self.photoIndexURL = directory.appendingPathComponent("photo_draft.json")
        createDirectoryIfNeeded()
        load()
    }

    // MARK: - Source URLs

    func sourceURL(for draft: EditingDraft) -> URL {
        directory.appendingPathComponent(draft.sourceFileName)
    }

    func thumbnail(for draft: EditingDraft) -> UIImage? {
        guard let name = draft.thumbnailFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Save

    /// Saves / updates a video draft (copying the source video for durability).
    @discardableResult
    func saveVideoDraft(
        existing: UUID?,
        sourceURL: URL,
        blockSize: Float,
        faceEnabled: Bool,
        manualRects: [CGRect],
        thumbnail: UIImage?
    ) -> EditingDraft? {
        guard let sourceFileName = copySource(sourceURL, ext: "mov", reuse: existing) else { return nil }
        let thumbName = writeThumbnail(thumbnail, reuse: existing)
        let draft = EditingDraft(
            id: existing ?? UUID(),
            kind: .video,
            sourceFileName: sourceFileName,
            blockSize: blockSize,
            faceEnabled: faceEnabled,
            manualRects: manualRects,
            thumbnailFileName: thumbName
        )
        if let index = videoDrafts.firstIndex(where: { $0.id == draft.id }) {
            videoDrafts[index] = draft
        } else {
            videoDrafts.insert(draft, at: 0)
        }
        saveVideoIndex()
        return draft
    }

    /// Saves / replaces the photo draft (writes the source image as JPEG).
    func savePhotoDraft(
        existing: UUID?,
        image: UIImage,
        blockSize: Float,
        faceEnabled: Bool,
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
            blockSize: blockSize,
            faceEnabled: faceEnabled,
            manualRects: manualRects,
            thumbnailFileName: nil
        )
        savePhotoIndex()
    }

    // MARK: - Delete

    func removeVideoDraft(_ draft: EditingDraft) {
        videoDrafts.removeAll { $0.id == draft.id }
        deleteFiles(for: draft)
        saveVideoIndex()
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

    private func copySource(_ url: URL, ext: String, reuse: UUID?) -> String? {
        let name = "source-\(reuse?.uuidString ?? UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: dest.path) {
            return name   // already copied for this draft
        }
        do {
            try fileManager.copyItem(at: url, to: dest)
            return name
        } catch {
            return nil
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
