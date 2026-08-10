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
        "WatermarkCompositor.apply(",
        // 回転（写真モード底上げ 第5段）も許可 3 ファイル以外から呼べないようにする。
        "renderOrientedToNewTexture("
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

    /// **`needsWatermark` の判定源は `Entitlements`（課金権限）1 本だけであること。**
    ///
    /// `MaskMe/` 全体で `needsWatermark:` の**実引数**に `true`/`false` のリテラルが
    /// 現れたら、誰かが判定を端折って固定値を渡している（写真は常に透かし無し/常に透かし
    /// あり、のように権限と無関係に固定されてしまう）サインなので落とす。
    /// パラメータの**既定値宣言**（`needsWatermark: Bool = false` のような
    /// `VideoMosaicExporter.export` のシグネチャ）は「実引数」ではないので対象外
    /// ——`Bool =` を挟むぶん、探す文字列（`needsWatermark: true` / `needsWatermark: false`）
    /// が直接は一致しない。
    ///
    /// あわせて、`renderPreview()` 本体の `needsWatermark:` 行が `isPro` を含むこと
    /// （`MosaicEditorModel` の中では `Entitlements.shared` を直接読まず、注入された
    /// `entitlements` プロパティ経由で読む規約——`entitlements` プロパティの doc 参照）。
    func testWatermarkDecisionComesOnlyFromEntitlements() throws {
        let appDirectory = try maskMeDirectory()
        let forbiddenLiterals = ["needsWatermark: true", "needsWatermark: false"]
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            for literal in forbiddenLiterals where stripped.contains(literal) {
                offenders.append("\(url.lastPathComponent): \(literal)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "needsWatermark: に true/false のリテラルが渡されている（権限判定を経由していない疑い）: \(offenders)")

        let modelURL = appDirectory.appendingPathComponent("Model/MosaicEditorModel.swift")
        let modelText = try XCTUnwrap(try? String(contentsOf: modelURL, encoding: .utf8))
        let strippedModel = strippingComments(modelText)
        let renderPreviewBody = try XCTUnwrap(extractFunctionBody(named: "renderPreview", in: strippedModel),
            "renderPreview() が見つからない（MosaicEditorModel.swift の構造が変わった？）")
        let needsWatermarkLines = renderPreviewBody.split(separator: "\n")
            .filter { $0.contains("needsWatermark:") }
        XCTAssertFalse(needsWatermarkLines.isEmpty, "renderPreview() に needsWatermark: が見つからない")
        XCTAssertTrue(needsWatermarkLines.allSatisfy { $0.contains("isPro") },
            "renderPreview() の needsWatermark: が isPro を経由していない: \(needsWatermarkLines)")
    }

    /// `PhotoRenderPipeline.swift` が `Entitlements` を一切読んでいないこと
    /// （判定点の二重化防止。判定は呼び出し側 `renderPreview()` の 1 箇所だけに閉じる）。
    func testPhotoRenderPipelineDoesNotReadEntitlements() throws {
        let url = try maskMeDirectory().appendingPathComponent("Model/PhotoRenderPipeline.swift")
        let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
        let stripped = strippingComments(text)
        XCTAssertFalse(stripped.contains("Entitlements"),
            "PhotoRenderPipeline.swift が Entitlements を直接読んでいる（判定点が二重化している）")
    }

    /// 写真モードの共有（`ShareLink`）が `previewImage` だけを使っていること
    /// （`renderer` / `MTLTexture` / `Compositor` を含んだら、共有のために描画をやり直して
    /// いる＝原本が渡る経路がある疑い。`savePhoto()` と同じ WYSIWYG 規約）。
    func testPhotoShareUsesPreviewImageOnly() throws {
        let url = try maskMeDirectory().appendingPathComponent("Views/EditorView.swift")
        let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
        let stripped = strippingComments(text)
        guard let range = stripped.range(of: "ShareLink") else {
            XCTFail("EditorView.swift に ShareLink が見つからない（写真の共有導線が無い？）")
            return
        }
        let windowEnd = stripped.index(range.upperBound,
            offsetBy: 200, limitedBy: stripped.endIndex) ?? stripped.endIndex
        let window = stripped[range.lowerBound..<windowEnd]
        XCTAssertTrue(window.contains("previewImage"), "ShareLink が previewImage を使っていない")
        for forbidden in ["renderer", "MTLTexture", "Compositor"] {
            XCTAssertFalse(window.contains(forbidden),
                "ShareLink 周辺に「\(forbidden)」が含まれている（描画をやり直している疑い）")
        }
    }

    /// **`remap(..., clipID: nil)` の取り違えを防ぐ番人（写真モード底上げ 第5〜6段）。**
    ///
    /// `clipID: nil` は「クリップ未登録＝単位矩形・無変換」の意味であって静止画の意味では
    /// ない（`TimelineRenderLayout.placement(for:)` の doc 参照）。`PhotoRenderPipeline.swift`
    /// が静止画の写像に `remap(..., clipID: nil)` を書いてしまうと、回転が黙って効かず
    /// モザイクが素通しになる。`remapStill` 系（`clipID` を取らない）だけを使うこと。
    func test_photoPipelineNeverUsesClipKeyedRemapWithNilClipID() throws {
        let url = try maskMeDirectory().appendingPathComponent("Model/PhotoRenderPipeline.swift")
        let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
        let stripped = strippingComments(text)
        XCTAssertFalse(stripped.contains("clipID: nil"),
            "PhotoRenderPipeline.swift に `clipID: nil` が現れている（remapStill 系を使うこと）")
    }

    /// **`MosaicEditorModel.renderLayout` へ直接代入する箇所が無いこと（写真モード底上げ 第4段）。**
    ///
    /// `renderLayout` は計算プロパティ化した（格納は `builtLayout`）。格納 var のままだと
    /// `applyPhotoEdit` / `apply(snapshot:)`（undo）/ `load(image:)` の 3 箇所で同期を
    /// 取り忘れる余地があり、写真の向きだけ古いままモザイクが素通しになる
    /// （`MosaicEditorModel.renderLayout` の doc 参照）。誰かが「計算プロパティは代入できない」
    /// というコンパイルエラーを避けるために格納へ戻してしまうのをソース走査で塞ぐ。
    ///
    /// `MaskMe/Export/VideoMosaicExporter.swift` は無関係——`MosaicEditorModel` とは別の型が
    /// 持つ**独立した**`private var renderLayout`（コンストラクタ引数をそのまま保持する
    /// 通常の格納プロパティ）で、`MosaicEditorModel.renderLayout` の同期問題とは無関係
    /// （`PhotoRenderPipelineParityTests.unrelatedPreexistingCaller` と同じ理由の除外）。
    func test_renderLayoutHasNoStoredAssignment() throws {
        let appDirectory = try maskMeDirectory()
        let unrelatedFile = "VideoMosaicExporter.swift"
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != unrelatedFile else { continue }
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            if stripped.contains("renderLayout = ") || stripped.contains("renderLayout=") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "renderLayout への直接代入が見つかった（計算プロパティを格納へ戻していないか）: \(offenders)")
    }

    /// **アプリ層（`MaskMe/`）が物体マスクの前方写像に `remapStill` を直接書いていないこと
    /// （写真モード底上げ 第6段）。**
    ///
    /// 物体マスクの前方写像（素材 → 合成フレーム）は `ObjectMaskResolver.placements` の
    /// 唯一の場所に閉じてある（`MosaicEditorModel+ObjectMask.swift` の型 doc 参照）。
    /// アプリ層に `remapStill(` / `remapStillAngle(` を書き足すと、`ObjectMaskResolver` が
    /// 掛けた写像の上にもう一度掛かり、矩形が二重にずれる（`half` 相当になる）。
    /// 逆写像（`inverseRemapStill` / `inverseRemapStillAngle`）は「画面に描いた矩形を
    /// 素材へ戻す」入力経路で正当に必要なので対象外。
    ///
    /// `PhotoRenderPipeline.swift` も対象外——こちらは**顔ランドマーク・背景マスク**の
    /// 前方写像を持つのが正しい（`MosaicInput` の doc / `PhotoRenderPipeline.render` 本体
    /// 参照。素材フレーム基準のまま渡ってくる入力を、回転後フレームへ 1 回だけ写す）。
    /// このテストが狙う事故は**物体マスク**（`ObjectMask`）の前方写像の二重化
    /// （`ObjectMaskResolver.placements` が既に写した結果へ、アプリ層がもう一度
    /// `remapStill` を掛けてしまうこと）で、`MosaicEditorModel+ObjectMask.swift` 側の話。
    func test_appLayerNeverCallsRemapStillForObjectMasks() throws {
        let appDirectory = try maskMeDirectory()
        let unrelatedFile = "PhotoRenderPipeline.swift"
        let forbidden = ["remapStill(", "remapStillAngle("]
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != unrelatedFile else { continue }
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = strippingComments(text)
            for needle in forbidden where stripped.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "MaskMe/ の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "アプリ層が remapStill 系（前方写像）を直接呼んでいる（二重写像の恐れ）: \(offenders)")
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
