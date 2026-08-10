import MosaicCore
import SwiftUI

/// クロップ編集中にプレビューへ重ねる、外側の暗幕と 8 ハンドルのオーバーレイ。
///
/// **幾何の計算はここではしない。** ハンドルをドラッグしたときの新しい矩形は
/// `CropHandleMath.dragged` に、画面 pt ⇔ 正規化座標の換算は `geometry`
/// （`PreviewImageGeometry`）に、それぞれ 1 本化してある。ここで作るのは
/// 「掴んだハンドル」と「ドラッグの正規化移動量」だけで、あとは値をそのまま
/// 図形として描く（`.swiftlint.yml` の `crop_geometry_stays_in_core` が
/// `CropRect(rect:` の書き戻しを機械的に止める）。
///
/// クロップ中はプレビュー合成が `crop = .full` で組み直されている
/// （`MosaicEditorModel+Crop.swift` の型 doc 参照）ので、`cropDraft` は
/// **その全面フレームに対する**正規化矩形として扱える。切り落とし予定の外側は
/// 暗幕で示すだけで、実際にはまだ何も切られていない。
struct CropOverlay: View {
    @ObservedObject var model: MosaicEditorModel
    /// 画像・他オーバーレイと共有する換算。**ここでは作らない**——生成箇所は
    /// `EditorView+Preview.swift` の 1 箇所だけ（`.swiftlint.yml` の
    /// `preview_geometry_single_construction` が番をしている）。
    let geometry: PreviewImageGeometry
    let cropDraft: CropRect

    /// 掴んだ時点のクロップ。ドラッグ中は毎回これへ translation を適用する
    /// （逐次積算しない。`CropHandleMath.dragged` の doc の注意と同じ）。
    @State private var dragStartCrop: CropRect?
    /// いまドラッグ中のハンドル（三分割グリッドの表示条件）。
    @State private var activeHandle: CropHandle?

    private static let handleTapTarget: CGFloat = 44
    private static let handleVisualLength: CGFloat = 18
    private static let handleThickness: CGFloat = 3

    var body: some View {
        let rect = geometry.screenRect(from: cropDraft.rect)
        return ZStack {
            // **全面キャッチ層は置かない。** 以前は「クロップ以外の操作面へ触らせない」
            // ための透明なドラッグ面をここに敷いていたが、それがあると排他を実際に
            // 担っているのがキャッチ層になり、`PreviewInteractionPolicy` の配線を
            // 外しても UI テストが緑のまま通ってしまった（親の変異検証で確認）。
            // 守り手が 2 つあってテストできる方が働いていない状態は、退行を素通しする。
            //
            // 排他の唯一の機構は `PreviewInteractionPolicy`
            // （`FacePickOverlay` / `RectangleDrawingOverlay` / `TextOverlayEditView` が
            // それぞれ `allowsHitTesting` で参照する）。プレビュー上の操作面はこの 3 つで
            // 尽きているので、重ね順に頼る必要は無い。
            dimming(hole: rect)
            border(rect)
            if activeHandle != nil {
                gridLines(in: rect)
            }
            // `CropHandle`（MosaicCore）は `Equatable` / `Hashable` を持たないので
            // `id: \.self` は使えない。並びは固定なので配列の添字を id に使う。
            ForEach(Array(Self.draggableHandles.enumerated()), id: \.offset) { _, handle in
                handleView(handle, in: rect)
            }
        }
        .frame(width: geometry.containerSize.width, height: geometry.containerSize.height)
        .allowsHitTesting(model.previewInteraction.allowsCropHandles)
    }

    /// `.inside` を除いた 8 ハンドル。`CropHandle` が `Equatable` を持たないため
    /// `!=` ではなくパターンマッチで除外する。
    private static let draggableHandles: [CropHandle] = CropHandle.allCases.filter {
        if case .inside = $0 { return false }
        return true
    }

    /// 外側の暗幕。穴あきパス（`eoFill`）でクロップの中だけくり抜く。
    private func dimming(hole rect: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: geometry.containerSize))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func border(_ rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// 三分割グリッド。**ドラッグ中だけ**表示する（常時出すと絵が読めない。写真.app と同じ）。
    private func gridLines(in rect: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.7), lineWidth: 1)
        .allowsHitTesting(false)
    }

    // MARK: - ハンドル

    @ViewBuilder
    private func handleView(_ handle: CropHandle, in rect: CGRect) -> some View {
        let point = position(of: handle, in: rect)
        handleShape(handle)
            .foregroundStyle(Color.white)
            // 見た目は細いまま、**当たり判定だけ** 44pt へ広げる
            // （`FacePickOverlay` / `TimelineLayerTrackView.edgeHandle` と同じ手）。
            .frame(width: Self.handleTapTarget, height: Self.handleTapTarget)
            .contentShape(Rectangle())
            .position(point)
            .gesture(dragGesture(handle))
            .accessibilityIdentifier("editor.crop.handle.\(handleName(handle))")
            .accessibilityLabel("クロップ枠を調整")
    }

    /// 角は L 字、辺は棒。**見た目のサイズは当たり判定と独立**（`handleTapTarget` 参照）。
    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            CropCornerShape()
                .stroke(style: StrokeStyle(lineWidth: Self.handleThickness, lineCap: .square))
                .rotationEffect(.radians(cornerRotation(handle)))
                .frame(width: Self.handleVisualLength, height: Self.handleVisualLength)
        case .top, .bottom:
            Rectangle()
                .frame(width: Self.handleVisualLength, height: Self.handleThickness)
        case .left, .right:
            Rectangle()
                .frame(width: Self.handleThickness, height: Self.handleVisualLength)
        case .inside:
            EmptyView()
        }
    }

    /// `CropCornerShape` は右下向き（頂点が `(maxX, maxY)`）を基準に描いてあるので、
    /// 他の角は 90° 刻みで回して合わせる。
    private func cornerRotation(_ handle: CropHandle) -> Double {
        switch handle {
        case .bottomRight: return 0
        case .bottomLeft: return .pi / 2
        case .topLeft: return .pi
        case .topRight: return 3 * .pi / 2
        default: return 0
        }
    }

    /// ハンドルの画面座標（クロップ矩形の角・辺の中点）。**幾何の算術ではない**——
    /// `rect` はすでに `geometry.screenRect(from:)` で換算済みの画面矩形なので、
    /// ここは SwiftUI の `CGRect` の角・辺の読み出しだけ。
    private func position(of handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .inside: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func handleName(_ handle: CropHandle) -> String {
        switch handle {
        case .topLeft: return "topLeft"
        case .top: return "top"
        case .topRight: return "topRight"
        case .right: return "right"
        case .bottomRight: return "bottomRight"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottomLeft"
        case .left: return "left"
        case .inside: return "inside"
        }
    }

    /// **掴んだ時点の `CropRect` を `dragStartCrop` に保持し、`translation` を
    /// 毎回「元の矩形」へ適用する**（累積させない。誤差が溜まらない）。
    ///
    /// `.global` 座標空間を使うのは `TimelineLayerTrackView.edgeHandle` と同じ理由:
    /// ハンドル自身がドラッグの結果で毎フレーム動くため、`.local` だと `translation` が
    /// 自分の移動を拾って発振する（帯のトリムで実際に踏んだ不具合と同種）。
    private func dragGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStartCrop == nil {
                    dragStartCrop = cropDraft
                    activeHandle = handle
                }
                guard let start = dragStartCrop else { return }
                let width = geometry.imageRect.width
                let height = geometry.imageRect.height
                guard width > 0, height > 0 else { return }
                let translation = CGSize(width: value.translation.width / width,
                                         height: value.translation.height / height)
                let next = CropHandleMath.dragged(start, handle: handle, by: translation,
                                                  lock: model.cropAspectLock,
                                                  inFrame: model.cropEditingFrameSize)
                model.updateCropDraft(next)
            }
            .onEnded { _ in
                dragStartCrop = nil
                activeHandle = nil
            }
    }
}

/// 角ハンドルの L 字（右下ハンドルの向き基準。他の角は `rotationEffect` で回す）。
private struct CropCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
