import SwiftUI

/// 横スクロール可能なカスタムタブバー（顔／背景、今後拡張）。
/// タブ自体がトグル：タップで選択＋効果ON、選択中タブの再タップで効果OFF。
/// はっきりした境目は設けず、下部ドックにシームレスに収める。
struct EffectTabBar: View {
    @ObservedObject var model: MosaicEditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MosaicEditorModel.EffectTab.allCases) { tab in
                    tabButton(tab)
                }
                futurePlaceholder
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private func tabButton(_ tab: MosaicEditorModel.EffectTab) -> some View {
        let isActive = model.activeTab == tab
        return Button {
            model.tapTab(tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol(for: tab))
                    .font(.system(size: 20, weight: .regular))
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(width: 74, height: 60)
            .foregroundStyle(isActive ? Color.white : Color(uiColor: .secondaryLabel))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var futurePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
            Text("追加予定")
                .font(.system(size: 11.5, weight: .medium))
        }
        .frame(width: 62, height: 60)
        .foregroundStyle(Color(uiColor: .tertiaryLabel))
    }

    private func symbol(for tab: MosaicEditorModel.EffectTab) -> String {
        EffectTabSymbol.name(for: tab)
    }
}

/// 効果タブのアイコン名（写真モードの `EffectTabBar` と動画モードの
/// `VideoEffectDockView` で同じ絵を使うための共有）。
enum EffectTabSymbol {
    static func name(for tab: MosaicEditorModel.EffectTab) -> String {
        switch tab {
        case .face: return "face.smiling"
        case .background: return "photo"
        }
    }
}

/// 動画モードの下部ドック。**常に 1 段・高さ固定**の階層ナビゲーション。
///
/// 段の中身だけが入れ替わる（積み上げない）:
/// ```
/// 初期      [編集] [モザイク]
/// モザイク  [← 戻る] [顔] [背景]
/// 顔        [← 戻る] [顔*] [顔サムネ][顔サムネ]…
/// 背景      [← 戻る] [背景*] 背景全体にモザイク
/// ```
/// 旧 UI は「顔サムネ列 76pt + 粗さバー 62pt + タブバー 86pt」が**積み上がって**
/// 224pt を占め、プレビューが 46% → 30% まで潰れていた。ここを 1 段
/// （`VideoEffectDockView.height`）に固定し、粗さスライダーはタイムライン直下の
/// ツールバー段と入れ替わりで出す（`TimelineAdjustmentBarView`）ことで、
/// **どの階層でも画面の高さ配分が動かない**。
///
/// 階層は「モザイク → 顔 → サムネ列」の 3 段階まで。行き止まりを作らないため、
/// 最上段以外には必ず左端の戻るボタンを置く。
///
/// **`*` 印のタブチップは押すと効果 OFF**（`tapTab` は選択中タブの再タップで
/// 効果を切る契約）。これが無いと、動画モードから顔／背景モザイクを**切る手段が
/// 消える**（戻るボタンは効果を保ったまま階層を上がる）。
struct VideoEffectDockView: View {
    @ObservedObject var model: MosaicEditorModel

    /// 段の高さ。**階層で変えないこと**（変えるとプレビューの高さが階層で動く）。
    static let height: CGFloat = 52

    /// 「モザイク」階層に降りているか（効果タブ未選択のときだけ意味を持つ）。
    @State private var showsMosaicMenu = false

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.2), value: showsMosaicMenu)
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.activeTab {
            // 3 段階目：効果ごとの中身。戻ると「モザイク」階層へ上がる（効果は保つ）。
            backButton { model.confirmAdjustment(); showsMosaicMenu = true }
            dockButton(title: tab.title, systemImage: EffectTabSymbol.name(for: tab),
                       isActive: true, accessibilityLabel: "\(tab.title)モザイクをオフ") {
                model.tapTab(tab)
            }
            Divider().frame(height: 28)
            tabContent(tab)
        } else if showsMosaicMenu {
            // 2 段階目：モザイクの種類。
            backButton { showsMosaicMenu = false }
            ForEach(MosaicEditorModel.EffectTab.allCases) { tab in
                dockButton(title: tab.title, systemImage: EffectTabSymbol.name(for: tab),
                           isActive: isEffectOn(tab)) {
                    model.tapTab(tab)
                }
            }
            Spacer(minLength: 0)
        } else {
            // 1 段階目：編集モードとモザイクモード（並列）。
            // 「編集」はタイムライン直下のツールバーが出ている状態そのものなので、
            // 既定で選択済み扱いにする（押しても階層は動かない ＝ 行き止まりにならない）。
            dockButton(title: "編集", systemImage: "slider.horizontal.3", isActive: true) {
                showsMosaicMenu = false
            }
            dockButton(title: "モザイク", systemImage: "squareshape.split.3x3",
                       isActive: false) {
                showsMosaicMenu = true
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: MosaicEditorModel.EffectTab) -> some View {
        switch tab {
        case .face:
            FaceSelectorView(model: model, compact: true)
        case .background:
            Text("背景全体にモザイクをかけます")
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func isEffectOn(_ tab: MosaicEditorModel.EffectTab) -> Bool {
        switch tab {
        case .face: return model.faceMosaicOn
        case .background: return model.backgroundMosaicOn
        }
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 44)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("戻る")
    }

    private func dockButton(title: String, systemImage: String, isActive: Bool,
                            accessibilityLabel: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 60, height: 44)
            .foregroundStyle(isActive ? Color.white : Color(uiColor: .secondaryLabel))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
