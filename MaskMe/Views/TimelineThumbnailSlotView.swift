import MosaicCore
import SwiftUI

/// コマ 1 枚ぶんの描画。**値が同じなら描き直さない**（`Equatable`）。
///
/// タイムラインは `MosaicEditorModel` 全体を購読しているため、コマの絵と関係のない
/// 更新（プレビューの再描画・検出結果・再生位置）でも親の body が作り直される。
/// 帯の中で最も重いのがこのコマの描画なので、ここで止めるのが一番効く。
///
/// `UIImage` の比較は参照の同一性（`===`）で足りる。倉庫（`TimelineThumbnailStore`）は
/// 同じキーに対して同じインスタンスを返し、作り直したときだけ別インスタンスになる。
struct ThumbnailSlotView: View, Equatable {
    let image: UIImage?
    let width: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.width == rhs.width
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: TimelineMetrics.clipHeight)
                .clipped()
        } else {
            // 未生成の枠。**黒一色にしない**（1 回の要求数には上限があり、上限で
            // 切り捨てられた枠が「読み込み中」と区別できなくなる）。
            ZStack {
                Rectangle().fill(Color.white.opacity(0.10))
                if width >= 24 {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
            .frame(width: width, height: TimelineMetrics.clipHeight)
        }
    }
}
