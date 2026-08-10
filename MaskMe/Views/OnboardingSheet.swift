import SwiftUI

/// 初回起動時に一度だけ出す案内。
///
/// ## なぜ要るか
///
/// このアプリの中心は「顔を自動で見つけて隠す」ことだが、**動画は開いただけでは
/// モザイクが掛からない**（`feat(editor): 動画は開いただけではモザイクを掛けない`
/// で意図的にそうした。勝手に掛かると、隠したくない人まで隠れて取り消し方も分からない）。
/// この仕様は正しいが、初見だと「顔を検出しないアプリ」に見える。最初の 1 回だけ
/// 「モザイクを押す → 顔を選ぶ」を伝える。
///
/// ## 出す条件
///
/// `@AppStorage` の既読フラグ 1 つだけで決める。**素材の有無や下書きの状態は見ない**——
/// 条件を増やすと「消したはずの案内がまた出る」経路が作れてしまう。
///
/// 閉じる手段は本文のボタンと下スワイプの両方（`presentationDetents` を使う通常の
/// シート）。読み飛ばしたい人を止めない。
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 案内の 1 項目。色は `AppTheme.ToolAccent` から引く——**説明に出てくる色と、
    /// 実際の道具の色を一致させる**ため（別々に決めると案内が嘘になる）。
    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let color: Color
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(symbol: "plus",
             color: AppTheme.accent,
             title: "「新しく作る」から始める",
             body: "写真・動画を選ぶか、その場で撮影できます。撮影したものはモザイクを焼き込んだ状態でだけ保存されます。"),
        Step(symbol: "squareshape.split.3x3",
             color: AppTheme.ToolAccent.mask,
             title: "「モザイク」で隠す相手を選ぶ",
             body: "開いただけでは掛かりません。隠したい顔をタップして選びます。囲って隠すこともできます。"),
        Step(symbol: "person.2",
             color: AppTheme.ToolAccent.mask,
             title: "選んだ人を最後まで追いかける",
             body: "向きが変わっても、一度画面から消えて戻ってきても、同じ人を追い続けます。"),
        // 書き出しは 5 つの役割（隠す・音・文字・切る・形）のどれでもないので
        // 主アクセントを使う。編集画面の「エクスポート」も同じ色なので、
        // 案内と実物が一致する。
        Step(symbol: "square.and.arrow.up",
             color: AppTheme.accent,
             title: "書き出して共有する",
             body: "保存・共有されるのは加工後の映像だけです。元の映像がそのまま出ることはありません。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Mask Me へようこそ")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text("顔にモザイクを掛けて共有するためのアプリです。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(steps) { step in
                        row(step)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }

            Button {
                dismiss()
            } label: {
                Text("はじめる")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(AppTheme.onAccent)
                    .background(AppTheme.accent,
                                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius,
                                                     style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .accessibilityIdentifier("onboarding.start")
        }
        .appSheetBackground()
        .presentationDetents([.large])
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(step.color)
                .frame(width: 40, height: 40)
                .background(step.color.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: AppTheme.chipRadius,
                                                 style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(step.body)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
