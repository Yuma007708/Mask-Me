import Foundation

/// 編集画面の下部ツールバーが「いま何を出しているか」。
///
/// ツールバーは**常に 1 段**で、階層が変わると中身が**丸ごと入れ替わる**
/// （段を積み上げない。積むとプレビューの高さが階層で動く）。
/// 旧 UI は「編集の道具」と「モザイクの階層」が別々の段に分かれており、
/// 戻る `‹` はモザイク側にしか無かったため、**現在地が読めなくなっていた**。
/// 経路を 1 本の enum に統合することで「`‹` を何回押せば戻れるか」が
/// 型の上で決まる（`parent` が高々 2 段で `root` に着く）。
///
/// **この enum は「見えている段」だけを表す。** 効果が ON かどうか
/// （`faceMosaicOn` など）とは独立で、`root` へ戻っても効果は保たれる。
public enum EditorDockRoute: String, Equatable, Sendable, CaseIterable {
    /// クリップに対する編集の道具（分割・速度・音量・削除／追加）とモザイクの入口。
    case root
    /// モザイクの種類選び（顔・背景・矩形）。
    case mosaic
    /// 顔モザイク（対象の顔チップ＋粗さ）。
    case face
    /// 背景モザイク（粗さのみ）。
    case background
    /// 手で置く矩形（追加＋粗さ）。
    case rectangle
    /// 色調補正（プリセットのチップ＋詳細スライダーへの入口）。`mosaic` を経由せず
    /// `root`（クリップ選択時のツールバー）から直接入る。顔・背景・矩形と違って
    /// ON/OFF の効果フラグを持たない（既定値 `.identity` が「無補正」を兼ねるので、
    /// 顔モザイクのような `faceMosaicOn` 相当のフラグが要らない）。
    case colorGrade
    /// クリップの向き（回転・反転）。以前は「回転」「反転」の 2 ボタンだったものを
    /// 1 段へ畳んである（ツールバーの枠が足りないため。`VideoTimelineView+Toolbar` の
    /// doc 参照）。`colorGrade` と同じく `root` から直接入り、効果フラグを持たない。
    case transform

    /// 戻る `‹` の行き先。`root` は最上段なので自分自身を返す
    /// （＝ `root` では `‹` を出さない。`showsBackButton` を使う）。
    public var parent: EditorDockRoute {
        switch self {
        case .root: return .root
        case .mosaic: return .root
        case .face, .background, .rectangle: return .mosaic
        case .colorGrade, .transform: return .root
        }
    }

    /// 戻る `‹` を出すか。最上段だけ出さない（行き止まりを作らないため、
    /// これ以外のすべての段には必ず戻る手段がある）。
    public var showsBackButton: Bool { self != .root }

    /// 「完了」を出すか。`root` は完了する対象が無いので出さない。
    /// 完了はどの深さからでも一気に `root` へ戻す（`‹` の連打を要求しない）。
    public var showsDoneButton: Bool { self != .root }

    /// この段が粗さスライダーを持つか。
    public var showsBlockSizeSlider: Bool {
        switch self {
        case .face, .background, .rectangle: return true
        case .root, .mosaic, .colorGrade, .transform: return false
        }
    }
}

/// ドックの遷移。**タイムライン操作では段が動かない**ことを型で保証するための入れ物。
///
/// ここに無い操作（シーク・再生・クリップの選択／選択解除・スクロール・ズーム）は
/// **段を変えてはならない**。旧 UI はクリップ選択が下段そのものを差し替えていたため、
/// 粗さを調整しながら再生位置を確かめる、という当たり前の操作で段が消えていた。
///
/// 段が動くのは 3 つだけ:
/// - `enter` … 道具を押して降りる
/// - `back` … `‹` で 1 段上がる
/// - `done` … `root` へ一気に戻る
public enum EditorDockNavigation {
    /// 降りる。**降りられない組み合わせは現在地を保つ**（no-op）。
    ///
    /// 押せない項目は UI 側で出さない建前だが、非同期でクリップが消えるなど
    /// 想定外の順序でも段が壊れないよう、遷移表そのものを閉じた形にしてある。
    public static func enter(_ destination: EditorDockRoute,
                             from current: EditorDockRoute) -> EditorDockRoute {
        switch (current, destination) {
        case (.root, .mosaic):
            return .mosaic
        case (.mosaic, .face), (.mosaic, .background), (.mosaic, .rectangle):
            return destination
        // `colorGrade` / `transform` は `mosaic` を経由しない（クリップ選択時の
        // ツールバーから直接入る。`mosaic` はモザイクの種類選びだけの入口）。
        case (.root, .colorGrade), (.root, .transform):
            return destination
        default:
            return current
        }
    }

    public static func back(from current: EditorDockRoute) -> EditorDockRoute {
        current.parent
    }

    public static func done(from current: EditorDockRoute) -> EditorDockRoute {
        .root
    }
}
