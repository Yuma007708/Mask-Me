import Foundation

/// プレビュー上の操作モード。`.crop` はクロップ枠のハンドルだけを出す
/// 専用モードで、通常編集（顔ピック・矩形・テキスト・ピンチズーム）とは
/// **排他**（同時に成立しない）。
public enum EditorInteractionMode: Equatable, Sendable {
    case normal
    case crop
}

/// `PreviewInteractionPolicy.make` が受け取る、素材の種別。
/// アプリ側 `MosaicEditorModel.Mode`（`.photo` / `.video`）に対応する core 版。
public enum PreviewEditorMediaKind: Equatable, Sendable {
    case photo
    case video
}

/// `PreviewInteractionPolicy.make` が受け取る、いま選ばれているエフェクトの段。
/// アプリ側 `MosaicEditorModel.EffectTab`（`.face` / `.background`）に対応する core 版。
public enum PreviewEditorEffectTab: Equatable, Sendable {
    case face
    case background
}

/// プレビュー上の各操作面が「いま触れるか」をまとめた真理値表。
///
/// 顔ピック（`FacePickOverlay`）・矩形の新規作成／既存編集（`RectangleDrawingOverlay`）・
/// テキスト編集（`TextOverlayEditView`）・ピンチズーム・クロップハンドルが、
/// それぞれ別のファイルに散らばった条件式で「いま出してよいか」を判定していたのを
/// ここへ集約したもの。**View 側に条件式を書き戻さないこと**——1 箇所直し忘れると
/// 「矩形は編集できるのに顔だけ触れない」のような、画面上で原因の分からない
/// 食い違いが起きる。
public struct PreviewInteractionPolicy: Equatable, Sendable {
    /// 顔の枠をタップして選択を切り替えられるか（`FacePickOverlay`）。
    public let allowsFacePick: Bool
    /// ドラッグで新しい矩形を作れるか（`RectangleDrawingOverlay.drawingSurface`）。
    public let allowsRectangleDrawing: Bool
    /// 既に置いた物体マスクの枠・つまみ（移動・大きさ・回転・削除）を操作できるか。
    public let allowsExistingMaskEditing: Bool
    /// テキスト／ステッカーの選択・移動ができるか（`TextOverlayEditView`）。
    public let allowsTextEditing: Bool
    /// 2 本指のピンチ／パンでプレビューを拡大できるか。
    public let allowsPinchZoom: Bool
    /// クロップ枠のハンドルを操作できるか。
    public let allowsCropHandles: Bool

    public init(allowsFacePick: Bool, allowsRectangleDrawing: Bool, allowsExistingMaskEditing: Bool,
                allowsTextEditing: Bool, allowsPinchZoom: Bool, allowsCropHandles: Bool) {
        self.allowsFacePick = allowsFacePick
        self.allowsRectangleDrawing = allowsRectangleDrawing
        self.allowsExistingMaskEditing = allowsExistingMaskEditing
        self.allowsTextEditing = allowsTextEditing
        self.allowsPinchZoom = allowsPinchZoom
        self.allowsCropHandles = allowsCropHandles
    }

    /// `mode == .crop` のときは**クロップハンドルだけ** true で、他は全部 false
    /// （通常編集の操作面とクロップ枠のドラッグは同じプレビュー面を奪い合うため、
    /// 排他にしないと指が同時に取り合いになる）。
    ///
    /// `mode == .normal` は現行の 3 ファイルに散らばった判定をそのまま移設した
    /// もの（`FacePickOverlay.isActive` / `RectangleDrawingOverlay` の
    /// `isRectangleToolActive` 周り / `TextOverlayEditView` の `allowsHitTesting`）。
    /// **挙動を 1 ビットも変えていない**:
    /// - 顔ピック: `activeTab == .face && !isRectangleToolActive`
    /// - 矩形の新規作成: `isRectangleToolActive`（既存マスクの編集面はこれとは独立に常時開く）
    /// - 既存マスクの編集: 常に true（ツールの ON/OFF・段・モードに関係なく操作できる）
    /// - テキスト編集: `!isRectangleToolActive`（**モードを問わない**。写真モードにも
    ///   テキスト／ステッカーが入ったため、動画限定の条件は外した。`editorMode` は
    ///   引数として残してあるが現在どの真理値にも効いていない——写真だけ挙動を
    ///   変えたくなったときに、View 側へ条件式を書き戻さず済むようにするため）
    /// - ピンチズーム: 常に true（`EditorView+Preview.swift` がタブに関係なく結線している）
    public static func make(mode: EditorInteractionMode, editorMode: PreviewEditorMediaKind,
                            activeTab: PreviewEditorEffectTab, isRectangleToolActive: Bool) -> PreviewInteractionPolicy {
        guard mode == .normal else {
            return PreviewInteractionPolicy(allowsFacePick: false, allowsRectangleDrawing: false,
                                            allowsExistingMaskEditing: false, allowsTextEditing: false,
                                            allowsPinchZoom: false, allowsCropHandles: true)
        }
        return PreviewInteractionPolicy(
            allowsFacePick: activeTab == .face && !isRectangleToolActive,
            allowsRectangleDrawing: isRectangleToolActive,
            allowsExistingMaskEditing: true,
            allowsTextEditing: !isRectangleToolActive,
            allowsPinchZoom: true,
            allowsCropHandles: false)
    }
}
