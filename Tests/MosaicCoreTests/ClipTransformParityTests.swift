import CoreGraphics
import XCTest
@testable import MosaicCore

/// クリップ単位の変形（`ClipTransform`）: 映像とモザイクの写像一致、回転との合成順、
/// および**二重化の機械的防止**（番人テスト）を固定する。
///
/// `VideoCompositionFactory.make`（`MaskMe/Export/`）は `let rect =
/// clip.transform.applied(to: AspectFit.placement(of: display, in: renderSize))` という
/// 1 行で、この `rect` を映像側（`fitTransform`）と顔座標の写像用（`layoutRects` →
/// `TimelineRenderLayout`）の両方へ渡す。アプリ層（`MaskMe/`）は MediaPipe に依存し
/// `MosaicCoreTests` から直接呼べないため、ここでは同じ組み立て方をコア層の型だけで
/// 再現し、`ClipRenderTransform.make`（映像側の変換）と `TimelineRenderLayout.remap`
/// （モザイク側の写像）が変形込みでも一致することを固定する
/// （`ClipOrientationTests.test_レターボックス込みでも映像とモザイクの写像が一致する` と同じ手口）。
final class ClipTransformParityTests: XCTestCase {
    private let samplePoints: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.1)
    ]

    private func landmarkSet(at point: CGPoint) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [FaceLandmark(x: Float(point.x), y: Float(point.y), z: 0)],
                        confidence: 1.0)
    }

    // MARK: - 1. 映像とモザイクの正規化写像が変形込みで一致する

    /// `VideoCompositionFactory.make` が組み立てる `rect`（`transform.applied(to:
    /// AspectFit.placement(...))`）を映像側・モザイク側の両方へ渡したときに、
    /// ピクセル変換（`ClipRenderTransform.make`）と正規化写像（`TimelineRenderLayout.remap`）
    /// が全 8 向き × 変形ありで一致すること。
    func test_映像のアフィン変換とモザイクの正規化写像が変形込みで一致する() {
        let display = CGSize(width: 640, height: 360)
        let renderSize = CGSize(width: 480, height: 640)
        let clipID = UUID()
        let transforms = [
            ClipTransform(scale: 1.0, offset: .zero),
            ClipTransform(scale: 1.7, offset: CGPoint(x: 0.15, y: -0.1)),
            ClipTransform(scale: 0.4, offset: CGPoint(x: -0.3, y: 0.25))
        ]
        let orientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
            [ClipOrientation(rotation: rotation, isMirrored: false),
             ClipOrientation(rotation: rotation, isMirrored: true)]
        }
        for transform in transforms {
            for orientation in orientations {
                // `VideoCompositionFactory.make` と同じ組み立て順:
                // 向きを掛けた後のサイズで AspectFit → その rect へ変形を 1 回だけ掛ける。
                let basePlacement = AspectFit.placement(of: orientation.displaySize(display),
                                                         in: renderSize)
                let placement = transform.applied(to: basePlacement)
                let layout = TimelineRenderLayout(placements: [clipID: placement],
                                                  orientations: [clipID: orientation])
                let affine = ClipRenderTransform.make(displaySize: display,
                                                      orientation: orientation,
                                                      placement: placement,
                                                      renderSize: renderSize)
                for point in samplePoints {
                    let pixel = CGPoint(x: point.x * display.width, y: point.y * display.height)
                    let moved = pixel.applying(affine)
                    let viaPixels = CGPoint(x: moved.x / renderSize.width,
                                            y: moved.y / renderSize.height)
                    let viaLayout = layout.remap([landmarkSet(at: point)], clipID: clipID)[0].points[0]
                    XCTAssertEqual(Double(viaLayout.x), Double(viaPixels.x), accuracy: 1e-5,
                                   "\(orientation) \(transform) \(point)")
                    XCTAssertEqual(Double(viaLayout.y), Double(viaPixels.y), accuracy: 1e-5,
                                   "\(orientation) \(transform) \(point)")
                }
            }
        }
    }

    // MARK: - 2. 変形は向きを掛けた後（出力座標系）で効く

    /// 90 度回転したクリップに横方向 offset を掛けても、**画面上は横に動く**こと。
    ///
    /// `applied(to:)` は「向きを掛けた後のサイズで求めた配置矩形」を受け取るので、
    /// 変形は素材の縦横に引きずられない。回転を内側（`applied` の前ではなく `orientation`
    /// のさらに内側、素材座標側）に書いた実装だと、90 度回転で横方向の offset が
    /// 画面上は縦方向の移動として現れてしまい、ここが落ちる。
    func test_90度回転したクリップで横方向offsetは画面の横に動く() {
        let display = CGSize(width: 640, height: 360)
        let renderSize = CGSize(width: 640, height: 360)
        let orientation = ClipOrientation(rotation: .right90)
        let basePlacement = AspectFit.placement(of: orientation.displaySize(display), in: renderSize)
        let transform = ClipTransform(scale: 1.0, offset: CGPoint(x: 0.2, y: 0))
        let placement = transform.applied(to: basePlacement)

        XCTAssertNotEqual(placement.midX, basePlacement.midX, accuracy: 1e-9,
                          "横方向 offset なのに画面上の横位置が動いていない")
        XCTAssertEqual(placement.midY, basePlacement.midY, accuracy: 1e-9,
                       "横方向 offset なのに画面上の縦位置が動いている（回転を内側に書いた実装の兆候）")
    }

    // MARK: - 3. 二重化の機械的防止（番人テスト）

    /// **アプリ層（`MaskMe/`）が scale/offset の算術を自前で書いていないこと。**
    ///
    /// 「同じ関数を 2 回呼んで一致」は決定性の確認であって二重化は防げない。
    /// ソースの構造そのものを検査する: `MaskMe/` 配下で `ClipTransform` の内部計算
    /// （`scale *`・`offset.x *`・変形の中心移動）を自前で書いているファイルが 0 件であること。
    /// **`applied(to:` の呼び出しそのもの**は別テスト（
    /// `testCompositionFactoryIsTheOnlyCallSiteOfApplied`）で唯一の呼び出し元を確認するので、
    /// ここでは「呼ばずに算術だけ書き写す」パターンを狙う。
    func testAppLayerNeverAppliesClipTransformItself() throws {
        let root = repositoryRoot()
        let appDirectory = root.appendingPathComponent("MaskMe")
        guard FileManager.default.fileExists(atPath: appDirectory.path) else {
            throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
        }
        // `VideoCompositionFactory.swift` は唯一の正当な呼び出し元（`applied(to:` を書く）。
        // それ以外のファイルにこれらの断片が現れたら、変形の算術を書き写している疑いが強い。
        let forbidden = [".scale * CGFloat(", "clip.transform.scale *", "transform.offset.x *",
                         "transform.offset.y *"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: appDirectory,
                                                   includingPropertiesForKeys: nil)
        var scanned = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let stripped = strippingComments(text)
            for needle in forbidden where stripped.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "アプリ層の走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertTrue(offenders.isEmpty,
            "アプリ層が変形の算術を自前で組み立てている: \(offenders)。"
            + "`ClipTransform.applied(to:)` だけを通すこと（二重化の防止）")
    }

    /// **`ClipTransform.applied(to:` の呼び出し元は `VideoCompositionFactory.swift`
    /// ただ 1 つであること。** `MaskMe/` と `Sources/` の非テストファイルを走査する。
    /// テストファイル自身（このファイルを含む）は除外する。
    func testCompositionFactoryIsTheOnlyCallSiteOfApplied() throws {
        let root = repositoryRoot()
        var callSites: [String] = []
        var scanned = 0
        for directoryName in ["MaskMe", "Sources"] {
            let directory = root.appendingPathComponent(directoryName)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                // **必ず `strippingComments()` を通してから探す。** doc コメントに
                // `applied(to:` という語を書いただけで当たってしまい、呼び出しを消しても
                // 緑のまま素通りする（`BodyWarpCompositorParityTests` と同じ注意）。
                if strippingComments(text).contains(".applied(to:") {
                    callSites.append(url.lastPathComponent)
                }
            }
        }
        // **スキップの条件は「アプリ層が無いこと」であって「呼び出しが見つからないこと」では
        // ない。** 呼び出しが 0 件なのは、まさに検出したい退行（唯一の適用点が消され、
        // 変形が映像にもモザイクにも効かなくなった状態）そのもの。ここを
        // `callSites.isEmpty` でスキップにすると、適用点を消しても緑のまま素通りする
        // （親の変異検証で実際に素通りした。`.applied(to:` を消した木で失敗 0・スキップ 1）。
        guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("MaskMe").path) else {
            throw XCTSkip("アプリ層が無い環境（パッケージ単体）ではスキップ")
        }
        XCTAssertGreaterThan(scanned, 50, "走査に失敗している（0 件走査で緑になる空振りを防ぐ）")
        XCTAssertEqual(callSites, ["VideoCompositionFactory.swift"],
            "`applied(to:` の呼び出し元が唯一（VideoCompositionFactory.swift）ではない: \(callSites)")
    }

    /// 行コメント（`//` 以降）を落とす。文字列リテラル内の `//` までは考えないが、
    /// この用途（呼び出しが実際に書かれているか）には十分（`BodyWarpCompositorParityTests` と同じ）。
    private func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MosaicCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
    }
}
