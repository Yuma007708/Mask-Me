import SwiftUI

/// プレビュー上に重ねるジェスチャーオーバーレイ。
/// ドラッグで矩形を描き、完了時に model.detectInRegion() を呼ぶ。
struct RectangleDrawingOverlay: View {
    @ObservedObject var model: MosaicEditorModel
    /// ドラッグ中の矩形（画面座標）
    @State private var dragging: CGRect?
    @State private var startLocation: CGPoint = .zero
    @State private var isDetecting = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ドラッグ中の矩形プレビュー
                if let rect = dragging {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red, lineWidth: 2)
                        .background(Color.red.opacity(0.1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                // 既存の手動矩形をオーバーレイ表示
                ForEach(model.manualRegions) { region in
                    let r = previewRect(from: region.normalizedRect, in: geo.size)
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange, lineWidth: 2)
                            .background(Color.orange.opacity(0.08))
                            .frame(width: r.width, height: r.height)

                        Button {
                            model.removeManualRegion(region.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .red)
                                .font(.system(size: 16))
                        }
                        .offset(x: 8, y: -8)
                    }
                    .position(x: r.midX, y: r.midY)
                }

                // 検出中インジケーター
                if isDetecting {
                    ProgressView()
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                // ドラッグジェスチャー（透明レイヤー）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let origin = CGPoint(
                                    x: min(value.startLocation.x, value.location.x),
                                    y: min(value.startLocation.y, value.location.y)
                                )
                                let size = CGSize(
                                    width: abs(value.location.x - value.startLocation.x),
                                    height: abs(value.location.y - value.startLocation.y)
                                )
                                dragging = CGRect(origin: origin, size: size)
                            }
                            .onEnded { value in
                                guard let rect = dragging, rect.width > 10, rect.height > 10 else {
                                    dragging = nil
                                    return
                                }
                                dragging = nil
                                let normalized = normalizedRect(from: rect, in: geo.size)
                                isDetecting = true
                                Task {
                                    await model.detectInRegion(normalized)
                                    isDetecting = false
                                }
                            }
                    )
            }
        }
    }

    // プレビュー領域内の正規化座標 → 画面座標
    private func previewRect(from normalized: CGRect, in size: CGSize) -> CGRect {
        let (imageRect, _) = imageRectInPreview(size: size)
        return CGRect(
            x: imageRect.origin.x + normalized.origin.x * imageRect.width,
            y: imageRect.origin.y + normalized.origin.y * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    // 画面座標 → 画像正規化座標（scaledToFit 表示を考慮）
    private func normalizedRect(from rect: CGRect, in containerSize: CGSize) -> CGRect {
        let (imageRect, _) = imageRectInPreview(size: containerSize)
        let clipped = rect.intersection(imageRect)
        return CGRect(
            x: (clipped.origin.x - imageRect.origin.x) / imageRect.width,
            y: (clipped.origin.y - imageRect.origin.y) / imageRect.height,
            width: clipped.width / imageRect.width,
            height: clipped.height / imageRect.height
        )
    }

    /// プレビューコンテナ内で画像が占める矩形を計算（scaledToFit 相当）。
    private func imageRectInPreview(size: CGSize) -> (imageRect: CGRect, imageSize: CGSize) {
        guard let img = model.previewImage else {
            return (CGRect(origin: .zero, size: size), size)
        }
        let iw = img.size.width
        let ih = img.size.height
        let scale = min(size.width / iw, size.height / ih)
        let fw = iw * scale
        let fh = ih * scale
        let origin = CGPoint(x: (size.width - fw) / 2, y: (size.height - fh) / 2)
        return (CGRect(x: origin.x, y: origin.y, width: fw, height: fh), CGSize(width: fw, height: fh))
    }
}
