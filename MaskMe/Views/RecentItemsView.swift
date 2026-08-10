import SwiftUI

/// ホームの作品置き場。「編集中」（下書き）と「最近使ったもの」を 2 列のグリッドで並べる。
///
/// ## 写真の下書きもここに出す
///
/// **旧 UI は `videoDrafts` しか見ておらず、写真の下書きは保存されているのに
/// 画面から辿れなかった**（`DraftStore.savePhotoDraft` は動いていて、
/// `EditorView` の `@SceneStorage("photoEditingActive")` による復帰判定まで
/// 用意されているのに、再開する導線だけが無い状態）。ここで `photoDraft` を
/// 同じ「編集中」の枠に出して塞ぐ。
///
/// 写真の下書きは**常に高々 1 件**（`DraftStore.photoDraft` は単数）で、
/// 強制終了では破棄される（`DraftStore.reconcile(photoSessionActive:)`）。
/// 動画の下書きは複数・強制終了でも残る。この非対称は仕様なので、
/// 画面では「編集中」として同じ見た目で並べつつ、削除の作法だけ分ける。
struct RecentItemsView: View {
    @EnvironmentObject private var recents: RecentItemsStore
    @EnvironmentObject private var draftStore: DraftStore
    @State private var previewItem: RecentItem?

    /// 「編集中」をタップしたときに呼ばれる（再開導線）。写真・動画の
    /// どちらも同じ入口を通し、種別の分岐は受け手（`HomeView.resume`）が持つ。
    var onResumeDraft: (EditingDraft) -> Void = { _ in }

    /// 画面に出す下書き。**写真を先頭へ置く**（写真の下書きは 1 件しか持てず、
    /// 上書きされると消えるので、いちばん見つけやすい位置に出す）。
    private var drafts: [EditingDraft] {
        var all: [EditingDraft] = []
        if let photo = draftStore.photoDraft { all.append(photo) }
        all.append(contentsOf: draftStore.videoDrafts)
        return all
    }

    private var isEmpty: Bool { recents.items.isEmpty && drafts.isEmpty }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .sheet(item: $previewItem) { item in
            previewSheet(for: item)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !drafts.isEmpty {
                    section(title: "編集中") {
                        ForEach(drafts) { draft in
                            Button { onResumeDraft(draft) } label: {
                                DraftCard(draft: draft, thumbnail: draftStore.thumbnail(for: draft))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { delete(draft) } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !recents.items.isEmpty {
                    section(title: "最近使ったもの") {
                        ForEach(recents.items) { item in
                            Button { previewItem = item } label: {
                                RecentCard(item: item, thumbnail: recents.thumbnail(for: item))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { recents.remove(item) } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// 見出し ＋ 2 列グリッドの組。見出しの体裁を 1 箇所に閉じ込める。
    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(AppTheme.inkDim)
            LazyVGrid(columns: columns, spacing: 12) { content() }
        }
    }

    /// **写真の下書きは `deletePhotoDraft`、動画は `removeVideoDraft`。**
    /// 写真は単数で保管の作法が違う（インデックスファイルごと消す）ため、
    /// 同じ関数では消せない。
    private func delete(_ draft: EditingDraft) {
        if draft.kind == .photo {
            draftStore.deletePhotoDraft()
        } else {
            draftStore.removeVideoDraft(draft)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppTheme.inkDim)
            Text("まだ作品がありません")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Text("「新しく作る」から写真・動画を選ぶか、\nその場で撮って始められます。")
                .font(.footnote)
                .foregroundStyle(AppTheme.inkDim)
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
        .background(AppTheme.background)
    }
}

// MARK: - カード

/// サムネイル＋説明の共通の器。**枠と角丸と縁をここ 1 箇所で決める**
/// （カードごとに書くと、種類が増えたとき縁の太さだけ揃わなくなる）。
private struct MediaCard<Overlay: View, Caption: View>: View {
    let thumbnail: UIImage?
    let fallbackSymbol: String
    @ViewBuilder let overlay: Overlay
    @ViewBuilder let caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                thumbnailView
                overlay.padding(7)
            }
            caption
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 9)
        }
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        // **`aspectRatio(contentMode: .fill)` + `clipped()` にする。**
        // `frame(height:)` だけだと、縦長のサムネイルが枠からはみ出したまま
        // 次のカードに重なる（グリッドは高さを揃えないため）。
        Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    AppTheme.surfaceDim
                        .overlay(
                            Image(systemName: fallbackSymbol)
                                .font(.system(size: 22))
                                .foregroundStyle(AppTheme.inkDim)
                        )
                }
            }
            .clipped()
    }
}

/// 再開できる下書き（写真・動画）のカード。
private struct DraftCard: View {
    let draft: EditingDraft
    let thumbnail: UIImage?

    var body: some View {
        MediaCard(thumbnail: thumbnail, fallbackSymbol: draft.kind.symbolName) {
            Text("編集中")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.onAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AppTheme.accent, in: Capsule())
        } caption: {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.kind.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.inkDim)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.draftCard")
        .accessibilityLabel("編集中の\(draft.kind.label)を再開")
    }
}

/// 書き出し済みの作品のカード。
private struct RecentCard: View {
    let item: RecentItem
    let thumbnail: UIImage?

    var body: some View {
        MediaCard(thumbnail: thumbnail, fallbackSymbol: item.kind.symbolName) {
            Image(systemName: item.kind.symbolName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Color.black.opacity(0.45), in: Circle())
        } caption: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.inkDim)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.recentCard")
    }
}
