import SwiftUI

/// 検出済み顔のサムネイルを横スクロールで並べ、タップで選択/解除できるビュー。
/// 動画モードでは右下に検出率バッジを表示する。
struct FaceSelectorView: View {
    @ObservedObject var model: MosaicEditorModel
    /// 動画モードの 1 段ドック（`EditorDockView`）に収める縮小版。
    /// 写真モードは既定（`false`）のまま＝従来の見た目を変えない。
    var compact = false
    /// 矩形ツールのチップを並べるか。
    ///
    /// **動画モードの「顔」の段では出さない**（`false`）。あちらは矩形が
    /// 顔と並列の段として独立しているので、両方に入口があると同じ道具が
    /// 2 箇所から生えて「どっちを押せばいいのか」が読めなくなる。
    /// 写真モードは段が無く、ここが唯一の入口なので既定は `true`。
    var showsRectangleTool = true
    /// 検出した顔（人物）のチップを並べるか。
    ///
    /// **「矩形」の段では出さない**（`false`）。あの段は手で置いた矩形だけを扱う。
    /// ただし**置いた矩形のチップは出す**（`objectMaskChip`）。あれが矩形を消す
    /// 唯一の導線なので、外すと一度置いた矩形を取り消せなくなる。
    var showsFaces = true

    /// サムネイルの一辺。
    private var chipSize: CGFloat { compact ? 40 : 60 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 6 : 10) {
                // 矩形ツールの入口。**顔が 1 つも見つからないときこそ必要**なので、
                // 「検出できませんでした」の場合も必ず並べる（旧実装はこの分岐で
                // 行ごと差し替えていたため、検出ゼロだと手動指定へ辿り着けなかった）。
                if showsRectangleTool { rectangleToolChip }
                // 顔ではなく**人物**単位で並べる。同じ人がフレームアウト→再入して
                // ターゲットが増えても、一覧では 1 つのチップにまとまる。
                // 署名が取れていない顔は従来どおり 1 顔 = 1 チップ。
                if showsFaces {
                    ForEach(model.personGroups) { group in
                        personChip(group)
                    }
                }
                // 物体マスクは顔ではなく「領域」として別表示
                ForEach(model.visibleObjectMasks, id: \.id) { mask in
                    objectMaskChip(mask.id)
                }
                if let progress = model.objectTrackingProgress {
                    trackingChip(progress)
                }
                if let progress = model.regionSeedProgress {
                    regionSeedChip(progress)
                }
                if showsFaces && model.detectedFaces.isEmpty && model.objectMasks.isEmpty {
                    Text("顔を検出できませんでした")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.inkDim)
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
            .foregroundStyle(isOn ? AppTheme.onAccent : AppTheme.ToolAccent.mask)
            .frame(width: chipSize, height: chipSize)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? AppTheme.ToolAccent.mask : AppTheme.ToolAccent.mask.opacity(0.16))
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

    // MARK: - 自動追跡の進捗

    /// 物体マスクの自動追跡が走っている間だけ出る表示。
    ///
    /// 追跡が終わるまではキーフレームの直線補間で描かれており、終わった瞬間に
    /// モザイクの動きが変わる。**何も出さないと「勝手に位置が変わった」ように見える**ので、
    /// 進行中であることを見せる（押せるものではないので Button にしない）。
    private func trackingChip(_ progress: Double) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "scope")
                .font(.system(size: compact ? 15 : 18, weight: .semibold))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.orange)
        .frame(width: chipSize, height: chipSize)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("editor.objectTrackingProgress")
        .accessibilityLabel("矩形を自動追跡しています")
    }

    /// 範囲指定で見つけた顔を前後へ追い続ける走査（第2段）が走っている間だけ出る表示。
    /// `trackingChip` と同じ理由（進行中であることを見せないと、後から急に
    /// モザイクが追加/変化したように見える）。
    private func regionSeedChip(_ progress: Double) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: compact ? 15 : 18, weight: .semibold))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.orange)
        .frame(width: chipSize, height: chipSize)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("editor.regionSeedProgress")
        .accessibilityLabel("囲った範囲を追跡中")
    }

    // MARK: - 物体マスクのチップ

    /// ✕ は**マスクごと削除**（キーフレーム 1 個だけを消すのではない）。
    private func objectMaskChip(_ maskID: UUID) -> some View {
        Button {
            model.removeObjectMask(maskID)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: chipSize, height: chipSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue, lineWidth: 2)
                    )
                VStack(spacing: 2) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
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
