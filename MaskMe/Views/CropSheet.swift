import MosaicCore
import SwiftUI

/// クロップの比率固定を選ぶシート（`TimelineAspectRatioSheet` と同じ体裁）。
///
/// 選ぶと `model.cropAspectLock` を更新し、いまの下書き（`model.cropDraft`）を
/// `CropHandleMath.applying` で選び直した比率の最大枠へ縮退させる。**式はここに
/// 書かない**——`CropHandleMath.applying` の 1 本を呼ぶだけ。
struct CropSheet: View {
    @ObservedObject var model: MosaicEditorModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CropAspectLock.allCases, id: \.self) { lock in
                        row(lock)
                    }
                } footer: {
                    Text("選び直すと、いまの枠の中心を保ったまま最大の大きさへ調整されます。")
                }
            }
            .navigationTitle("クロップ比率")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { onClose() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(_ lock: CropAspectLock) -> some View {
        let isSelected = model.cropAspectLock == lock
        return Button {
            apply(lock)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(lock))
                        .foregroundStyle(Color(uiColor: .label))
                    Text(Self.usage(lock))
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityIdentifier("editor.crop.aspectRatio.\(lock.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// **幾何の算術はしない。** `CropHandleMath.applying` の結果をそのまま下書きへ渡す。
    private func apply(_ lock: CropAspectLock) {
        model.cropAspectLock = lock
        if let draft = model.cropDraft {
            let next = CropHandleMath.applying(lock, to: draft, inFrame: model.cropEditingFrameSize)
            model.updateCropDraft(next)
        }
    }

    static func title(_ lock: CropAspectLock) -> String {
        switch lock {
        case .free: return "フリー"
        case .original: return "元の比率"
        case .square: return "1:1（正方形）"
        case .landscape16x9: return "16:9（横）"
        case .portrait9x16: return "9:16（縦）"
        case .landscape4x3: return "4:3（横）"
        case .portrait3x4: return "3:4（縦）"
        }
    }

    static func usage(_ lock: CropAspectLock) -> String {
        switch lock {
        case .free: return "辺・角を自由に動かせます"
        case .original: return "いまの映像の形のまま切り抜きます"
        case .square: return "Instagram のフィード向け"
        case .landscape16x9: return "YouTube・テレビ向け"
        case .portrait9x16: return "TikTok・リール・ショート向け"
        case .landscape4x3: return "昔ながらのテレビ・写真向け"
        case .portrait3x4: return "縦向きの写真向け"
        }
    }
}
