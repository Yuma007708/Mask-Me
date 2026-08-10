import SwiftUI

/// 検出済み顔のサムネイルを横スクロールで並べ、タップで選択/解除できるビュー。
/// 動画モードでは右下に検出率バッジを表示する。
struct FaceSelectorView: View {
    @ObservedObject var model: MosaicEditorModel
    /// 動画モードの 1 段ドック（`VideoEffectDockView`）に収める縮小版。
    /// 写真モードは既定（`false`）のまま＝従来の見た目を変えない。
    var compact = false

    /// サムネイルの一辺。
    private var chipSize: CGFloat { compact ? 40 : 60 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 6 : 10) {
                // 矩形ツールの入口。**顔が 1 つも見つからないときこそ必要**なので、
                // 「検出できませんでした」の場合も必ず並べる（旧実装はこの分岐で
                // 行ごと差し替えていたため、検出ゼロだと手動指定へ辿り着けなかった）。
                rectangleToolChip
                // 顔ではなく**人物**単位で並べる。同じ人がフレームアウト→再入して
                // ターゲットが増えても、一覧では 1 つのチップにまとまる。
                // 署名が取れていない顔は従来どおり 1 顔 = 1 チップ。
                ForEach(model.personGroups) { group in
                    personChip(group)
                }
                // 手動矩形は顔ではなく「領域」として別表示
                ForEach(model.manualRegions) { region in
                    manualRegionChip(region)
                }
                if model.detectedFaces.isEmpty && model.manualRegions.isEmpty {
                    Text("顔を検出できませんでした")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, compact ? 0 : 16)
            .padding(.vertical, compact ? 0 : 8)
        }
    }

    // MARK: - 矩形ツール

    /// 手動矩形ツールの ON/OFF。**既定は OFF**（常時有効だと誤って矩形ができる）。
    private var rectangleToolChip: some View {
        Button {
            model.isRectangleToolActive.toggle()
        } label: {
            let isOn = model.isRectangleToolActive
            VStack(spacing: 2) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: compact ? 17 : 22, weight: .semibold))
                Text("矩形")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOn ? Color.white : Color.accentColor)
            .frame(width: chipSize, height: chipSize)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? Color.accentColor : Color.accentColor.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.rectangleTool")
        .accessibilityLabel(model.isRectangleToolActive ? "矩形の指定を終える" : "矩形で範囲を指定")
    }

    // MARK: - Face chip

    private func personChip(_ group: PersonGroup) -> some View {
        Button {
            model.togglePerson(group.memberIDs)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: group.representative.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: chipSize, height: chipSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(group.isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
                    )
                    .opacity(group.isSelected ? 1.0 : 0.45)

                if model.mode == .video {
                    detectionBadge(rate: group.detectionRate, isScanning: model.isScanning)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detectionBadge(rate: Double?, isScanning: Bool) -> some View {
        if isScanning && rate == nil {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 22, height: 14)
                .background(.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(3)
        } else if let r = rate {
            Text("\(Int(r))%")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.65))
                .clipShape(Capsule())
                .padding(3)
        }
    }

    // MARK: - Manual region chip

    private func manualRegionChip(_ region: ManualRegion) -> some View {
        Button {
            model.removeManualRegion(region.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: chipSize, height: chipSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange, lineWidth: 2)
                    )
                VStack(spacing: 2) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.manualRegion")
        .accessibilityLabel("指定した矩形を削除")
    }
}
