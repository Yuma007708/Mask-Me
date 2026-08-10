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
    /// 画像・他オーバーレイと共有する換算。**ここでは作らない**——生成箇所は
    /// `EditorView+Preview.swift` の 1 箇所だけにする（`.swiftlint.yml` の
    /// `preview_geometry_single_construction` が番をしている）。
    let geometry: PreviewImageGeometry
    /// 2 本指のピンチ／パンが進行中かどうか（`EditorView.isPinchZooming`。
    /// `@GestureState` なのでジェスチャの異常終了でも自動で戻る）。
    /// true になった瞬間、進行中の編集を確定せずに捨て、当たり判定を切る
    /// （`body` の `onChange` / `allowsHitTesting` 参照）。
    let isZoomGestureActive: Bool
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
    /// 状態ラベルの中心を画面上端からこれ以上は上げない（見切れ防止）。
    private static let stateLabelInset: CGFloat = 10

    var body: some View {
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
            //
            // **排他の根拠は `PreviewInteractionPolicy` であって、`CropOverlay` の
            // 全面キャッチレイヤーではない。** クロップ編集中は `activeTab = nil` の
            // didSet で `isRectangleToolActive` も落ちるため、この画面が消える結果自体は
            // 従来と変わらない——判定の出どころを 1 箇所（`allowsRectangleDrawing`）へ
            // 揃えることが目的（`CropOverlay` の全面キャッチは重ね順の多重防御でしかない）。
            if model.previewInteraction.allowsRectangleDrawing {
                drawingSurface(in: geometry)
            }

            // 既存の物体マスクをオーバーレイ表示。**描画面より上に置く**ので、
            // 矩形ツール ON でもマスクの上のドラッグは「移動」になる
            // （空いている所をドラッグすれば従来どおり新規作成）。
            //
            // **`objectMasks` を直接 `ForEach` しないこと**: 矩形はキーフレーム補間で
            // 時刻ごとに変わるので、シークしても枠が動かなくなる。
            //
            // 枠自体は常時見せる（ツール ON/OFF・段に関係なく「何が掛かっているか」は
            // 見えている必要がある）が、**編集操作（移動・大きさ・回転・削除）の可否だけ**
            // `allowsExistingMaskEditing` で切る。クロップ編集中はここが false になり、
            // `CropOverlay` の全面キャッチレイヤーに頼らずこのビュー自身が当たり判定を切る。
            ForEach(model.visibleObjectMasks, id: \.id) { mask in
                maskOverlay(id: mask.id, rect: mask.rect, angle: mask.angle,
                           state: mask.state, in: geometry)
                    .allowsHitTesting(model.previewInteraction.allowsExistingMaskEditing)
            }

            // 追えているかのラベル。**`maskOverlay` の中に入れない。** あそこは
            // `.frame` → `.rotationEffect` → `.position` の連鎖と `.global` 座標の
            // ドラッグが噛み合っており、子を足すと当たり判定が動く。枠より上に
            // 別の `ForEach` として重ねる。
            ForEach(model.visibleObjectMasks, id: \.id) { mask in
                stateLabel(for: mask, in: geometry)
            }
        }
        .frame(width: geometry.containerSize.width, height: geometry.containerSize.height)
        .allowsHitTesting(!isZoomGestureActive)
        // **ピンチが始まった瞬間、進行中の編集を確定せずに捨てる。** これをやらないと
        // 「ピンチしたら矩形が 1 個できた」「掴んでいた矩形が指 1 本ぶんだけ飛んだ」が起きる
        // （2 本指のうち先に着いた 1 本を単独ドラッグとして拾ってしまうため）。
        .onChange(of: isZoomGestureActive) { active in
            guard active else { return }
            dragging = nil
            movingMaskID = nil
            moveOffset = .zero
            resizingMaskID = nil
            resizeDelta = .zero
            rotatingMaskID = nil
            rotationPreview = 0
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
    private func maskOverlay(id: UUID, rect: CGRect, angle: Double,
                             state: ObjectMaskFollowState, in geometry: PreviewImageGeometry) -> some View {
        let base = previewRect(from: rect, in: geometry)
        let shown = shownRect(for: id, base: base)
        let shownAngle = rotatingMaskID == id ? rotationPreview : angle

        return ZStack {
            frameBody(id: id, shown: shown, angle: shownAngle, state: state, in: geometry)
            handles(id: id, base: base, shown: shown, angle: shownAngle, in: geometry)
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

    /// 移動・大きさ変更の下書きを反映した、いま画面に見せている矩形（画面座標）。
    ///
    /// `maskOverlay`（枠本体）と `stateLabel`（ラベル、`maskOverlay` の外の別 `ForEach`）が
    /// 同じ位置合わせを使うための共通部。ここが 2 箇所に書き写されると、
    /// ドラッグ中に枠とラベルの位置がずれる。
    private func shownRect(for id: UUID, base: CGRect) -> CGRect {
        let moved = movingMaskID == id ? moveOffset : .zero
        let sized = resizingMaskID == id ? resizeDelta : .zero
        // 大きさの下書きは**ローカル軸**で持っている（`localDelta` を通した後の値）ので、
        // ここでそのまま矩形へ効かせてよい。位置の下書きは画面座標なので後から足す。
        let resized = RectangleHandleMath.resizedAroundCenter(base, byLocal: sized)
        return resized.offsetBy(dx: moved.width, dy: moved.height)
    }

    /// 枠本体と移動ドラッグ。
    ///
    /// ドラッグの確定で**現在の再生位置にキーフレームが 1 個できる**
    /// （`setObjectMaskKeyframe`）。位置を変えずに指を離したときは
    /// `ObjectMask.settingKeyframe` が同値を返すのでモデルは何もしない
    /// （無意味なキーフレームで undo 履歴が汚れない）。
    ///
    /// 色は顔検出の青枠（`FacePickOverlay`）に揃える。線種は `state` に従う
    /// （追跡中・固定＝実線、解析中・追跡なし＝破線。`ObjectMaskStateStyle` 参照）。
    private func frameBody(id: UUID, shown: CGRect, angle: Double,
                           state: ObjectMaskFollowState, in geometry: PreviewImageGeometry) -> some View {
        let dashed = ObjectMaskStateStyle.isDashed(state)
        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.blue,
                   style: dashed ? StrokeStyle(lineWidth: 2, dash: [6, 4]) : StrokeStyle(lineWidth: 2))
            .background(Color.blue.opacity(0.08))
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
                               angle: angle, in: geometry)
                    }
            )
    }

    /// ✕（消す）・↘（大きさ）・↻（傾き）。
    private func handles(id: UUID, base: CGRect, shown: CGRect,
                         angle: Double, in geometry: PreviewImageGeometry) -> some View {
        ZStack {
            handleButton(systemImage: "xmark.circle.fill", tint: .red)
                .position(x: shown.width, y: 0)
                .onTapGesture { model.removeObjectMask(id) }
                .accessibilityIdentifier("editor.objectMask.remove")
                .accessibilityLabel("この矩形を消す")

            handleButton(systemImage: "arrow.down.right.circle.fill", tint: .blue)
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
                                   angle: angle, in: geometry)
                        }
                )
                .accessibilityIdentifier("editor.objectMask.resize")
                .accessibilityLabel("矩形の大きさを変える")

            handleButton(systemImage: "rotate.right.fill", tint: .blue)
                .position(x: shown.width / 2, y: shown.height + Self.rotateHandleGap)
                .gesture(rotationGesture(id: id, shown: shown, angle: angle, in: geometry))
                .accessibilityIdentifier("editor.objectMask.rotate")
                .accessibilityLabel("矩形を傾ける")
        }
    }

    /// 中心から指への角度で回す。**掴んだ時点との差**を足すので、指を置いた瞬間は動かない。
    private func rotationGesture(id: UUID, shown: CGRect,
                                 angle: Double, in geometry: PreviewImageGeometry) -> some Gesture {
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
                commit(id: id, rect: shown, angle: settled, in: geometry)
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
    private func commit(id: UUID, rect: CGRect, angle: Double, in geometry: PreviewImageGeometry) {
        model.setObjectMaskKeyframe(id, compositionRect: normalizedRect(from: rect, in: geometry),
                                    angle: angle)
    }

    /// 矩形を描く面（ツール ON のときだけ張る）。
    private func drawingSurface(in geometry: PreviewImageGeometry) -> some View {
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
                            let normalized = normalizedRect(from: rect, in: geometry)
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
    // 片方だけ直すと「矩形は合っているのに顔の枠だけずれる」ことになる。`geometry` は
    // 格納プロパティ（`EditorView+Preview.swift` から渡される）で、ここでは作らない。

    private func previewRect(from normalized: CGRect, in geometry: PreviewImageGeometry) -> CGRect {
        geometry.screenRect(from: normalized)
    }

    private func normalizedRect(from rect: CGRect, in geometry: PreviewImageGeometry) -> CGRect {
        geometry.normalizedRect(from: rect)
    }

    /// 「追えているか」のラベル。**枠より上に、別の `ForEach` として**重ねる
    /// （`maskOverlay` の中には入れない。理由は `body` のコメント参照）。
    ///
    /// - ドラッグ確定直後は必ず `.computing` に落ちる（追跡タスクの張り替えが起きるため）。
    ///   連続ドラッグでラベルが明滅しないよう、掴んでいる最中は出さない。
    /// - ラベルは**回転させない**（傾いた矩形でも文字が読めるように）。`shownRect` は
    ///   回転前の画面座標そのものなので、ここではそのまま使う。
    private func stateLabel(for mask: VisibleObjectMask, in geometry: PreviewImageGeometry) -> some View {
        let isDragging = movingMaskID == mask.id || resizingMaskID == mask.id
            || rotatingMaskID == mask.id
        let shown = shownRect(for: mask.id, base: previewRect(from: mask.rect, in: geometry))
        return Group {
            if !isDragging, let text = ObjectMaskStateStyle.label(mask.state) {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue, in: Capsule())
                    // 枠の上辺の**中央**に置く（左上に置くと、ラベルの中心が角に来るので
                    // 半分が枠の外側へはみ出す）。画面の上端に張り付いた矩形でも見切れない
                    // よう y は下限で止める。
                    .position(x: shown.midX, y: max(Self.stateLabelInset, shown.minY - 12))
                    // **ドラッグを奪わないこと。** これが無いと枠の移動ジェスチャより
                    // ラベルの当たり判定が優先されてしまう。
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("editor.objectMask.state")
                    .accessibilityLabel(text)
            }
        }
    }
}

/// 物体マスクの「追えているか」の表示規則を純関数に切り出したもの。
///
/// `.fixed`（静止画の固定マスク）はラベル無し・実線。`.tracking`（軌跡が最新でセグメント内）は
/// 実線 + ラベル。`.computing`（解析中）/ `.untracked`（追跡なし）は破線 + ラベル。
///
/// **「追跡なし」に赤やエラー色を使わない。** モザイクはキーフレーム補間で乗り続けているので、
/// 危険サインに見せると嘘になる（色は常に青、線種と文言だけで区別する）。
enum ObjectMaskStateStyle {
    static func label(_ state: ObjectMaskFollowState) -> String? {
        switch state {
        case .fixed: return nil
        case .tracking: return "追跡中"
        case .computing: return "解析中"
        case .untracked: return "追跡なし"
        }
    }

    static func isDashed(_ state: ObjectMaskFollowState) -> Bool {
        switch state {
        case .fixed, .tracking: return false
        case .computing, .untracked: return true
        }
    }
}
