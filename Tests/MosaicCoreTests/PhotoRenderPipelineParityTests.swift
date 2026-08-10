import XCTest
@testable import MosaicCore

/// **写真の描画経路が二重化していないことを機械的に防ぐ番人。**
///
/// 写真モード底上げ 第1段（色調補正）で `PhotoRenderPipeline.render` を
/// 「写真の絵を作る唯一の関数」として新設した。もし誰かが `savePhoto()` や
/// 別の場所で `ColorGradeCompositor.apply` / `renderToNewTexture` /
/// `renderBackgroundToNewTexture` を直接呼んでしまうと、プレビューと保存結果が
/// 食い違う（プレビューでは効くのに保存すると消える、あるいはその逆）事故になる
/// —— `BodyWarpCompositorParityTests`（`feat/body-tuner` ブランチ）が動画側で
/// 実際に踏んだ「片側だけ独自実装」の写真版をここで防ぐ。
///
/// **「同じ関数を2回呼んで一致」は決定性の確認であって二重化は防げない**
/// （`BodyWarpCompositorParityTests` の doc 参照）。ここではソースの構造そのものを
/// 走査する。
final class PhotoRenderPipelineParityTests: XCTestCase {
    /// 合成器を直接呼んでよい3ファイル（写真経路・プレビュー経路・書き出し経路）。
    private let allowedCompositorCallers: Set<String> = [
        "PhotoRenderPipeline.swift",
        "MosaicPreviewController+Rendering.swift",
        "VideoMosaicExporter.swift"
    ]

    /// `CameraMosaicPipeline+Rendering.swift` は撮影パイプライン（`renderer.renderToNewTexture`
    /// をモザイクだけの用途で呼ぶ）で、色調補正・写真の静止プレビュー・書き出しのいずれとも
    /// 無関係。この機能（写真モード底上げ）より前から存在する呼び出しで、
    /// `ColorGradeCompositor.apply` / `TextOverlayCompositor.apply` / `WatermarkCompositor.apply`
    /// はここには一切現れない（`renderToNewTexture(` の needle だけが衝突する）。
    /// 二重化防止の対象は「色調補正を含む写真/動画の合成経路」なので、無関係な
    /// カメラ経路まで許可ファイルへ含めるのではなく、ここで明示的に例外として扱う。
    private let unrelatedPreexistingCaller = "CameraMosaicPipeline+Rendering.swift"

    private let forbiddenCalls = [
        "ColorGradeCompositor.apply(",
        "renderToNewTexture(",
        "renderBackgroundToNewTexture(",
        "TextOverlayCompositor.apply(",
        "WatermarkCompositor.apply("
    ]

    func testOnlyThreeFilesMayCallCompositors() throws {
        let appDirectory = try maskMeDirectory()
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let name = url.lastPathComponent
            guard !allowedCompositorCallers.contains(name), name != unrelatedPreexistingCaller,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            for needle in forbiddenCalls where stripped.contains(needle) {
                offenders.append("\(name): \(needle)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "許可された3ファイル以外が合成器を直接呼んでいる（写真経路の二重化の恐れ）: \(offenders)")
    }

    /// `savePhoto()` は `previewImage` を保存するだけであること。
    ///
    /// `renderer` / `MTLTexture` / `Compositor` のいずれかの語が本体に現れたら、
    /// 誰かが `savePhoto()` の中で描画をやり直そうとしている（＝プレビューと保存で
    /// 別経路になる）サインなので落とす。
    func testSavePhotoConsumesPreviewImageOnly() throws {
        let url = try maskMeDirectory().appendingPathComponent("Model/MosaicEditorModel.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("アプリ層が無い環境ではスキップ")
        }
        let stripped = strippingComments(text)
        guard let body = extractFunctionBody(named: "savePhoto", in: stripped) else {
            XCTFail("savePhoto() が見つからない（MosaicEditorModel.swift の構造が変わった？）")
            return
        }
        XCTAssertTrue(body.contains("previewImage"), "savePhoto() が previewImage を読んでいない")
        for forbidden in ["renderer", "MTLTexture", "Compositor"] {
            XCTAssertFalse(body.contains(forbidden),
                "savePhoto() が「\(forbidden)」を含んでいる（描画を自前でやり直している疑い）")
        }
    }

    /// `PhotoRenderPipeline.render(` の呼び出しが `MaskMe/` 全体で 1 回だけであること
    /// （`renderPreview()` の唯一の呼び出し以外に生えていないか）。
    func testPhotoPipelineIsCalledExactlyOnce() throws {
        let appDirectory = try maskMeDirectory()
        var count = 0
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            // 定義ファイル自身（`static func render(`）を数えないよう、呼び出し形
            // `PhotoRenderPipeline.render(` だけを探す。
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            count += stripped.components(separatedBy: "PhotoRenderPipeline.render(").count - 1
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertEqual(count, 1, "PhotoRenderPipeline.render( の呼び出しが 1 回ではない（\(count) 回）")
    }

    // MARK: - Helpers

    private func maskMeDirectory() throws -> URL {
        let root = repositoryRoot()
        let dir = root.appendingPathComponent("MaskMe")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
        }
        return dir
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MosaicCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
    }

    /// 行コメント（`//` 以降）を落とす（`BodyWarpCompositorParityTests` と同じ流儀）。
    /// doc コメントに関数名が書いてあるだけで文字列検索が当たる事故を防ぐ。
    private func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// `func <name>(` から対応する閉じ `}` までの本体テキストを雑に取り出す
    /// （中括弧の対応を数えるだけ。文字列リテラル中の `{`/`}` は考慮しないが、
    /// この用途——特定語の有無チェック——には十分）。
    private func extractFunctionBody(named name: String, in text: String) -> String? {
        guard let signatureRange = text.range(of: "func \(name)(") else { return nil }
        guard let openBrace = text.range(of: "{", range: signatureRange.upperBound..<text.endIndex) else {
            return nil
        }
        var depth = 0
        var index = openBrace.lowerBound
        var bodyEnd = index
        while index < text.endIndex {
            let ch = text[index]
            if ch == "{" { depth += 1 } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    bodyEnd = index
                    break
                }
            }
            index = text.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(text[openBrace.lowerBound...bodyEnd])
    }
}
