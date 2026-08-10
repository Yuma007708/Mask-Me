import MosaicCore
import SwiftUI

/// プレビュー上に顔の枠を出し、**タップで直接その人を隠す／外す**オーバーレイ。
///
/// 顔一覧のサムネイル（`FaceSelectorView`）だけだった頃は、画面の中の誰が
/// どのサムネイルなのかを目で照合してから押す必要があった。人数が増えるほど、
/// また似た服装・似た構図ほど、この照合が当てにならない。隠したい相手は
/// **映像の中に見えている**のだから、そこを直接押せるのが最短になる。
///
/// **出すのは顔の段だけ。** 常時出すとプレビューが枠で埋まって素材が見えない。
/// 矩形を置いている最中（`isRectangleToolActive`）も出さない——あちらは
/// プレビュー全面にドラッグ面を張るので、枠のタップと取り合いになる。
///
/// 枠は `model.pickableFaces(at:)` が返したものだけ。あちらは
/// 「タップしたら実際に切り替わる顔」だけを返す契約なので、**押しても何も
/// 起きない枠は出ない**（そういう枠が 1 つでもあると、他の枠まで信用されなくなる）。
struct FacePickOverlay: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        GeometryReader { geo in
            let geometry = PreviewImageGeometry(containerSize: geo.size,
                                                imageSize: model.previewImage?.size)
            ForEach(model.pickableFaces(at: model.compositionTimeForOverlay)) { face in
                frame(for: face, in: geometry)
            }
        }
        .allowsHitTesting(isActive)
        .opacity(isActive ? 1 : 0)
    }

    /// 顔の段に居て、かつ矩形を置いている最中ではないこと。
    ///
    /// 写真モードには段が無いので `activeTab` で見る。動画モードは
    /// `.face` の段で `activeTab == .face`、`.rectangle` の段では
    /// それに加えて `isRectangleToolActive` が立つ（`MosaicEditorModel+Dock`）。
    private var isActive: Bool {
        model.activeTab == .face && !model.isRectangleToolActive
    }

    private func frame(for face: MosaicEditorModel.PickableFace,
                       in geometry: PreviewImageGeometry) -> some View {
        // 枠は顔の輪郭ぴったりだと窮屈で、指も置きにくい。少しだけ外へ出す。
        let rect = geometry.screenRect(from: face.bounds).insetBy(dx: -6, dy: -6)
        return RoundedRectangle(cornerRadius: 6)
            .strokeBorder(face.isSelected ? Color.blue : Color.white.opacity(0.7),
                          lineWidth: face.isSelected ? 3 : 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(face.isSelected ? Color.blue.opacity(0.12) : Color.clear)
            )
            .frame(width: rect.width, height: rect.height)
            // **見た目の枠は顔の大きさのまま、当たり判定だけ 44pt へ広げる**
            // （`TimelineLayerTrackView.edgeHandle` と同じ手）。frame ごと広げると
            // 遠くの小さい顔に不釣り合いな大枠が描かれ、隣の顔まで覆う。
            .overlay(
                Color.clear
                    .frame(width: max(rect.width, TimelineMetrics.minimumTapTarget),
                           height: max(rect.height, TimelineMetrics.minimumTapTarget))
                    .contentShape(Rectangle())
            )
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { model.togglePerson(face.memberIDs) }
            .accessibilityIdentifier("editor.facePick")
            .accessibilityLabel(face.isSelected ? "この人を隠すのをやめる" : "この人を隠す")
            .accessibilityAddTraits(face.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
