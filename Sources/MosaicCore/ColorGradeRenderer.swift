import Foundation

#if canImport(Metal) && canImport(MetalKit)
import Metal

/// 色調補正（`ColorGrade`）を 1 テクスチャへ適用する compute カーネルの薄いラッパー。
///
/// `TextOverlayRenderer` の写し（16x16 ディスパッチ・out-of-place・`commandQueue` は
/// `MosaicRenderer` と共有）。数式の正は `ColorGrade.apply(r:g:b:)`（Swift 側）にあり、
/// ここが呼ぶ `MosaicShader.metal` の `colorGradeKernel` はその写しでしかない
/// （数式を変えたら両方直すこと。`ColorGrade` の型 doc 参照）。
final class ColorGradeRenderer {
    private let pipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue

    /// `MosaicShader.metal` の `ColorGradeParams` と**フィールド順・型を厳密に一致**
    /// させること（`MosaicParams` / `TextOverlayParams` と同じ流儀。ずれると値が
    /// 無言で化ける）。
    private struct ColorGradeParams {
        var brightness: Float
        var contrast: Float
        var saturation: Float
        var warmth: Float
        var width: UInt32
        var height: UInt32
    }

    init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        guard let function = library.makeFunction(name: "colorGradeKernel") else {
            throw MosaicRendererError.functionMissing("colorGradeKernel")
        }
        self.pipelineState = try device.makeComputePipelineState(function: function)
        self.commandQueue = commandQueue
    }

    /// `input` へ `grade` を適用し、`output` へ書く。`input`/`output` は別テクスチャであること
    /// （他のカーネルと同じ out-of-place 前提）。呼び出し側が `grade.isIdentity` を見て
    /// 呼ぶかどうかを決める（ここでは判定しない。ゼロコスト経路の判断は呼び出し側の責務）。
    @discardableResult
    func render(
        input: MTLTexture,
        output: MTLTexture,
        grade: ColorGrade,
        waitForCompletion: Bool
    ) -> Bool {
        var params = ColorGradeParams(
            brightness: Float(grade.brightness),
            contrast: Float(grade.contrast),
            saturation: Float(grade.saturation),
            warmth: Float(grade.warmth),
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
