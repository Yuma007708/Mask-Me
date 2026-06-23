import SwiftUI

/// 検出済み顔のサムネイルを横スクロールで並べ、タップで選択/解除できるビュー。
/// 動画モードでは右下に検出率バッジを表示する。
struct FaceSelectorView: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        Group {
            if model.detectedFaces.isEmpty && model.manualRegions.isEmpty {
                Text("顔を検出できませんでした")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.detectedFaces) { face in
                            faceChip(face)
                        }
                        // 手動矩形は顔ではなく「領域」として別表示
                        ForEach(model.manualRegions) { region in
                            manualRegionChip(region)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Face chip

    private func faceChip(_ face: FaceTarget) -> some View {
        Button {
            model.toggleFace(face.id)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: face.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(face.isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
                    )
                    .opacity(face.isSelected ? 1.0 : 0.45)

                if model.mode == .video {
                    detectionBadge(rate: face.detectionRate, isScanning: model.isScanning)
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
                    .frame(width: 60, height: 60)
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
    }
}
