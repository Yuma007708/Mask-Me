import SwiftUI

/// プレビュー上に重ねるジェスチャーオーバーレイ。
/// ドラッグで矩形を描き、完了時に model.detectInRegion() を呼ぶ。
///
/// **ドラッグ面を張るのは矩形ツールが ON のときだけ**
/// （`MosaicEditorModel.isRectangleToolActive`）。常時張っていた頃は、プレビューを
/// 少しなぞっただけで矩形ができてしまい「間違えて指定して使いづらい」状態だった。
/// 既存の矩形（と削除ボタン）は OFF でも出す: 何が掛かっているかは常に見えていないと
/// 消す手段が無くなる。
struct RectangleDrawingOverlay: View {
    @ObservedObject var model: MosaicEditorModel
    /// ドラッグ中の矩形（画面座標）
    @State private var dragging: CGRect?
    @State private var startLocation: CGPoint = .zero
    @State private var isDetecting = false
    /// ドラッグして動かしている最中のマスクと、その移動量（画面座標）。
    @State private var movingMaskID: UUID?
    @State private var moveOffset: CGSize = .zero

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

                // 検出中インジケーター
                if isDetecting {
                    ProgressView()
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                // ドラッグジェスチャー（透明レイヤー）。**ツール ON のときだけ張る。**
                if model.isRectangleToolActive {
                    drawingSurface(in: geo.size)
                }

                // 既存の物体マスクをオーバーレイ表示。**描画面より上に置く**ので、
                // 矩形ツール ON でもマスクの上のドラッグは「移動」になる
                // （空いている所をドラッグすれば従来どおり新規作成）。
                //
                // **`objectMasks` を直接 `ForEach` しないこと**: 矩形はキーフレーム補間で
                // 時刻ごとに変わるので、シークしても枠が動かなくなる。
                ForEach(model.visibleObjectMasks, id: \.id) { mask in
                    maskOverlay(id: mask.id, rect: mask.rect, in: geo.size)
                }
            }
        }
    }

    /// 既存マスク 1 個の枠・削除ボタン・移動ドラッグ。
    ///
    /// ドラッグの確定で**現在の再生位置にキーフレームが 1 個できる**
    /// （`setObjectMaskKeyframe`）。位置を変えずに指を離したときは
    /// `ObjectMask.settingKeyframe` が同値を返すのでモデルは何もしない
    /// （無意味なキーフレームで undo 履歴が汚れない）。
    private func maskOverlay(id: UUID, rect: CGRect, in size: CGSize) -> some View {
        let base = previewRect(from: rect, in: size)
        let offset = movingMaskID == id ? moveOffset : .zero
        let shown = base.offsetBy(dx: offset.width, dy: offset.height)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.orange, lineWidth: 2)
                .background(Color.orange.opacity(0.08))
                .frame(width: shown.width, height: shown.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            movingMaskID = id
                            moveOffset = value.translation
                        }
                        .onEnded { value in
                            movingMaskID = nil
                            moveOffset = .zero
                            let moved = base.offsetBy(dx: value.translation.width,
                                                      dy: value.translation.height)
                            model.setObjectMaskKeyframe(id,
                                                        compositionRect: normalizedRect(from: moved,
                                                                                        in: size))
                        }
                )

            Button {
                model.removeObjectMask(id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.system(size: 16))
            }
            .offset(x: 8, y: -8)
        }
        .position(x: shown.midX, y: shown.midY)
        .accessibilityIdentifier("editor.objectMask")
    }

    /// 矩形を描く面（ツール ON のときだけ張る）。
    private func drawingSurface(in size: CGSize) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let origin = CGPoint(
                                x: min(value.startLocation.x, value.location.x),
                                y: min(value.startLocation.y, value.location.y)
                            )
                            let extent = CGSize(
                                width: abs(value.location.x - value.startLocation.x),
                                height: abs(value.location.y - value.startLocation.y)
                            )
                            dragging = CGRect(origin: origin, size: extent)
                        }
                        .onEnded { _ in
                            guard let rect = dragging, rect.width > 10, rect.height > 10 else {
                                dragging = nil
                                return
                            }
                            dragging = nil
                            let normalized = normalizedRect(from: rect, in: size)
                            isDetecting = true
                            Task {
                                await model.detectInRegion(normalized)
                                isDetecting = false
                            }
                        }
                )
            // ツール ON を画面上でも示す（枠と一言）。押し間違いの再発防止に、
            // 「いま指定モードである」ことが指を置く前に分かる状態を保つ。
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)
            VStack {
                Spacer()
                Text("ドラッグで範囲を指定")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 12)
            }
            .allowsHitTesting(false)
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
