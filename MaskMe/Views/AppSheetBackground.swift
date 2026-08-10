import SwiftUI

/// シート・全画面の地を `AppTheme.background` へ揃える修飾子。
///
/// ## なぜ要るか
///
/// `MaskMeApp` が `.preferredColorScheme(.dark)` を掛けているので、シートは
/// **OS 既定のダーク（ほぼ黒）**で出る。アプリ本体は濃紺なので、シートを開くたびに
/// 地の色が変わる＝同じアプリの中で段差ができる。
///
/// ## `List` / `Form` は地を自前で塗る
///
/// `.background(...)` を足しただけでは `List` / `Form` の地は変わらない。
/// **`.scrollContentBackground(.hidden)` で既定の地を外してから**背景を敷く必要がある
/// （iOS 16 で入った API。この案件の iOS 16.0 下限で使える）。
/// `ScrollView` / `VStack` にはこの指定は要らないが、掛けても害はないので
/// 呼び出し側が中身の種類を意識しなくて済むよう 1 本にまとめてある。
///
/// **`ignoresSafeArea` を含める。** 含めないと、下端のホームインジケータ周りだけ
/// 既定の黒が残り、細い帯として見える。
struct AppSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
    }
}

extension View {
    /// シートの地をアプリの配色へ揃える（`AppSheetBackground` の doc 参照）。
    func appSheetBackground() -> some View { modifier(AppSheetBackground()) }
}
