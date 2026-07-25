import AVFoundation
import SwiftUI

/// CapCut/iMovie 風の動画タイムライン。
///
/// - サムネイル列（`AVAssetImageGenerator` で非同期生成、既定 24 枚）
/// - プレイヘッド（縦線 + 現在時刻）: `model.playbackPosition` に追従
/// - スクラブ: 横ドラッグで `seekToLatest`（最新1件のみ処理）
/// - In/Out トリムハンドル: 左右端をドラッグして `model.trimRange` を更新、
///   範囲外は暗くマスク表示
struct VideoTimelineView: View {
    @ObservedObject var model: MosaicEditorModel

    /// サムネイル並び。初回ロードで非同期に埋まる。
    @State private var thumbnails: [UIImage] = []
    /// 最後に読み込んだ動画 URL（差し替え検知用）。
    @State private var loadedURL: URL?

    /// トリムハンドルの太さ。ドラッグ判定領域も兼ねる。
    private let handleWidth: CGFloat = 12
    /// タイムラインの高さ。
    private let timelineHeight: CGFloat = 56
    /// サムネイル生成枚数。
    private let thumbnailCount = 24

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // MARK: サムネイル列
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Rectangle().fill(Color.black.opacity(0.4))
                    } else {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(uiImage: thumbnails[i])
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: width / CGFloat(thumbnails.count),
                                    height: timelineHeight
                                )
                                .clipped()
                        }
                    }
                }
                .frame(height: timelineHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // MARK: トリム範囲外のマスク（左右）
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, CGFloat(model.trimRange.lowerBound) * width))
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: max(0, (1 - CGFloat(model.trimRange.upperBound)) * width))
                }
                .frame(height: timelineHeight)
                .allowsHitTesting(false)

                // MARK: トリム範囲の枠（黄色）
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.yellow, lineWidth: 2)
                    .frame(
                        width: max(handleWidth * 2,
                                   CGFloat(model.trimRange.upperBound - model.trimRange.lowerBound) * width),
                        height: timelineHeight
                    )
                    .offset(x: CGFloat(model.trimRange.lowerBound) * width)
                    .allowsHitTesting(false)

                // MARK: 左トリムハンドル
                trimHandle(isLeft: true, width: width)

                // MARK: 右トリムハンドル
                trimHandle(isLeft: false, width: width)

                // MARK: プレイヘッド
                let playX = CGFloat(model.playbackPosition) * width
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: timelineHeight + 8)
                    .offset(x: max(0, min(width - 2, playX)) - 1, y: -4)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .allowsHitTesting(false)
            }
            .frame(height: timelineHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // タイムライン中央部（トリムハンドル外）でのドラッグはスクラブ。
                        let x = max(0, min(width, value.location.x))
                        let position = Double(x / width)
                        // トリム範囲内にクランプ（範囲外にはシーク不可）
                        let clamped = min(max(position, model.trimRange.lowerBound), model.trimRange.upperBound)
                        model.seekToLatest(position: clamped)
                    }
            )
        }
        .frame(height: timelineHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onAppear { reloadThumbnailsIfNeeded() }
        .onChange(of: model.sourceVideoURL) { _ in reloadThumbnailsIfNeeded() }
    }

    // MARK: - トリムハンドル

    @ViewBuilder
    private func trimHandle(isLeft: Bool, width: CGFloat) -> some View {
        let position = isLeft ? model.trimRange.lowerBound : model.trimRange.upperBound
        let xOffset = CGFloat(position) * width - (isLeft ? 0 : handleWidth)

        RoundedRectangle(cornerRadius: 2)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: timelineHeight + 4)
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 2, height: 20)
            )
            .offset(x: xOffset, y: -2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = max(0, min(width, value.location.x))
                        let raw = Double(x / width)
                        let minGap = 0.02  // トリム範囲最小 2%（極端に狭いレンジで書き出し破綻を防ぐ）
                        if isLeft {
                            let newLower = min(raw, model.trimRange.upperBound - minGap)
                            model.trimRange = max(0, newLower)...model.trimRange.upperBound
                        } else {
                            let newUpper = max(raw, model.trimRange.lowerBound + minGap)
                            model.trimRange = model.trimRange.lowerBound...min(1, newUpper)
                        }
                    }
                    .onEnded { _ in
                        // ドラッグ確定時のみ履歴へ積む（onChanged ごとに積むと
                        // 1 ドラッグが無数の undo ステップに割れる）。
                        model.commitEdit()
                    }
            )
    }

    // MARK: - サムネイル生成

    private func reloadThumbnailsIfNeeded() {
        guard let url = model.sourceVideoURL, url != loadedURL else { return }
        loadedURL = url
        thumbnails = []
        Task {
            let generated = await generateThumbnails(for: url, count: thumbnailCount)
            await MainActor.run { self.thumbnails = generated }
        }
    }

    private func generateThumbnails(for url: URL, count: Int) async -> [UIImage] {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else { return [] }
        var out: [UIImage] = []
        for i in 0..<count {
            let t = Double(i) / Double(max(count - 1, 1)) * duration
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: cm, actualTime: nil) {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }
}
