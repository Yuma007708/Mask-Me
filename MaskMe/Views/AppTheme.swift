import SwiftUI

/// アプリ全体の配色（案 C: 濃い紺 ＋ 鮮やか）。
///
/// **色は必ずここを通すこと。** View に `Color(red:green:blue:)` を直書きすると、
/// 色を 1 つ変えたいだけで全画面を探す羽目になり、押し忘れた場所だけ旧配色で
/// 残る（実際に旧 UI で「ドックだけ違う灰色」が起きていた）。
///
/// ## なぜ濃紺で固定するのか
///
/// **端末のライト／ダーク設定に追従させない。** 編集画面は映像の上に道具を重ねる
/// ので、地の明るさが変わると同じ操作でも見え方が変わる。加えてホームと編集画面で
/// 地が変わると、同じアプリの中で段差ができる。`MaskMeApp` が
/// `.preferredColorScheme(.dark)` を掛け、地の色はここが 1 本で決める。
///
/// ## 道具の色（`ToolAccent`）
///
/// 道具は**種類ごとに固有の色**を持つ。場所ではなく色で覚えられるようにするため
/// （「緑を押す＝分割」）。色は道具の意味に紐づけて固定し、画面ごとに変えない。
enum AppTheme {

    // MARK: - 地と面

    /// いちばん奥（画面の地）。
    static let background = Color(red: 0.047, green: 0.067, blue: 0.188)      // #0C1130
    /// カード・シート・帯（地より一段手前）。
    static let surface = Color(red: 0.098, green: 0.125, blue: 0.302)         // #19204D
    /// 地と面の中間（ドック・タブバーなど、面の下に敷く帯）。
    static let surfaceDim = Color(red: 0.075, green: 0.102, blue: 0.251)      // #131A40
    /// 区切り線・カードの縁。
    static let line = Color(red: 0.165, green: 0.196, blue: 0.447)            // #2A3272

    // MARK: - 文字

    /// 本文・見出し。
    static let ink = Color(red: 0.933, green: 0.945, blue: 1.0)               // #EEF1FF
    /// 補助（日時・単位・説明）。
    static let inkDim = Color(red: 0.596, green: 0.635, blue: 0.839)          // #98A2D6

    // MARK: - 強調

    /// 主アクセント（保存・選択中・プレイヘッド）。
    static let accent = Color(red: 0.373, green: 0.490, blue: 1.0)            // #5F7DFF
    /// アクセントの上に載せる文字色。
    static let onAccent = Color.white
    /// 破壊的操作（削除）。
    static let danger = Color(red: 1.0, green: 0.357, blue: 0.478)            // #FF5B7A

    // MARK: - 形

    /// カード・ボタンの角丸。
    static let cornerRadius: CGFloat = 14
    /// 帯の中の小さな入れ物（道具のアイコン枠など）。
    static let chipRadius: CGFloat = 10

    /// 道具の色。**意味に紐づけて固定する**（画面ごとに変えない）。
    ///
    /// 並び順ではなく役割で決めてある: 隠す＝青、切る＝緑、足す＝黄、
    /// 飾る＝桃、形＝紫。新しい道具を足すときは、いちばん近い役割の色を使う
    /// （色を増やすと「色で覚える」効果が薄れる）。
    enum ToolAccent {
        /// モザイク・顔・矩形（隠す）。
        static let mask = Color(red: 0.431, green: 0.659, blue: 1.0)         // #6EA8FF
        /// 分割・複製・削除・速度（切る・並べる）。
        static let cut = Color(red: 0.239, green: 0.863, blue: 0.592)        // #3DDC97
        /// テキスト・音声・BGM（足す）。
        static let add = Color(red: 1.0, green: 0.761, blue: 0.314)          // #FFC250
        /// 色調補正・ステッカー・フィルタ（飾る）。
        static let decorate = Color(red: 1.0, green: 0.478, blue: 0.659)     // #FF7AA8
        /// 比率・切り抜き・変形（形）。
        static let shape = Color(red: 0.780, green: 0.608, blue: 1.0)        // #C79BFF
    }
}
