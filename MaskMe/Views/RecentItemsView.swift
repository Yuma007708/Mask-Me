import SwiftUI

/// Vertically scrolling list of recently processed items. Each row shows a
/// thumbnail; rows support swipe-to-delete. Tapping a row previews the saved
/// result thumbnail.
struct RecentItemsView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @EnvironmentObject private var draftStore: DraftStore
    @State private var previewItem: RecentItem?

    /// 動画の「編集中」下書きをタップしたときに呼ばれる（再開導線）。
    var onResumeDraft: (EditingDraft) -> Void = { _ in }

    private var isEmpty: Bool {
        recents.items.isEmpty && draftStore.videoDrafts.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
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
            if !draftStore.videoDrafts.isEmpty {
                Section("編集中") {
                    ForEach(draftStore.videoDrafts) { draft in
                        Button { onResumeDraft(draft) } label: {
                            DraftRowView(draft: draft, thumbnail: draftStore.thumbnail(for: draft))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                draftStore.removeVideoDraft(draft)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !recents.items.isEmpty {
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

/// One row representing a resumable video draft ("編集中").
private struct DraftRowView: View {
    let draft: EditingDraft
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(draft.kind.label)
                        .font(.headline)
                    Text("編集中")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.uturn.left.circle")
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
                .overlay(Image(systemName: draft.kind.symbolName))
        }
    }
}
