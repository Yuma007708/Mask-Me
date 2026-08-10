import MosaicCore
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
    /// 大きさを変えている最中のマスクと、その変化量（**矩形のローカル軸**）。
    @State private var resizingMaskID: UUID?
    @State private var resizeDelta: CGSize = .zero
    /// 回している最中のマスクと、掴んだ時点の角度・元の角度・いまの見た目の角度。
    @State private var rotatingMaskID: UUID?
    @State private var rotationGrabAngle: Double = 0
    @State private var rotationInitial: Double = 0
    @State private var rotationPreview: Double = 0

    /// 回転つまみを枠の下端からどれだけ離すか。近すぎると大きさのつまみと
    /// 指が取り合いになる。
    private static let rotateHandleGap: CGFloat = 28
    /// つまみの当たり判定（見た目は 18pt）。
    private static let handleTapTarget: CGFloat = 44

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
                    maskOverlay(id: mask.id, rect: mask.rect, angle: mask.angle, in: geo.size)
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
    /// - Parameter angle: 傾き（ラジアン）。枠もつまみも**まとめて回す**ので、
    ///   傾いた矩形でも「右下のつまみ」は見た目どおり右下にある。
    private func maskOverlay(id: UUID, rect: CGRect, angle: Double, in size: CGSize) -> some View {
        let base = previewRect(from: rect, in: size)
        let moved = movingMaskID == id ? moveOffset : .zero
        let sized = resizingMaskID == id ? resizeDelta : .zero
        // 大きさの下書きは**ローカル軸**で持っている（`localDelta` を通した後の値）ので、
        // ここでそのまま矩形へ効かせてよい。位置の下書きは画面座標なので後から足す。
        let resized = RectangleHandleMath.resizedAroundCenter(base, byLocal: sized)
        let shown = resized.offsetBy(dx: moved.width, dy: moved.height)
        let shownAngle = rotatingMaskID == id ? rotationPreview : angle

        return ZStack {
            frameBody(id: id, base: base, shown: shown, angle: shownAngle, in: size)
            handles(id: id, base: base, shown: shown, angle: shownAngle, in: size)
        }
        .frame(width: shown.width, height: shown.height)
        // **枠とつまみを一緒に回す。** 枠だけ回すと、傾けた矩形のつまみが
        // 見た目と合わない位置に残る。
        .rotationEffect(.radians(shownAngle))
        .position(x: shown.midX, y: shown.midY)
        // **`children: .contain` を先に置くこと。** これが無いと、コンテナに付けた
        // 識別子が子孫へ伝播して、つまみが自分で持っている
        // `editor.objectMask.resize` / `.rotate` / `.remove` を上書きする
        // （`EditorDockView` で同じ事故を起こしている。`VideoTimelineView.trackStack`
        // も同じ理由でこの組み合わせにしてある）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.objectMask")
    }

    /// 枠本体と移動ドラッグ。
    ///
    /// ドラッグの確定で**現在の再生位置にキーフレームが 1 個できる**
    /// （`setObjectMaskKeyframe`）。位置を変えずに指を離したときは
    /// `ObjectMask.settingKeyframe` が同値を返すのでモデルは何もしない
    /// （無意味なキーフレームで undo 履歴が汚れない）。
    private func frameBody(id: UUID, base: CGRect, shown: CGRect,
                           angle: Double, in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.orange, lineWidth: 2)
            .background(Color.orange.opacity(0.08))
            .contentShape(Rectangle())
            .gesture(
                // **`.global` で取ること。** 既定の `.local` は `rotationEffect` を
                // 掛けたビューの中では一緒に回るので、傾けた矩形を掴むと
                // 指と別の方向へ動く。
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        movingMaskID = id
                        moveOffset = value.translation
                    }
                    .onEnded { value in
                        movingMaskID = nil
                        moveOffset = .zero
                        commit(id: id, rect: shown.offsetBy(dx: value.translation.width,
                                                            dy: value.translation.height),
                               angle: angle, in: size)
                    }
            )
    }

    /// ✕（消す）・↘（大きさ）・↻（傾き）。
    private func handles(id: UUID, base: CGRect, shown: CGRect,
                         angle: Double, in size: CGSize) -> some View {
        ZStack {
            handleButton(systemImage: "xmark.circle.fill", tint: .red)
                .position(x: shown.width, y: 0)
                .onTapGesture { model.removeObjectMask(id) }
                .accessibilityIdentifier("editor.objectMask.remove")
                .accessibilityLabel("この矩形を消す")

            handleButton(systemImage: "arrow.down.right.circle.fill", tint: .orange)
                .position(x: shown.width, y: shown.height)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            resizingMaskID = id
                            resizeDelta = RectangleHandleMath.localDelta(value.translation,
                                                                         angle: angle)
                        }
                        .onEnded { value in
                            let delta = RectangleHandleMath.localDelta(value.translation,
                                                                       angle: angle)
                            resizingMaskID = nil
                            resizeDelta = .zero
                            commit(id: id,
                                   rect: RectangleHandleMath.resizedAroundCenter(base, byLocal: delta),
                                   angle: angle, in: size)
                        }
                )
                .accessibilityIdentifier("editor.objectMask.resize")
                .accessibilityLabel("矩形の大きさを変える")

            handleButton(systemImage: "rotate.right.fill", tint: .orange)
                .position(x: shown.width / 2, y: shown.height + Self.rotateHandleGap)
                .gesture(rotationGesture(id: id, shown: shown, angle: angle, in: size))
                .accessibilityIdentifier("editor.objectMask.rotate")
                .accessibilityLabel("矩形を傾ける")
        }
    }

    /// 中心から指への角度で回す。**掴んだ時点との差**を足すので、指を置いた瞬間は動かない。
    private func rotationGesture(id: UUID, shown: CGRect,
                                 angle: Double, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let center = CGPoint(x: shown.midX, y: shown.midY)
                guard let current = RectangleHandleMath.angle(from: center, to: value.location)
                else { return }
                if rotatingMaskID != id {
                    rotatingMaskID = id
                    // 掴んだ位置の角度を基準にする（`nil` なら指が中心にあるので待つ）。
                    rotationGrabAngle = RectangleHandleMath.angle(from: center,
                                                                  to: value.startLocation) ?? current
                    rotationInitial = angle
                }
                rotationPreview = RectangleHandleMath.rotated(from: rotationGrabAngle,
                                                              by: current, initial: rotationInitial)
            }
            .onEnded { _ in
                guard rotatingMaskID == id else { return }
                let settled = rotationPreview
                rotatingMaskID = nil
                commit(id: id, rect: shown, angle: settled, in: size)
            }
    }

    private func handleButton(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(.white, tint)
            .font(.system(size: 18))
            // 見た目は 18pt のまま、**当たり判定だけ**を指の大きさへ広げる。
            .frame(width: Self.handleTapTarget, height: Self.handleTapTarget)
            .contentShape(Circle())
    }

    /// 画面の矩形をモデルへ書き戻す（正規化して渡すのはここ 1 箇所）。
    private func commit(id: UUID, rect: CGRect, angle: Double, in size: CGSize) {
        model.setObjectMaskKeyframe(id, compositionRect: normalizedRect(from: rect, in: size),
                                    angle: angle)
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

    // 換算の実体は `PreviewImageGeometry`（MosaicCore、`swift test` で固定）。
    // **ここに式を書き戻さないこと。** 顔の枠（`FacePickOverlay`）が同じ換算を使うので、
    // 片方だけ直すと「矩形は合っているのに顔の枠だけずれる」ことになる。

    private func geometry(in size: CGSize) -> PreviewImageGeometry {
        PreviewImageGeometry(containerSize: size, imageSize: model.previewImage?.size)
    }

    private func previewRect(from normalized: CGRect, in size: CGSize) -> CGRect {
        geometry(in: size).screenRect(from: normalized)
    }

    private func normalizedRect(from rect: CGRect, in containerSize: CGSize) -> CGRect {
        geometry(in: containerSize).normalizedRect(from: rect)
    }
}
