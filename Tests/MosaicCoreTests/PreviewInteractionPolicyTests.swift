import XCTest
@testable import MosaicCore

/// `PreviewInteractionPolicy.make` の契約。
///
/// `.normal` の真理値表は `FacePickOverlay.isActive` / `RectangleDrawingOverlay` の
/// `isRectangleToolActive` 周り / `TextOverlayEditView.allowsHitTesting` を**そのまま
/// 移設したもの**なので、ここでは現行実装から読み取った literal で固定する
/// （式を書き写して再導出しない）。
final class PreviewInteractionPolicyTests: XCTestCase {
    // MARK: - .normal の真理値表（顔の段 × 矩形ツール × 写真/動画 の全組み合わせ）

    fileprivate struct Case {
        let editorMode: PreviewEditorMediaKind
        let activeTab: PreviewEditorEffectTab
        let isRectangleToolActive: Bool
        let expectedFacePick: Bool
        let expectedRectangleDrawing: Bool
        let expectedTextEditing: Bool
    }

    /// `isRectangleToolActive` はアプリ側の不変条件（`MosaicEditorModel.swift` の
    /// `if activeTab != .face { isRectangleToolActive = false }`）により
    /// `activeTab == .background` のときは常に false のはずだが、この関数自体は
    /// その不変条件に依存せず、渡された値をそのまま使う（防御的にどちらの値でも
    /// 正しく振る舞うことを確認する）。
    private static let cases: [Case] = [
        // 写真モード
        Case(editorMode: .photo, activeTab: .face, isRectangleToolActive: false,
            expectedFacePick: true, expectedRectangleDrawing: false, expectedTextEditing: false),
        Case(editorMode: .photo, activeTab: .face, isRectangleToolActive: true,
            expectedFacePick: false, expectedRectangleDrawing: true, expectedTextEditing: false),
        Case(editorMode: .photo, activeTab: .background, isRectangleToolActive: false,
            expectedFacePick: false, expectedRectangleDrawing: false, expectedTextEditing: false),
        Case(editorMode: .photo, activeTab: .background, isRectangleToolActive: true,
            expectedFacePick: false, expectedRectangleDrawing: true, expectedTextEditing: false),
        // 動画モード
        Case(editorMode: .video, activeTab: .face, isRectangleToolActive: false,
            expectedFacePick: true, expectedRectangleDrawing: false, expectedTextEditing: true),
        Case(editorMode: .video, activeTab: .face, isRectangleToolActive: true,
            expectedFacePick: false, expectedRectangleDrawing: true, expectedTextEditing: false),
        Case(editorMode: .video, activeTab: .background, isRectangleToolActive: false,
            expectedFacePick: false, expectedRectangleDrawing: false, expectedTextEditing: true),
        Case(editorMode: .video, activeTab: .background, isRectangleToolActive: true,
            expectedFacePick: false, expectedRectangleDrawing: true, expectedTextEditing: false)
    ]

    func test_通常モードの真理値表が現行挙動と一致する() {
        for testCase in Self.cases {
            let policy = PreviewInteractionPolicy.make(mode: .normal, editorMode: testCase.editorMode,
                                                        activeTab: testCase.activeTab,
                                                        isRectangleToolActive: testCase.isRectangleToolActive)
            XCTAssertEqual(policy.allowsFacePick, testCase.expectedFacePick,
                           "facePick: \(testCase)")
            XCTAssertEqual(policy.allowsRectangleDrawing, testCase.expectedRectangleDrawing,
                           "rectangleDrawing: \(testCase)")
            XCTAssertEqual(policy.allowsTextEditing, testCase.expectedTextEditing,
                           "textEditing: \(testCase)")
            // 既存マスクの編集とピンチズームは、どの組み合わせでも常に true
            // （`RectangleDrawingOverlay` のマスク枠は矩形ツールの ON/OFF に関係なく
            // 操作できる。ピンチズームは `EditorView+Preview.swift` がタブに関係なく結線）。
            XCTAssertTrue(policy.allowsExistingMaskEditing, "existingMaskEditing: \(testCase)")
            XCTAssertTrue(policy.allowsPinchZoom, "pinchZoom: \(testCase)")
            XCTAssertFalse(policy.allowsCropHandles, "cropHandles: \(testCase)")
        }
    }

    // MARK: - .crop は排他

    /// 「常に全部 false」でも「常に全部 true」でも落ちるように、両方向を固定する。
    func test_クロップ編集中は全ての操作面が止まる() {
        for editorMode: PreviewEditorMediaKind in [.photo, .video] {
            for activeTab: PreviewEditorEffectTab in [.face, .background] {
                for isRectangleToolActive in [false, true] {
                    let policy = PreviewInteractionPolicy.make(mode: .crop, editorMode: editorMode,
                                                               activeTab: activeTab,
                                                               isRectangleToolActive: isRectangleToolActive)
                    XCTAssertFalse(policy.allowsFacePick)
                    XCTAssertFalse(policy.allowsRectangleDrawing)
                    XCTAssertFalse(policy.allowsExistingMaskEditing)
                    XCTAssertFalse(policy.allowsTextEditing)
                    // クロップハンドルだけが true（「常に全部 false」だと落ちる側）。
                    XCTAssertTrue(policy.allowsCropHandles)
                }
            }
        }
    }

    func test_クロップ編集中はピンチズームも止まる() {
        let policy = PreviewInteractionPolicy.make(mode: .crop, editorMode: .video, activeTab: .face,
                                                    isRectangleToolActive: false)
        XCTAssertFalse(policy.allowsPinchZoom)
    }
}

extension PreviewInteractionPolicyTests.Case: CustomStringConvertible {
    var description: String {
        "editorMode=\(editorMode) activeTab=\(activeTab) isRectangleToolActive=\(isRectangleToolActive)"
    }
}
