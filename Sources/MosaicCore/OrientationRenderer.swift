import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// 90 度単位の回転 + 左右反転（`ClipOrientation`）を 1 テクスチャへ適用する compute
/// カーネルの薄いラッパー。
///
/// `ColorGradeRenderer` の写し（16x16 ディスパッチ・out-of-place・`commandQueue` は
/// `MosaicRenderer` と共有）。数式の正は `ClipOrientation.map(_:CGPoint)`（Swift 側）に
/// あり、ここが呼ぶ `MosaicShader.metal` の `orientationKernel` はその px 版の写しでしかない
/// （数式を変えたら両方直すこと。`ClipOrientation` の型 doc 参照）。
final class OrientationRenderer {
    private let pipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue

    /// `MosaicShader.metal` の `OrientationParams` と**フィールド順・型を厳密に一致**
    /// させること（`ColorGradeParams` と同じ流儀。ずれると値が無言で化ける）。
    private struct OrientationParams {
        var rotation: UInt32
        var isMirrored: UInt32
        var outWidth: UInt32
        var outHeight: UInt32
    }

    init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        guard let function = library.makeFunction(name: "orientationKernel") else {
            throw MosaicRendererError.functionMissing("orientationKernel")
        }
        self.pipelineState = try device.makeComputePipelineState(function: function)
        self.commandQueue = commandQueue
    }

    /// `input` へ `orientation` を掛け、`output` へ書く。`input`/`output` は別テクスチャで
    /// あること（他のカーネルと同じ out-of-place 前提）。`output` のサイズは呼び出し側が
    /// `orientation.displaySize(inputSize)` 相当（90/270 度で縦横入れ替え）で確保しておくこと。
    /// 呼び出し側が `orientation.isIdentity` を見て呼ぶかどうかを決める
    /// （ここでは判定しない。ゼロコスト経路の判断は呼び出し側の責務）。
    @discardableResult
    func render(
        input: MTLTexture,
        output: MTLTexture,
        orientation: ClipOrientation,
        waitForCompletion: Bool
    ) -> Bool {
        var params = OrientationParams(
            rotation: UInt32(orientation.rotation.rawValue),
            isMirrored: orientation.isMirrored ? 1 : 0,
            outWidth: UInt32(output.width),
            outHeight: UInt32(output.height)
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        withUnsafeBytes(of: &params) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (output.width + 15) / 16,
            height: (output.height + 15) / 16,
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
