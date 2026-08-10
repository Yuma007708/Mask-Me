import XCTest
@testable import MosaicCore

/// **描画順序（色調 → モザイク → テキスト → 透かし）がプレビュー・書き出し・写真の
/// 3経路で食い違っていないことを固定する番人。**
///
/// `ColorGradeCompositor` の型 doc・崩さない規則 1・4（色調はモザイクより前、透かしは
/// 常に最後）が実コード上でも守られているかをソース走査で確認する。
final class RenderStageOrderTests: XCTestCase {
    /// 描画順で早いものから並べた目印。写真経路（`PhotoRenderPipeline.swift`）は
    /// まだテキスト・透かしを持たないため、実際に存在する目印だけを取り出して
    /// その部分列が正しい順序になっているかを見る。
    private let orderedMarkers = [
        "renderOrientedToNewTexture(",
        "ColorGradeCompositor.apply(",
        "renderToNewTexture(",
        "TextOverlayCompositor.apply(",
        "WatermarkCompositor.apply("
    ]

    /// **ファイルごとに「最低限これだけの段が無ければならない」を明示する。**
    ///
    /// 旧実装の `present.count >= 2` は、新しい段（テキスト・透かし）を足し忘れても
    /// 緑のまま通ってしまう空振りの穴だった（写真経路がテキスト・透かしを持たなかった
    /// 頃の名残）。写真モード底上げ 第2段（テキスト）・第3段（透かし）でこの経路にも
    /// 4段すべてが揃い、第5段（今回）で写真経路にだけ回転（`renderOrientedToNewTexture(`）が
    /// 加わったため、ファイルごとに必要な段数を固定する。
    ///
    /// **回転は写真経路（`PhotoRenderPipeline.swift`）にしか無い。** 動画クリップの向きは
    /// `AVMutableVideoCompositionLayerInstruction`（`ClipOrientation.transform(sourceSize:)`）
    /// で映像そのものに焼き込まれ、この Metal カーネルは通らない
    /// （`MosaicPreviewController+Rendering.swift` / `VideoMosaicExporter.swift` の
    /// 必須集合に `renderOrientedToNewTexture(` を含めないのはそのため）。
    private let requiredMarkers: [String: Set<String>] = [
        "MaskMe/Model/PhotoRenderPipeline.swift": [
            "renderOrientedToNewTexture(",
            "ColorGradeCompositor.apply(", "renderToNewTexture(",
            "TextOverlayCompositor.apply(", "WatermarkCompositor.apply("
        ],
        "MaskMe/Model/MosaicPreviewController+Rendering.swift": [
            "ColorGradeCompositor.apply(", "renderToNewTexture(",
            "TextOverlayCompositor.apply(", "WatermarkCompositor.apply("
        ],
        // `VideoMosaicExporter` は出力バッファを使い回すため `renderToNewTexture(` ではなく
        // `renderer.render(` を直接呼ぶ（`renderToNewTexture(` という文字列自体が現れない）。
        "MaskMe/Export/VideoMosaicExporter.swift": [
            "ColorGradeCompositor.apply(",
            "TextOverlayCompositor.apply(", "WatermarkCompositor.apply("
        ]
    ]

    private var filesToCheck: [String] { Array(requiredMarkers.keys).sorted() }

    func testAllThreeRenderPathsApplyStagesInTheSameOrder() throws {
        let root = repositoryRoot()
        for path in filesToCheck {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
            }
            let stripped = strippingComments(text)

            // 存在する目印だけを、ファイル中の最初の出現位置で並べる。
            let present: [(marker: String, index: String.Index)] = orderedMarkers.compactMap { marker in
                guard let range = stripped.range(of: marker) else { return nil }
                return (marker, range.lowerBound)
            }
            let presentMarkers = Set(present.map(\.marker))

            // **新段の足し忘れを塞ぐ本体。** ファイルごとに定めた必須集合が
            // 部分集合として含まれていることを要求する（旧 `>= 2` の空振りを閉じる）。
            let required = requiredMarkers[path] ?? []
            let missing = required.subtracting(presentMarkers)
            XCTAssertTrue(missing.isEmpty,
                "\(path) に必須の描画段の目印が見つからない（テストが空振りしている恐れ）: "
                + "不足 \(missing.sorted()) / 検出 \(present.map(\.marker))")

            // orderedMarkers の並びと、present の出現順（ファイル中の位置順）が一致すること。
            // 「存在する目印だけを抜き出した部分列」が両者で同じであれば順序が保たれている。
            let expectedSubsequence = orderedMarkers.filter { marker in present.contains { $0.marker == marker } }
            let actualOrder = present.sorted { $0.index < $1.index }.map(\.marker)
            XCTAssertEqual(actualOrder, expectedSubsequence,
                "\(path) の描画順が崩れている（色調 → モザイク → テキスト → 透かしの順で"
                + "呼ぶこと）。実際の出現順: \(actualOrder)")
        }
    }

    /// **色調補正の出力を検出へ渡していないこと。**
    ///
    /// `ColorGradeCompositor` の崩さない規則 3（検出は必ず補正前のバッファで行う）の
    /// 機械化。補正後のバッファ（プレビュー/書き出しでの変数名は `graded` を含む）や
    /// 回転後のバッファ（変数名は `oriented` を含む。写真モード底上げ 第5段で回転が
    /// 検出より前段に来たため、回転後バッファを検出へ渡さない規則も同じ機械で守る）を
    /// `landmarker.allLandmarks(` / `updateBackgroundMask(` へ渡す行が無いことを確認する。
    /// 顔検出が落ちてモザイクが素通しになる、プライバシーアプリとして最悪の事故の防止。
    func testColorGradeOutputIsNeverFedToDetection() throws {
        let root = repositoryRoot()
        let appDirectory = root.appendingPathComponent("MaskMe")
        guard FileManager.default.fileExists(atPath: appDirectory.path) else {
            throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
        }
        let detectionCalls = ["landmarker.allLandmarks(", "updateBackgroundMask("]
        let postProcessedVariableNeedles = ["graded", "oriented"]
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            for rawLine in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                guard detectionCalls.contains(where: { line.contains($0) }) else { continue }
                guard postProcessedVariableNeedles.contains(where: { line.contains($0) }) else { continue }
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "色調補正後のバッファ（`graded` 系変数）が検出へ渡されている（顔検出が落ちる最悪の事故）: \(offenders)")
    }

    // MARK: - Helpers

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
