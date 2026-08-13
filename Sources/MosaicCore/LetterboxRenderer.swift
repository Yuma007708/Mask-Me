import CoreGraphics
import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// レターボックス（余白）を塗る compute カーネルの薄いラッパー。
///
/// `ColorGradeRenderer` の写し（16x16 ディスパッチ・out-of-place・`commandQueue` は
/// `MosaicRenderer` と共有）。
///
/// **入力は必ずモザイクを焼いた後のフレームであること。** ぼかしはこの同じテクスチャを
/// 読んで作るので、焼く前のフレームを渡すと素顔が余白へ拡大されて出る。
/// ぼかしは隠す手段ではない（`TimelineBackground` の型 doc に理由の全文がある）。
final class LetterboxRenderer {
    private let pipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue

    /// `MosaicShader.metal` の `LetterboxParams` と**フィールド順・型を厳密に一致**
    /// させること（`ColorGradeParams` と同じ流儀。ずれると値が無言で化ける）。
    private struct LetterboxParams {
        var contentMinX: Float
        var contentMinY: Float
        var contentMaxX: Float
        var contentMaxY: Float
        var fillR: Float
        var fillG: Float
        var fillB: Float
        var blurRadius: Float
        var width: UInt32
        var height: UInt32
    }

    init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        guard let function = library.makeFunction(name: "letterboxKernel") else {
            throw MosaicRendererError.functionMissing("letterboxKernel")
        }
        self.pipelineState = try device.makeComputePipelineState(function: function)
        self.commandQueue = commandQueue
    }

    /// ぼかし半径（ピクセル）。**短辺基準**にするので、出力解像度が変わっても
    /// 見た目のぼけ具合が変わらない（長辺基準だと横長と縦長で強さが食い違う）。
    ///
    /// 上限は短辺の 4%。これ以上広げても見た目はほとんど変わらない一方、
    /// カーネルの読み取り回数だけが増える（余白は面積が大きいので効いてくる）。
    static func blurRadius(strength: Double, frameSize: CGSize) -> Float {
        let shortSide = Double(min(frameSize.width, frameSize.height))
        guard shortSide.isFinite, shortSide > 0, strength.isFinite else { return 0 }
        let unit = min(max(strength, 0), 1)
        return Float(shortSide * 0.04 * unit)
    }

    /// 塗り方の指定。**引数を 1 つずつ増やさず 1 個の値にまとめる**——
    /// `contentRect` / 色 / 半径は「余白をどう塗るか」という 1 つの関心事で、
    /// 別々に渡すと呼び出し側で片方だけ更新する取り違えが作れる。
    struct Fill {
        /// 素材が置かれている範囲（**正規化・左上原点**）。この矩形の中は 1 ピクセルも触らない。
        var contentRect: CGRect
        var color: RGBAColor
        /// 0 なら単色で塗るだけ。
        var blurRadius: Float
    }

    /// `input` の余白を塗って `output` へ書く。`input`/`output` は別テクスチャであること。
    @discardableResult
    func render(
        input: MTLTexture,
        output: MTLTexture,
        fill: Fill,
        waitForCompletion: Bool
    ) -> Bool {
        let contentRect = fill.contentRect
        let blurRadius = fill.blurRadius
        let color = fill.color.clamped
        var params = LetterboxParams(
            contentMinX: Float(contentRect.minX),
            contentMinY: Float(contentRect.minY),
            contentMaxX: Float(contentRect.maxX),
            contentMaxY: Float(contentRect.maxY),
            fillR: Float(color.red),
            fillG: Float(color.green),
            fillB: Float(color.blue),
            blurRadius: blurRadius.isFinite ? max(0, blurRadius) : 0,
            width: UInt32(input.width),
            height: UInt32(input.height)
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<LetterboxParams>.stride, index: 0)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (input.width + 15) / 16,
                             height: (input.height + 15) / 16,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        if waitForCompletion { commandBuffer.waitUntilCompleted() }
        return true
    }
}

#endif
