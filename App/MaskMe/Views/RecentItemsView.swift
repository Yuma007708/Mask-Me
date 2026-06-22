import SwiftUI

/// Vertically scrolling list of recently processed items. Each row shows a
/// thumbnail; rows support swipe-to-delete. Tapping a row previews the saved
/// result thumbnail.
struct RecentItemsView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @State private var previewItem: RecentItem?

    var body: some View {
        Group {
            if recents.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .sheet(item: $previewItem) { item in
            previewSheet(for: item)
        }
    }

    private var list: some View {
        List {
            Section("最近の項目") {
                ForEach(recents.items) { item in
                    Button { previewItem = item } label: {
                        RecentRowView(item: item, thumbnail: recents.thumbnail(for: item))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            recents.remove(item)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    recents.remove(atOffsets: offsets)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("最近の項目はありません")
                .foregroundStyle(.secondary)
            Text("写真・動画を編集すると、ここに表示されます。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private func previewSheet(for item: RecentItem) -> some View {
        VStack {
            if let image = recents.thumbnail(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            Button("閉じる") { previewItem = nil }
                .padding()
        }
    }
}

/// One row in the recent-items list.
private struct RecentRowView: View {
    let item: RecentItem
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind.label)
                    .font(.headline)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: item.kind.symbolName))
        }
    }
}
