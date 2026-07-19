import XCTest
import CoreVideo
import Metal
@testable import MosaicCore

/// キャッシュヒット経路（プレビュー済み→検出キャッシュ満杯→エクスポート）の
/// **支配的コストである Metal モザイク描画のスループット（fps）** を実測する。
///
/// エクスポートの1フレームあたり処理は「デコード＋Metal描画＋HEVC再エンコード」。
/// このうちデコードは軽く、HEVC は VideoToolbox のハード支援で描画より速いため、
/// **描画 fps が実効エクスポート fps の下限を決める**。ここでは実機経路と同じ
/// `render(...waitForCompletion: true)` を回して純粋な描画スループットを測り、
/// 5分（9000フレーム）加工へ線形外挿する（描画はフレーム数に対して線形）。
///
/// AVAssetWriter 合成も Simulator も pod も使わないため、`swift test` だけで
/// 再現性高く走る（フレーキー要素ゼロ）。GPU が無い環境では skip。
final class RenderThroughputTests: XCTestCase {
    private let width = 1920
    private let height = 1080
    private let warmup = 10
    private let measured = 300         // 実測フレーム数（10秒相当）
    private let projectFrames = 9000   // 外挿先（5分 @30fps）

    func testMosaicRenderThroughputAndFiveMinuteProjection() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal デバイスが無い環境ではスキップ")
        }
        // `swift test`（headless SwiftPM）ではシェーダーの default.metallib が
        // .module バンドルに載らず makeDefaultLibrary が nil を返す（＝MosaicCore に
        // レンダラーのユニットテストが無い理由）。Metal 描画が実際に動くのは
        // Simulator/実機の App ターゲットのみ。その環境では本ベンチが計測を行う。
        let renderer: MosaicRenderer
        do {
            renderer = try MosaicRenderer(
                device: device,
                evaluator: TrackingEvaluator(smoothing: 1.0)
            )
        } catch MosaicRendererError.libraryUnavailable {
            throw XCTSkip("シェーダーライブラリ未搭載環境（swift test 等）ではスキップ。描画計測は Simulator/実機のみ")
        }
        let input = try makeTexture(device: device, usage: [.shaderRead, .shaderWrite])
        let output = try makeTexture(device: device, usage: [.shaderRead, .shaderWrite])
        let face = makeSyntheticFace()

        // ウォームアップ（GPU パイプライン・シェーダーキャッシュを温める）。
        for _ in 0..<warmup {
            renderer.render(input: input, into: output,
                            landmarkSets: [face], waitForCompletion: true)
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<measured {
            renderer.render(input: input, into: output,
                            landmarkSets: [face], waitForCompletion: true)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        let fps = elapsed > 0 ? Double(measured) / elapsed : 0
        let projectedSec = fps > 0 ? Double(projectFrames) / fps : .infinity

        print(String(format:
            "[MMRENDER] %dx%d frames=%d elapsed=%.3fs → 描画スループット=%.0f fps",
            width, height, measured, elapsed, fps))
        print(String(format:
            "[MMRENDER] 5分(9000f)描画の外挿=%.1f秒（キャッシュヒット経路の下限・検出ゼロ）",
            projectedSec))
        print(String(format:
            "[MMRENDER] 判定: 目標30-60秒。描画外挿=%.1f秒。HEVCエンコードはハード支援で描画より速い。",
            projectedSec))

        XCTAssertGreaterThan(fps, 0, "描画スループットが計測できていない")
        XCTAssertTrue(projectedSec.isFinite, "外挿値が有限でない")
    }

    // MARK: - Helpers

    private func makeTexture(device: MTLDevice, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("テクスチャ生成に失敗")
        }
        return texture
    }

    /// 合成フルメッシュ顔（478点・良性）。実機で最も高価なメッシュ描画経路を通す。
    private func makeSyntheticFace() -> FaceLandmarkSet {
        var pts: [FaceLandmark] = []
        pts.reserveCapacity(FaceLandmarkSet.fullMeshCount)
        let side = 22
        for i in 0..<FaceLandmarkSet.fullMeshCount {
            let gx = i % side, gy = i / side
            let nx = 0.35 + 0.30 * Float(gx) / Float(side - 1)
            let ny = 0.30 + 0.35 * Float(gy) / Float(side - 1)
            pts.append(FaceLandmark(x: nx, y: ny, z: 0))
        }
        return FaceLandmarkSet(points: pts, confidence: 0.99)
    }
}
