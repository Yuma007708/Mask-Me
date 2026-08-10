import XCTest
@testable import MosaicCore

/// `MosaicEditorModel+Photo.swift` の setter が必ず `applyPhotoEdit` を経由することを
/// 機械的に固定する。
///
/// `applyPhotoEdit` は `commitEdit()` + `renderPreview()` + `editVersion` の唯一の発火点
/// （`MosaicEditorModel+Photo.swift` の型 doc 参照）。setter が `photoEdit` へ直接代入して
/// この入口をバイパスすると、`renderPreview()` が呼ばれず「スライダーを動かしても絵が
/// 変わらない」事故、`commitEdit()` が呼ばれず「undo に積まれない」事故になる。
final class PhotoEditWiringTests: XCTestCase {
    /// 骨格そのものである `applyPhotoEdit` 自身は対象外（自分自身を呼ぶ必要は無い）。
    private let entryPointFunctionName = "applyPhotoEdit"

    func testEveryMutatorGoesThroughApplyPhotoEdit() throws {
        let url = repositoryRoot()
            .appendingPathComponent("MaskMe/Model/MosaicEditorModel+Photo.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
        }
        let stripped = strippingComments(text)
        let functions = extractFunctions(in: stripped)

        XCTAssertGreaterThan(functions.count, 0, "MosaicEditorModel+Photo.swift に func が見つからない（空振り防止）")
        // 骨格（`applyPhotoEdit` 自身）以外に、実際に検査対象の setter が最低 1 つあること。
        let mutators = functions.filter { $0.name != entryPointFunctionName }
        XCTAssertGreaterThan(mutators.count, 0,
            "MosaicEditorModel+Photo.swift に applyPhotoEdit 以外の setter が無い（空振り防止）")

        var offenders: [String] = []
        for function in mutators where !function.body.contains(entryPointFunctionName) {
            offenders.append(function.name)
        }
        XCTAssertTrue(offenders.isEmpty,
            "applyPhotoEdit を経由していない setter がある（renderPreview/commitEdit 呼び忘れの恐れ）: \(offenders)")
    }

    // MARK: - Helpers

    private struct FoundFunction {
        let name: String
        let body: String
    }

    /// 素朴な括弧対応カウントで `func <name>(...) { ... }` の本体を切り出す。
    /// ネストした関数・クロージャは無いファイルなのでこの粒度で十分。
    private func extractFunctions(in text: String) -> [FoundFunction] {
        var results: [FoundFunction] = []
        var searchStart = text.startIndex
        while let funcRange = text.range(of: "func ", range: searchStart..<text.endIndex) {
            let afterFunc = funcRange.upperBound
            guard let parenIndex = text[afterFunc...].firstIndex(of: "(") else { break }
            let name = String(text[afterFunc..<parenIndex]).trimmingCharacters(in: .whitespaces)
            guard let openBrace = text.range(of: "{", range: parenIndex..<text.endIndex) else { break }
            var depth = 0
            var index = openBrace.lowerBound
            var bodyEnd = index
            while index < text.endIndex {
                let ch = text[index]
                if ch == "{" { depth += 1 } else if ch == "}" {
                    depth -= 1
                    if depth == 0 { bodyEnd = index; break }
                }
                index = text.index(after: index)
            }
            let body = String(text[openBrace.lowerBound...bodyEnd])
            results.append(FoundFunction(name: name, body: body))
            searchStart = text.index(after: bodyEnd)
        }
        return results
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MosaicCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
    }

    private func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}
