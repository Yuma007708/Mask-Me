import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// テキストのビットマップ（アプリ層がラスタライズ済み）をキャンバスへ合成する
/// compute カーネルの薄いラッパー（E3-2）。
///
/// `MosaicRenderer` の顔・背景モザイクと同じ「out-of-place・16x16 ディスパッチ」の
/// 流儀に揃えてある。矩形の位置・サイズ・不透明度はすべて `TextQuadLayout`
/// （純 Swift・プレビューと書き出し共通）が計算した値をそのまま受け取るだけで、
/// このクラス自身はレイアウトの数式を一切持たない。
final class TextOverlayRenderer {
    private let pipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue

    /// `MosaicShader.metal` の `textOverlayKernel` と**フィールド順・型を厳密に一致**
    /// させること（`MosaicParams` と同じ流儀。ずれると値が無言で化ける）。
    private struct TextOverlayParams {
        var originX: Float
        var originY: Float
        var width: Float
        var height: Float
        var opacity: Float
        var canvasWidth: UInt32
        var canvasHeight: UInt32
    }

    init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        guard let function = library.makeFunction(name: "textOverlayKernel") else {
            throw MosaicRendererError.functionMissing("textOverlayKernel")
        }
        self.pipelineState = try device.makeComputePipelineState(function: function)
        self.commandQueue = commandQueue
    }

    /// `input` へ `textTexture` を `layout` の位置・サイズ・不透明度で重ね、`output` へ書く。
    /// `input`/`output` は別テクスチャであること（他のカーネルと同じ out-of-place 前提）。
    /// コマンドキューは `MosaicRenderer` と共有する（init 時に受け取って保持する）。
    @discardableResult
    func render(
        input: MTLTexture,
        output: MTLTexture,
        textTexture: MTLTexture,
        layout: TextQuadLayout,
        waitForCompletion: Bool
    ) -> Bool {
        var params = TextOverlayParams(
            originX: Float(layout.originX),
            originY: Float(layout.originY),
            width: Float(layout.width),
            height: Float(layout.height),
            opacity: Float(layout.opacity),
            canvasWidth: UInt32(input.width),
            canvasHeight: UInt32(input.height)
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(textTexture, index: 2)
        withUnsafeBytes(of: &params) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (input.width + 15) / 16,
            height: (input.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        if waitForCompletion { commandBuffer.waitUntilCompleted() }
        return true
    }
}
#endif
