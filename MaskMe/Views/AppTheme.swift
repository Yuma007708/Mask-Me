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
    ///
    /// **`Assets.xcassets/AccentColor` と同じ値にしてある**（`ToolColorSchemeTests` が
    /// 番人）。資産は `project.yml` の `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
    /// でアプリ全体のアクセントとして結線してあり、システム部品（`Picker` /
    /// `Slider` / `Toggle`）と UIKit の `tintColor` はそちらを引く。
    ///
    /// そのため**既存の `Color.accentColor` はそのままでよい**（同じ色に解決される）。
    /// 一括で置き換える必要は無い——値が一致していることだけを保てばよい。
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

    /// 道具と帯の色。**意味に紐づけて固定する**（画面ごとに変えない）。
    ///
    /// ## 道具の色とタイムラインの帯の色は同じ表を使う
    ///
    /// この 5 色は**道具（ドックのボタン）と、その道具が作る帯（タイムラインの
    /// レイヤー）の両方**を塗る。「テキストを押す → 桃の帯が出る」が成り立つので、
    /// 画面の下と真ん中が同じ意味で結びつく。**2 つの表に分けてはいけない**——
    /// 分けると、押した色と出てくる帯の色が違って手がかりにならない。
    ///
    /// 割り当ては `TimelinePalette` 側の制約（**帯どうしが互いに見分けられること**）が
    /// 先に決まっているので、道具の側をそれに合わせてある。新しい道具を足すときは
    /// いちばん近い役割の色を使う（色を増やすと「色で覚える」効果が薄れる）。
    enum ToolAccent {
        /// 隠す。モザイク・顔・矩形 ↔ モザイクの適用区間の帯。
        static let mask = Color(red: 0.431, green: 0.659, blue: 1.0)         // #6EA8FF
        /// 音。音楽・音量 ↔ BGM／音声の帯。
        static let audio = Color(red: 0.239, green: 0.863, blue: 0.592)      // #3DDC97
        /// 文字・飾り。テキスト・ステッカー・フィルター ↔ テキストの帯。
        static let decorate = Color(red: 1.0, green: 0.478, blue: 0.659)     // #FF7AA8
        /// 切る・並べる。分割・複製・削除・速度・素材の追加 ↔ 継ぎ目とキーフレームの目印。
        static let cut = Color(red: 1.0, green: 0.761, blue: 0.314)          // #FFC250
        /// 形。比率・切り抜き・変形（帯を持たない。作品全体に掛かる設定）。
        static let shape = Color(red: 0.780, green: 0.608, blue: 1.0)        // #C79BFF
    }
}
