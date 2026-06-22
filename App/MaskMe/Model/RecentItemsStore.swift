import UIKit

/// The kind of media a recent item represents.
public enum MediaKind: String, Codable {
    case photo
    case video

    var symbolName: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        }
    }

    var label: String {
        switch self {
        case .photo: return "写真"
        case .video: return "動画"
        }
    }
}

/// A previously processed item shown in the Home "最近の項目" list.
public struct RecentItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public let kind: MediaKind
    public let createdAt: Date
    /// File name (in Documents) of the saved output, when available.
    public let outputFileName: String?
    /// File name (in Documents/Thumbnails) of the preview thumbnail.
    public let thumbnailFileName: String

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        createdAt: Date = Date(),
        outputFileName: String? = nil,
        thumbnailFileName: String
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.outputFileName = outputFileName
        self.thumbnailFileName = thumbnailFileName
    }
}

/// Persists recent items to the app's Documents directory (a JSON index plus
/// thumbnail image files) and exposes them to SwiftUI.
@MainActor
public final class RecentItemsStore: ObservableObject {
    @Published public private(set) var items: [RecentItem] = []

    private let fileManager: FileManager
    private let indexURL: URL
    private let thumbnailsDirectory: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.indexURL = documents.appendingPathComponent("recent_items.json")
        self.thumbnailsDirectory = documents.appendingPathComponent("Thumbnails", isDirectory: true)
        createThumbnailsDirectoryIfNeeded()
        load()
    }

    // MARK: - Mutations

    /// Saves a thumbnail and prepends a new recent item.
    @discardableResult
    public func add(
        kind: MediaKind,
        thumbnail: UIImage,
        outputFileName: String? = nil
    ) -> RecentItem? {
        let thumbnailFileName = "\(UUID().uuidString).jpg"
        let url = thumbnailsDirectory.appendingPathComponent(thumbnailFileName)
        guard let data = thumbnail.jpegData(compressionQuality: 0.8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let item = RecentItem(
            kind: kind,
            outputFileName: outputFileName,
            thumbnailFileName: thumbnailFileName
        )
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Removes the items at the given list offsets (for `List.onDelete`).
    public func remove(atOffsets offsets: IndexSet) {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)
        removed.forEach(deleteFiles(for:))
        save()
    }

    /// Removes a specific item (for `swipeActions`).
    public func remove(_ item: RecentItem) {
        guard let index = items.firstIndex(of: item) else { return }
        items.remove(at: index)
        deleteFiles(for: item)
        save()
    }

    // MARK: - Reads

    public func thumbnail(for item: RecentItem) -> UIImage? {
        let url = thumbnailsDirectory.appendingPathComponent(item.thumbnailFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func deleteFiles(for item: RecentItem) {
        let thumbURL = thumbnailsDirectory.appendingPathComponent(item.thumbnailFileName)
        try? fileManager.removeItem(at: thumbURL)
    }

    private func createThumbnailsDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: thumbnailsDirectory.path) else { return }
        try? fileManager.createDirectory(
            at: thumbnailsDirectory,
            withIntermediateDirectories: true
        )
    }
}
